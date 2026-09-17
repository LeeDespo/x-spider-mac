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

    /// 上游 runCreationTask（src/stores/download.ts）的忠实复刻：
    ///   while (nextCursor !== null && now.isAfter(since)) {
    ///     fetch(nextCursor); nextCursor = cursor; now = last?.createdAt || now;
    ///     日期过滤 → 媒体类型过滤 → sameFileSkip → batchCreateDownloadTask
    ///   }
    /// 两个要害（上游原文即如此，此前移植走样导致重复检索与请求风暴）：
    ///   1. cursor 推进紧跟 fetch 之后，**早于**任何过滤与 continue；
    ///   2. 终止靠 now 递减穿过 since，不靠页数上限。
    private func runCreationTask(_ task: CreationTask) async {
        let filter = task.filter
        let userId = task.user.id

        var completeCount = 0
        var skipCount = 0
        // 上游: let now = dayjs() —— 首页之前取当前时间
        var now = Date()
        let since = filter.dateRange?.start ?? Date(timeIntervalSince1970: 0)
        let until = filter.dateRange?.end ?? now

        // 上游: let nextCursor = undefined（首轮跑，服务端返回 null 即到底）。
        // Swift 无 undefined，用 hasFetched 区分"尚未请求"与"服务端已给 null"。
        var nextCursor: String? = nil
        var hasFetched = false
        var guardAgainstRepeatedCursor: String?

        while !hasFetched || (nextCursor != nil && now > since) {
            if Task.isCancelled { return }

            // 限流自适应：X API 处于限流/离线/登录失效时**挂起**而不是失败退出——
            // cursor 与进度都保留，状态恢复后自动续跑。避免"越限越试"把限流拖长。
            await waitWhileThrottled(userId: userId)
            if Task.isCancelled { return }

            do {
                let posts: [TwitterPost]
                let newCursor: String?
                if filter.source == .medias {
                    let r = try await TwitterAPI.shared.getUserMedias(userId: userId, cursor: nextCursor)
                    posts = r.posts
                    newCursor = r.cursor
                } else {
                    let r = try await TwitterAPI.shared.getUserTweets(userId: userId, cursor: nextCursor)
                    posts = r.posts
                    newCursor = r.cursor
                }
                if Task.isCancelled { return }

                // 上游: nextCursor = cursor; now = R.last(twitterPosts)?.createdAt || now
                // —— 紧跟 fetch，早于过滤（放循环尾会让被过滤清空的页重抓同一页）
                nextCursor = newCursor
                hasFetched = true
                if let lastCreated = posts.last?.createdAt { now = lastCreated }

                // X 偶发回吐与上一页相同的 cursor（限流/游标失效）。此时后续页必然重复，
                // 上游会原地空转并刷爆配额；判为到底退出。不设页数上限，正常翻页不受影响。
                if let sent = guardAgainstRepeatedCursor, let got = newCursor, sent == got {
                    AppLogger.warn("游标未推进,判定到底停止爬取", category: "DL", [
                        "userId": userId,
                    ])
                    break
                }
                guardAgainstRepeatedCursor = nextCursor

                // 上游日期过滤：until 前 + since 后；无 createdAt 放行
                let filteredPosts = posts.filter { post in
                    guard let createdAt = post.createdAt else { return true }
                    return createdAt <= until && createdAt >= since
                }

                // 上游: skipCount += getMediaCounts(twitterPosts) - getMediaCounts(filteredPosts)
                let totalMediaCount = posts.reduce(0) { $0 + ($1.medias?.count ?? 0) }
                let filteredMediaCount = filteredPosts.reduce(0) { $0 + ($1.medias?.count ?? 0) }
                skipCount += totalMediaCount - filteredMediaCount

                // 上游: 无符合日期条件的推文 → 记录进度后 continue（cursor 已推进）
                if filteredPosts.isEmpty {
                    updateCreationTaskProgress(id: task.id, completeCount: completeCount, skipCount: skipCount)
                    try await Self.pageThrottle()
                    continue
                }

                // 上游: 逐帖筛媒体类型 → prepareDownloadTask → sameFileSkip 存在性检查
                var paramsList: [(post: TwitterPost, media: TwitterMedia)] = []
                var seenDownloadURLs = Set<String>()
                for post in filteredPosts {
                    let medias = post.medias ?? []
                    for media in medias where (filter.mediaTypes?.contains(media.type) ?? false) {
                        // 同一次爬取内不重复入队（会话模块可能与主条目重复）
                        if let url = downloadURL(for: media), !seenDownloadURLs.insert(url).inserted { continue }
                        paramsList.append((post, media))
                    }
                }

                // 上游: 无待下载媒体 → 记录进度后 continue（cursor 已推进）
                if paramsList.isEmpty {
                    updateCreationTaskProgress(id: task.id, completeCount: completeCount, skipCount: skipCount)
                    try await Self.pageThrottle()
                    continue
                }

                // 上游: await batchCreateDownloadTask(paramsList); completeCount += paramsList.length
                // sameFileSkip 由 DownloadStore.createDownloadTask 内部按设置判定并计数跳过
                let beforeCount = DownloadStore.shared.tasks.count
                await DownloadStore.shared.batchCreateDownloadTasks(paramsList)
                let addedCount = DownloadStore.shared.tasks.count - beforeCount
                completeCount += addedCount
                skipCount += paramsList.count - addedCount

                updateCreationTaskProgress(id: task.id, completeCount: completeCount, skipCount: skipCount)

                try await Self.pageThrottle()
            } catch is CancellationError {
                AppLogger.info("创建任务已取消", category: "DL", ["userId": userId])
                return
            } catch {
                AppLogger.warn("创建任务爬取出错,停止", category: "DL", [
                    "userId": userId, "error": error.localizedDescription,
                ])
                break
            }
        }

        AppLogger.info("创建任务爬取结束", category: "DL", [
            "userId": userId,
            "complete": "\(completeCount)",
            "skip": "\(skipCount)",
        ])
    }

    /// 页间节流。上游靠浏览器渲染节奏自然限速，Swift 循环无此节流，显式等价（防 429）。
    ///
    /// 节奏随限流状态自适应：正常 500ms；曾触发限流（或当前处于限流/异常状态）时放缓到 1.5s。
    private static func pageThrottle() async throws {
        let caution = await MainActor.run {
            AccountStatusStore.shared.effectiveHealth != .normal
        }
        let nanos: UInt64 = caution ? 1_500_000_000 : 500_000_000
        do {
            try await Task.sleep(nanoseconds: nanos)
        } catch {
            throw CancellationError()
        }
    }

    /// 限流期间挂起：等状态恢复或熔断冷却结束再继续（cursor 不变，进度保留）。
    /// 只对"继续爬也没用"的状态挂起：限流、离线、超时、登录失效。
    private func waitWhileThrottled(userId: String) async {
        var logged = false
        while !Task.isCancelled {
            let blocked: Bool = await MainActor.run {
                switch AccountStatusStore.shared.effectiveHealth {
                case .rateLimited, .timedOut, .offline, .unauthenticated: return true
                case .normal, .serverError: return false
                }
            }
            guard blocked else {
                if logged {
                    AppLogger.info("限流解除,创建任务续跑", category: "DL", ["userId": userId])
                }
                return
            }
            if !logged {
                AppLogger.warn("限流中,创建任务挂起等待恢复", category: "DL", ["userId": userId])
                logged = true
            }
            // 分段等待：期间用户点「重试」或冷却到期即可续跑
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func updateCreationTaskProgress(id: String, completeCount: Int, skipCount: Int) {
        if let index = creationTasks.firstIndex(where: { $0.id == id }) {
            creationTasks[index].completeCount = completeCount
            creationTasks[index].skipCount = skipCount
        }
    }
}
