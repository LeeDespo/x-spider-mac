import Foundation

/// 全局请求闸门：令牌桶限速 + 同端点串行 + 429 熔断。
///
/// 为什么需要它：单个循环内的节流（翻页 400ms、爬虫 500ms）只约束"单次间隔"，
/// 但当翻页、详情、互动、爬虫、图片同时活跃时，并发叠加会把瞬时速率推高到触发 429。
/// 闸门把这些请求收进一个统一速率视图，是避免限流最有效的一层。
///
/// 设计取舍：
/// - **按端点分类**（而非全局串行）：时间线可以慢，但不该被互动请求阻塞；
/// - **串行 = 单飞行**：同类端点上一次请求未返回前不发下一个，天然消除并发尖峰；
/// - **熔断短路**：429 后该类端点直接快速失败（不占用配额、不等待），调用方按既有
///   错误路径处理（显示重试/停止本轮），避免"越限越试"；
/// - 令牌桶与熔断均为**被动**：只根据真实响应调整，不主动探测。
actor RequestGate {
    static let shared = RequestGate()

    /// 端点类别：同类共享队列与熔断状态
    enum Kind: String, CaseIterable, Sendable {
        case timeline   // UserMedia / UserTweets / HomeTimeline（翻页、爬虫）
        case detail     // TweetDetail（详情、评论）
        case user       // UserByScreenName / Following
        case action     // 点赞/转推/书签/关注等写操作
        case misc       // 其它（首页 HTML、XClId 等）

        var displayName: String {
            switch self {
            case .timeline: return L("时间线")
            case .detail: return L("推文详情")
            case .user: return L("用户信息")
            case .action: return L("互动操作")
            case .misc: return L("其它")
            }
        }

        /// 从请求路径推断类别（GraphQL operation 名在路径末段）
        static func classify(path: String) -> Kind {
            if path.contains("UserMedia") || path.contains("UserTweets") || path.contains("HomeTimeline") || path.contains("HomeLatestTimeline") {
                return .timeline
            }
            if path.contains("TweetDetail") { return .detail }
            if path.contains("UserByScreenName") || path.contains("Following") || path.contains("/1.1/friendships") {
                return .user
            }
            if path.contains("FavoriteTweet") || path.contains("UnfavoriteTweet")
                || path.contains("CreateRetweet") || path.contains("DeleteRetweet")
                || path.contains("CreateBookmark") || path.contains("DeleteBookmark")
                || path.contains("/1.1/friendships/create") || path.contains("/1.1/friendships/destroy") {
                return .action
            }
            return .misc
        }
    }

    enum GateError: LocalizedError {
        case breakerOpen(kind: Kind, until: Date)

        var errorDescription: String? {
            switch self {
            case .breakerOpen(let kind, _):
                return L("已被限流，\(kind.displayName)请求暂停中")
            }
        }
    }

    // MARK: - 配置（每次请求读取，设置改动即时生效）

    private var config: GatewayConfig = .default

    struct GatewayConfig: Sendable {
        var enabled: Bool
        var requestsPerWindow: Int
        var windowSeconds: Int
        var serialize: Bool
        var breakerEnabled: Bool
        var cooldownSeconds: Int

        static let `default` = GatewayConfig(
            enabled: true, requestsPerWindow: 10, windowSeconds: 10,
            serialize: true, breakerEnabled: true, cooldownSeconds: 900
        )
    }

    func update(config: GatewayConfig) {
        self.config = config
    }

    // MARK: - 状态

    private var tokens: Double = 10
    private var lastRefill = Date()
    /// 各类别熔断截止时间
    private var breakerUntil: [Kind: Date] = [:]
    /// 各类别上一次请求完成时间（最小间隔用）
    private var lastFinishedAt: [Kind: Date] = [:]
    /// 各类别当前是否有请求在飞行中（真正的互斥；仅记录完成时间挡不住并发同时发起）
    private var busy: Set<Kind> = []

    /// 当前是否熔断中（供 UI 展示）
    func isBreakerOpen() -> Bool {
        breakerUntil.values.contains { $0 > Date() }
    }

    /// 距今最近的熔断截止时间（供 UI 展示"预计恢复"）
    func nearestBreakerDeadline() -> Date? {
        let now = Date()
        return breakerUntil.values.filter { $0 > now }.min()
    }

    // MARK: - 闸门

    /// 获取通行许可：必要时按令牌桶等待；熔断中直接抛错。
    /// 返回前已完成全部等待，调用方可立即发请求。
    ///
    /// 异常安全：占用互斥（`busy.insert`）之前不做任何可能抛错的等待，
    /// 否则中途取消会让该类别的互斥永远不被释放。
    func acquire(kind: Kind) async throws {
        // 熔断检查（被动：只由真实 429 触发）
        if config.breakerEnabled, let until = breakerUntil[kind], until > Date() {
            throw GateError.breakerOpen(kind: kind, until: until)
        }

        guard config.enabled else { return }

        // 1) 先取令牌（无状态持有，可安全抛错）
        try await waitForToken()

        // 2) 再占互斥：同类别上一次请求返回前不发下一个。
        //    单靠 lastFinishedAt 不够——并发同时发起时谁都没有完成时间，会一起放行
        //    （实测首页加载并发 3 个 friendships/show）。
        guard config.serialize else { return }
        var waited: TimeInterval = 0
        let maxWait: TimeInterval = 60
        while busy.contains(kind) {
            // 上限保护：极端情况下（请求悬挂）放行，避免该类别永久卡死
            if waited >= maxWait {
                AppLogger.warn("等待同类请求超时,放行", category: "NET", ["kind": kind.rawValue])
                break
            }
            try await sleepCancellable(0.02)
            waited += 0.02
        }
        busy.insert(kind)
    }

    /// 请求结束（成功或失败都要调用，释放互斥并记录完成时间）
    func release(kind: Kind) {
        busy.remove(kind)
        lastFinishedAt[kind] = Date()
    }

    /// 429 上报：开启该类别的熔断窗口
    func noteRateLimited(kind: Kind, retryAfter: TimeInterval?) {
        guard config.breakerEnabled else { return }
        let cooldown = retryAfter.map { min($0, TimeInterval(config.cooldownSeconds)) }
            ?? TimeInterval(config.cooldownSeconds)
        let until = Date().addingTimeInterval(max(5, cooldown))
        // 只延长不缩短，避免并发 429 互相覆盖成更早的截止时间
        if let existing = breakerUntil[kind], existing > until { return }
        breakerUntil[kind] = until
    }

    /// 手动解除全部熔断（用户点「立即恢复」）
    func resetBreakers() {
        breakerUntil.removeAll()
    }

    // MARK: - 令牌桶实现

    private func waitForToken() async throws {
        let capacity = Double(max(1, config.requestsPerWindow))
        let rate = capacity / Double(max(1, config.windowSeconds)) // 每秒补充

        while true {
            refill(capacity: capacity, rate: rate)
            if tokens >= 1 {
                tokens -= 1
                return
            }
            // 距下一个令牌的等待时间
            let deficit = 1 - tokens
            let wait = deficit / rate
            try await sleepCancellable(min(max(wait, 0.05), 5))
        }
    }

    private func refill(capacity: Double, rate: Double) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * rate)
        lastRefill = now
    }

    private func sleepCancellable(_ seconds: TimeInterval) async throws {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        } catch {
            throw CancellationError()
        }
    }
}
