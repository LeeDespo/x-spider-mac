import Foundation

/// 上游 stores/download.ts 的 CreationTask 调度器：串行执行、可取消、日期过滤、sameFileSkip、跳过计数。
///
/// **爬取本身交给组件**（`crawl.run`）：翻页、游标推进、终止判据族（到底 / 时间轴推进 /
/// 连续空页 / 游标未推进）都只有一份实现。外壳保留的是**产品语义**那一层——
/// 勾选与排除、精确的本地日历边界、同一次任务内不重复、进度与挂起。
@MainActor
@Observable
final class CreationTaskStore {
    static let shared = CreationTaskStore()

    var creationTasks: [CreationTask] = []
    private var cancellableTasks: [String: Task<Void, Never>] = [:]

    /// 上游 createCreationTask：入队 + 触发调度
    /// 重复创建拒绝提示(nil = 允许创建)
    var creationBlockedReason: String?

    /// 连续多少页"过滤后为空"就停止爬取。
    ///
    /// 客户端日期过滤会让窄范围的用户连续翻很多空页；不设上限会一直翻到
    /// 服务端尽头，正是 AGENTS.md 大坑 3 说的 429 风暴。
    /// 取 5：足够跳过零星的活动稀疏页，又不至于空转太久。
    /// **这条判据现在由组件执行**（`strategy.limits.empty_page_limit`），这里只留取值。
    nonisolated static let maxConsecutiveEmptyPages = 5

    /// 一次性交给组件的爬取**最多翻几页**。
    ///
    /// `crawl.run` 是"跑到停为止再返回"，而外壳要边跑边报进度、要能在限流时挂起、
    /// 还要能被取消。切成小块之后，每块之间外壳才有机会做这些事；块内部照旧由组件
    /// 做页间节流。代价是每块末尾可能多翻 ≤ (crawlChunkPages-1) 页（块的边界对不上
    /// 用户要的内容），可接受。
    nonisolated static let crawlChunkPages = 3

    func createCreationTask(user: TwitterUser, filter: DownloadFilter,
                            selection: MediaSelection = MediaSelection()) {
        // 防重复创建:同用户 + 同过滤条件(数据源/类型/日期) + 同选择集 → 拒绝。
        // 选择集也要比：同一用户同时间范围，「全选」与「只选 3 个」是两个不同任务。
        let duplicate = creationTasks.contains { existing in
            (existing.status == .waiting || existing.status == .active)
                && existing.user.id == user.id
                && existing.filter.source == filter.source
                && existing.filter.mediaTypes == filter.mediaTypes
                && existing.filter.dateRange?.start == filter.dateRange?.start
                && existing.filter.dateRange?.end == filter.dateRange?.end
                && existing.excludedKeys == selection.excludedKeys
                && existing.includedKeys == selection.includedKeys
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
            skipCount: 0,
            excludedKeys: selection.excludedKeys,
            includedKeys: selection.includedKeys
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

    // MARK: - 爬取循环

    /// 一次创建任务：**分块**跑 `crawl.run`，把候选变成下载任务。
    ///
    /// 与旧实现（自己翻页）相比，终止判据不再在这里：
    /// 组件给 `done_reason`，这里只区分"本块跑满（`page_limit_reached`）→ 用 next_cursor 接着跑"
    /// 与"这一轮结束了"。
    private func runCreationTask(_ task: CreationTask) async {
        let filter = task.filter
        let userId = task.user.id

        var completeCount = 0
        var skipCount = 0
        // include 态（用户只勾了几个）：勾选的都收齐就收工，不必翻到服务端尽头。
        var remainingIncluded = task.includedKeys

        // **精确**的日期边界（本地日历），与展示路径 `applyDisplayFilter` 同源。
        // 组件那侧的 `since/until` 是**粗筛**（按 UTC 天比较，故意各放宽一天），
        // 精确的这一层由 `decide` 按候选自带的 `created_at` 做——见 `crawlStrategy(for:)`。
        let since = filter.dateRange?.start ?? Date(timeIntervalSince1970: 0)
        let until = filter.dateRange?.inclusiveEnd ?? Date()

        let strategy = Self.crawlStrategy(for: filter)
        var cursor: String? = nil
        // 同一次任务内不重复入队（块的边界可能让同一媒体再次出现）
        var seenDownloadURLs = Set<String>()

        while true {
            if Task.isCancelled { return }

            // 限流自适应：X API 处于限流/离线/登录失效时**挂起**而不是失败退出——
            // cursor 与进度都保留，状态恢复后自动续跑。避免"越限越试"把限流拖长。
            await waitWhileThrottled(userId: userId)
            if Task.isCancelled { return }

            let result: [String: JSONValue]
            do {
                result = try await XSpiderAPI.shared.crawlPage(
                    source: filter.source, userId: userId, cursor: cursor, strategy: strategy)
            } catch is CancellationError {
                AppLogger.info("创建任务已取消", category: "DL", ["userId": userId])
                return
            } catch {
                AppLogger.warn("创建任务爬取出错,停止", category: "DL", [
                    "userId": userId, "error": error.localizedDescription,
                ])
                break
            }
            if Task.isCancelled { return }

            // 候选只说"哪条推文的哪个媒体"（有损）；命名与记账要**完整推文**
            // （契约 1.5.0 的 `posts`，与 candidates 是同一批数据的两个视角）。
            let postsById = Self.postsById(result)

            var paramsList: [(post: TwitterPost, media: TwitterMedia)] = []
            for candidate in (result[array: "candidates"] ?? []).compactMap({ $0.asObject }) {
                guard let postId = candidate[string: "post_id"],
                      let mediaId = candidate[string: "media_id"],
                      let post = postsById[postId],
                      let media = post.medias?.first(where: { $0.id == mediaId }) else { continue }
                switch Self.decide(post: post, media: media, task: task,
                                   since: since, until: until,
                                   seenDownloadURLs: &seenDownloadURLs) {
                case .enqueue:
                    paramsList.append((post, media))
                    if !task.includedKeys.isEmpty {
                        remainingIncluded.remove(MediaSelectionKey.make(post: post, media: media))
                    }
                case .countedAsSkip:
                    skipCount += 1
                case .ignored:
                    break
                }
            }

            if !paramsList.isEmpty {
                // sameFileSkip 由 `createDownloadTask` 内部按设置判定并拒绝；
                // 这里用任务数的差额补 `skipCount`（与旧实现同一算法）。
                let beforeCount = DownloadStore.shared.tasks.count
                await DownloadStore.shared.batchCreateDownloadTasks(paramsList)
                let addedCount = DownloadStore.shared.tasks.count - beforeCount
                completeCount += addedCount
                skipCount += paramsList.count - addedCount
            }
            updateCreationTaskProgress(id: task.id, completeCount: completeCount, skipCount: skipCount)

            // include 态：勾选的项全部到手 → 收工（不必翻到底）。
            //
            // **刻意不用契约的 `wanted_keys`**：那边的 key 是媒体 id，而外壳的键是
            // `postId/mediaId`，两套键对不上时它**静默不生效**（不报错，只是多翻页）——
            // "以为它在起作用"比"晚一点停"更危险。外壳自己判断更直接。
            if !task.includedKeys.isEmpty, remainingIncluded.isEmpty {
                AppLogger.info("所选媒体已全部找到,提前结束爬取", category: "DL", ["userId": userId])
                break
            }

            // 本块跑满就接着跑，其它 `done_reason`（到底 / 时间轴推进 / 连续空页 /
            // 游标未推进 / 收齐 / 取消 / 出错）都表示这一轮结束了。
            guard result[string: "done_reason"] == "page_limit_reached",
                  let next = result[string: "next_cursor"] else { break }
            cursor = next
        }

        AppLogger.info("创建任务爬取结束", category: "DL", [
            "userId": userId,
            "complete": "\(completeCount)",
            "skip": "\(skipCount)",
        ])
    }

    /// `crawl.run` 的 `posts[]` → `[id: TwitterPost]`（候选按 `post_id` 回连它）。
    private static func postsById(_ result: [String: JSONValue]) -> [String: TwitterPost] {
        var out: [String: TwitterPost] = [:]
        for json in (result[array: "posts"] ?? []).compactMap({ $0.asObject }) {
            if let post = XSpiderMapping.post(json) { out[post.id] = post }
        }
        return out
    }

    // MARK: - 策略与取舍（纯函数，测试直接调）

    /// `crawl.run` 的策略参数。
    ///
    /// 日期**故意各放宽一天**：组件按 **UTC 天**比较（`docs/02` §D3），而用户选的是
    /// **本地日历**——在 UTC+8 下，开始日的最初 8 小时会被它当成前一天丢掉。
    /// 放宽之后组件只是"省请求的粗筛"，精确边界由 `decide` 再做一次。
    /// （时区偏移最大 ±14 小时 < 24 小时，所以 ±1 天足够覆盖。）
    nonisolated static func crawlStrategy(for filter: DownloadFilter) -> [String: JSONValue] {
        var strategy: [String: JSONValue] = [
            "limits": .object([
                "page_size": .int(20),                 // 与旧循环用的端点默认值一致
                "page_throttle_ms": .int(500),         // 与旧循环的页间节流一致
                "max_pages": .int(Self.crawlChunkPages),
                "empty_page_limit": .int(Self.maxConsecutiveEmptyPages),
            ]),
        ]
        if let range = filter.dateRange {
            let widenedStart = Calendar.current.date(byAdding: .day, value: -1, to: range.start)
                ?? range.start
            strategy["since"] = .string(XSpiderAPI.searchDateString(widenedStart))
            strategy["until"] = .string(XSpiderAPI.searchDateString(XSpiderAPI.nextDay(range.end)))
        }
        if let types = filter.mediaTypes {
            strategy["media_types"] = .array(types.map { .string($0.rawValue) })
        }
        return strategy
    }

    /// 一条候选的取舍。
    enum CandidateDecision: Equatable {
        /// 建下载任务
        case enqueue
        /// 跳过并计入 `skipCount`（日期不符 / 用户在排除集里）
        case countedAsSkip
        /// 静默跳过（include 态下没勾选 / 同一次任务里已经见过）
        case ignored
    }

    /// 候选 → 要不要建下载任务。
    ///
    /// **组件已经做过粗筛**，这里做的是组件**不该知道**的那一层：
    /// - **精确的本地日历边界**：组件的日期按 UTC 天比较，比本地日历宽一天；
    /// - **媒体类型逐条判**：组件是按"这条推文里有符合的类型"来保留推文的，
    ///   被保留的推文里其它类型的媒体也会出现在候选里；
    /// - **勾选 / 排除集**：产品语义，刻意不进契约（外壳在候选上过滤，零额外请求）；
    /// - **同一次任务内不重复**：块的边界可能让同一媒体再次出现。
    ///
    /// 抽成纯函数是为了让测试**调生产代码**——旧测试里复刻了一份同样的判据，
    /// 生产代码改了它不会红（"断言写错比代码写错更贵"）。
    nonisolated static func decide(post: TwitterPost, media: TwitterMedia, task: CreationTask,
                                   since: Date, until: Date,
                                   seenDownloadURLs: inout Set<String>) -> CandidateDecision {
        // 没有下载地址、或本次任务里已经见过 → 静默跳过（不计入跳过数）
        guard let url = downloadURL(for: media), seenDownloadURLs.insert(url).inserted else {
            return .ignored
        }
        // 日期：本地日历边界；**没有 createdAt 的放行**（不能因为解析不到时间就丢内容）
        if let createdAt = post.createdAt, createdAt < since || createdAt > until {
            return .countedAsSkip
        }
        // 媒体类型：`nil` = 一个类型都不选。UI 始终给全三型；这层语义保持与原实现一致。
        guard task.filter.mediaTypes?.contains(media.type) ?? false else { return .ignored }

        let key = MediaSelectionKey.make(post: post, media: media)
        // 全选态下用户取消的项（「全选后取消几个」）
        if task.excludedKeys.contains(key) { return .countedAsSkip }
        // include 态：只处理勾选的
        if !task.includedKeys.isEmpty, !task.includedKeys.contains(key) { return .ignored }
        return .enqueue
    }

    // MARK: - 限流挂起

    /// 限流期间挂起：等状态恢复或熔断冷却结束再继续（cursor 不变，进度保留）。
    ///
    /// 用 `shouldSuspendNewWork` 而非直接读状态：网络类异常带 TTL，
    /// 到期后放行让真实请求重新判定 —— 否则"断网时无成功请求 → 状态永不清除 → 无限挂起"
    /// （用户反馈的"代理恢复后应用仍卡很久，除非重启"）。
    private func waitWhileThrottled(userId: String) async {
        var logged = false
        while !Task.isCancelled {
            let blocked = await MainActor.run { AccountStatusStore.shared.shouldSuspendNewWork }
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
            // 分段等待：期间用户点「重试」、冷却到期或网络异常 TTL 到期即可续跑
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
