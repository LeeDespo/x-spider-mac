import Foundation

/// 上游 stores/download.ts 的 CreationTask 调度器：串行执行、可取消、日期过滤、sameFileSkip、跳过计数。
@MainActor
@Observable
final class CreationTaskStore {
    static let shared = CreationTaskStore()

    var creationTasks: [CreationTask] = []
    private var cancellableTasks: [String: Task<Void, Never>] = [:]

    /// 上游 createCreationTask：入队 + 触发调度
    func createCreationTask(user: TwitterUser, filter: DownloadFilter) {
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
                nextCursor = cursor
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

                // sameFileSkip 检查在 DownloadStore.createDownloadTask 内部完成；
                // 被跳过的文件计入 skipCount
                let beforeCount = DownloadStore.shared.tasks.count
                await DownloadStore.shared.batchCreateDownloadTasks(paramsList)
                let addedCount = DownloadStore.shared.tasks.count - beforeCount
                completeCount += addedCount
                skipCount += paramsList.count - addedCount

                updateCreationTaskProgress(id: task.id, completeCount: completeCount, skipCount: skipCount)

                // 到达日期下限：停止翻页（上游 while 条件 now.isAfter(since)）
                if now < since { break }
                if nextCursor == nil { break }
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
