import Foundation

/// 上游 stores/download.ts 的 CreationTask 调度器：串行执行、可取消、日期过滤、sameFileSkip、跳过计数。
@MainActor
@Observable
final class CreationTaskStore {
    static let shared = CreationTaskStore()

    var creationTasks: [CreationTask] = []
    private var cancellableTasks: [String: Task<Void, Never>] = [:]

    /// 上游 createCreationTask：入队 + 触发调度
    /// 重复创建拒绝提示(nil = 允许创建)
    var creationBlockedReason: String?

    func createCreationTask(user: TwitterUser, filter: DownloadFilter) {
        // 防重复创建:同用户 + 同过滤条件(数据源/类型/日期)的任务已在排队或执行中 → 拒绝
        let duplicate = creationTasks.contains { existing in
            (existing.status == .waiting || existing.status == .active)
                && existing.user.id == user.id
                && existing.filter.source == filter.source
                && existing.filter.mediaTypes == filter.mediaTypes
                && existing.filter.dateRange?.start == filter.dateRange?.start
                && existing.filter.dateRange?.end == filter.dateRange?.end
        }
        if duplicate {
            creationBlockedReason = L("该用户已有相同条件的任务在队列中")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.creationBlockedReason = nil
            }
            return
        }
        let id = UUID().uuidString
        let task = CreationTask(
            id: id,
            user: user,
            filter: filter,
            status: .waiting,
            completeCount: 0,
            skipCount: 0
        )
        creationTasks.append(task)
        scheduleNext()
    }

    func removeCreationTask(_ id: String) {
        cancellableTasks[id]?.cancel()
        cancellableTasks.removeValue(forKey: id)
        creationTasks.removeAll { $0.id == id }
    }

    private func updateCreationTask(_ task: CreationTask) {
        if let index = creationTasks.firstIndex(where: { $0.id == task.id }) {
            creationTasks[index] = task
        }
    }

    /// 上游 scheduleCreationTasks：无 active 任务时取队头执行
    private func scheduleNext() {
        guard !creationTasks.contains(where: { $0.status == .active }) else { return }
        guard let index = creationTasks.firstIndex(where: { $0.status == .waiting }) else { return }

        var task = creationTasks[index]
        task.status = .active
        creationTasks[index] = task

        let taskHandle = Task { [weak self] in
            await self?.runCreationTask(task)
            await self?.finishCreationTask(task.id)
        }
        cancellableTasks[task.id] = taskHandle
    }

    private func finishCreationTask(_ id: String) {
        cancellableTasks.removeValue(forKey: id)
        creationTasks.removeAll { $0.id == id }
        scheduleNext()
    }

    /// 上游 runCreationTask：cursor 循环翻页 → 日期过滤 → 媒体类型过滤 → sameFileSkip → 批量下载
    private func runCreationTask(_ task: CreationTask) async {
        let filter = task.filter
        let userId = task.user.id

        var completeCount = 0
        var skipCount = 0
        var now = Date()
        let since = filter.dateRange?.start ?? Date(timeIntervalSince1970: 0)
        let until = filter.dateRange?.end ?? now

        var nextCursor: String? = nil
        // 翻页防御:X 偶发对"无更多内容"返回重复/非空 cursor,导致无限检索(用户实测上千页)
        var seenCursors = Set<String>()
        var seenPostIds = Set<String>()
        var dupPageStreak = 0

        while nextCursor != nil || completeCount + skipCount == 0 {
            if Task.isCancelled { return }

            do {
                let posts: [TwitterPost]
                let cursor: String?
                if filter.source == .medias {
                    let r = try await TwitterAPI.shared.getUserMedias(userId: userId, cursor: nextCursor)
                    posts = r.posts
                    cursor = r.cursor
                } else {
                    let r = try await TwitterAPI.shared.getUserTweets(userId: userId, cursor: nextCursor)
                    posts = r.posts
                    cursor = r.cursor
                }
                if Task.isCancelled { return }
                // 翻页防御:重复 cursor = 服务端已无新内容,立即停止
                if let c = cursor {
                    guard seenCursors.insert(c).inserted else { break }
                } else {
                    break  // 无 cursor = 到底
                }
                seenCursors.insert("")
                nextCursor = cursor
                // 内容重复检测:X 深翻会"cursor 前进 + 内容重复"无限发牌。
                // 连续 2 页没有任何新推文 → 到底。单页全重复(置顶重叠)放行。
                let pageIds = posts.map(\.id)
                if pageIds.isEmpty {
                    dupPageStreak += 1
                } else if pageIds.allSatisfy({ seenPostIds.contains($0) }) {
                    // 整页全是本次扫描已见过的推文(X 深翻重复发牌,cursor 仍前进)
                    dupPageStreak += 1
                } else {
                    dupPageStreak = 0
                }
                if dupPageStreak >= 2 { break }
                seenPostIds.formUnion(pageIds)
                if let lastPost = posts.last, let createdAt = lastPost.createdAt {
                    now = createdAt
                }
                // 日期过滤（上游 allPass：until 之前 + since 之后；无 createdAt 放行）
                let filteredPosts = posts.filter { post in
                    guard let createdAt = post.createdAt else { return true }
                    return createdAt <= until && createdAt >= since
                }

                // 被过滤掉的媒体数计入 skipCount
                let totalMediaCount = posts.reduce(0) { $0 + ($1.medias?.count ?? 0) }
                let filteredMediaCount = filteredPosts.reduce(0) { $0 + ($1.medias?.count ?? 0) }
                skipCount += totalMediaCount - filteredMediaCount

                // 没有符合条件的推文：继续翻页
                if filteredPosts.isEmpty {
                    updateCreationTaskProgress(id: task.id, completeCount: completeCount, skipCount: skipCount)
                    if nextCursor == nil { break }
                    continue
                }

                var paramsList: [(post: TwitterPost, media: TwitterMedia)] = []
                for post in filteredPosts {
                    let medias = post.medias ?? []
                    let filteredMedias = medias.filter { media in
                        filter.mediaTypes?.contains(media.type) ?? false
                    }
                    for media in filteredMedias {
                        paramsList.append((post, media))
                    }
                }

                if paramsList.isEmpty {
                    updateCreationTaskProgress(id: task.id, completeCount: completeCount, skipCount: skipCount)
                    if nextCursor == nil { break }
                    continue
                }

                // 全部下载防重复:同一推文媒体在本轮/既有任务里只创建一次
                // (时间线翻页可能返回重叠推文,sameFileSkip 的记录文件模式在下载完成后才写记录,挡不住并发重复)
                var seenUrls = Set<String>()
                var deduped: [(post: TwitterPost, media: TwitterMedia)] = []
                for item in paramsList {
                    guard let url = downloadURL(for: item.media) else { continue }
                    guard seenUrls.insert(url).inserted else { continue }
                    if DownloadStore.shared.tasks.contains(where: { $0.downloadUrl == url && $0.status != .error && $0.status != .removed }) {
                        skipCount += 1
                        continue
                    }
                    deduped.append(item)
                }
                let beforeCount = DownloadStore.shared.tasks.count
                await DownloadStore.shared.batchCreateDownloadTasks(deduped)
                let addedCount = DownloadStore.shared.tasks.count - beforeCount
                completeCount += addedCount
                skipCount += deduped.count - addedCount

                updateCreationTaskProgress(id: task.id, completeCount: completeCount, skipCount: skipCount)

                // 到达日期下限：停止翻页（上游 while 条件 now.isAfter(since)）
                if now < since { break }
                if nextCursor == nil { break }
                // 页间节流,防 429 限流风暴
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                NSLog("CreationTask error: \(error.localizedDescription)")
                break
            }
        }
    }

    private func updateCreationTaskProgress(id: String, completeCount: Int, skipCount: Int) {
        if let index = creationTasks.firstIndex(where: { $0.id == id }) {
            creationTasks[index].completeCount = completeCount
            creationTasks[index].skipCount = skipCount
        }
    }
}
