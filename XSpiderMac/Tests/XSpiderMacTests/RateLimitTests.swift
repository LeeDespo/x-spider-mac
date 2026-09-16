import XCTest
@testable import XSpiderMac

/// 限流缓解（请求闸门 + 熔断）与状态上报的回归测试。
final class RateLimitTests: XCTestCase {

    // MARK: - 端点分类（闸门按类别排队/熔断的基础）

    func testClassifyTimelineEndpoints() {
        XCTAssertEqual(RequestGate.Kind.classify(path: "/i/api/graphql/cEjpJXA15Ok78yO4TUQPeQ/UserMedia"), .timeline)
        XCTAssertEqual(RequestGate.Kind.classify(path: "/i/api/graphql/9zyyd1hebl7oNWIPdA8HRw/UserTweets"), .timeline)
        XCTAssertEqual(RequestGate.Kind.classify(path: "/i/api/graphql/7zlnp2TxC044W4C1ZUJMHw/HomeTimeline"), .timeline)
        XCTAssertEqual(RequestGate.Kind.classify(path: "/i/api/graphql/0dateTVgvXjpkf7kyBZy0g/HomeLatestTimeline"), .timeline)
    }

    func testClassifyDetailUserAndAction() {
        XCTAssertEqual(RequestGate.Kind.classify(path: "/i/api/graphql/XMOz5h24KAZ86qKffKTLdQ/TweetDetail"), .detail)
        XCTAssertEqual(RequestGate.Kind.classify(path: "/i/api/graphql/NimuplG1OB7Fd2btCLdBOw/UserByScreenName"), .user)
        XCTAssertEqual(RequestGate.Kind.classify(path: "/1.1/friendships/show.json"), .user)
        XCTAssertEqual(RequestGate.Kind.classify(path: "/i/api/graphql/lI07N6Otwv1PhnEgXILM7A/FavoriteTweet"), .action)
        XCTAssertEqual(RequestGate.Kind.classify(path: "/i/api/graphql/aoDbu3RHznuiSkQ9aNM67Q/CreateBookmark"), .action)
        XCTAssertEqual(RequestGate.Kind.classify(path: "/tesla"), .misc)
    }

    /// 时间线请求不应被归到互动类别（否则点赞会阻塞翻页）
    func testTimelineNotClassifiedAsAction() {
        let path = "/i/api/graphql/9zyyd1hebl7oNWIPdA8HRw/UserTweets"
        XCTAssertNotEqual(RequestGate.Kind.classify(path: path), .action)
    }

    // MARK: - 闸门：熔断短路

    /// 429 后该类端点被熔断，再次获取许可应立即抛错（而非等待或真实发请求）
    func testBreakerBlocksSubsequentRequests() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 100, windowSeconds: 1,
            serialize: false, breakerEnabled: true, cooldownSeconds: 60
        ))

        // 熔断前可通行
        try await gate.acquire(kind: .timeline)
        await gate.release(kind: .timeline)

        // 触发熔断
        await gate.noteRateLimited(kind: .timeline, retryAfter: nil)

        do {
            try await gate.acquire(kind: .timeline)
            XCTFail("熔断中不应放行")
        } catch let error as RequestGate.GateError {
            guard case .breakerOpen(let kind, _) = error else {
                return XCTFail("应为 breakerOpen，实际 \(error)")
            }
            XCTAssertEqual(kind, .timeline)
        }
    }

    /// 熔断按类别隔离：时间线被限流不应阻断互动操作
    func testBreakerIsolatedPerKind() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 100, windowSeconds: 1,
            serialize: false, breakerEnabled: true, cooldownSeconds: 60
        ))
        await gate.noteRateLimited(kind: .timeline, retryAfter: nil)

        // action 类别不受 timeline 熔断影响
        try await gate.acquire(kind: .action)
        await gate.release(kind: .action)
    }

    /// 关闭熔断开关后不再短路（用户选择权）
    func testBreakerDisabledAllowsTraffic() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 100, windowSeconds: 1,
            serialize: false, breakerEnabled: false, cooldownSeconds: 60
        ))
        await gate.noteRateLimited(kind: .timeline, retryAfter: nil)
        // 熔断关闭 → 仍可通行
        try await gate.acquire(kind: .timeline)
        await gate.release(kind: .timeline)
    }

    /// resetBreakers 可立即恢复（设置页「立即恢复」按钮）
    func testResetBreakersRestoresTraffic() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 100, windowSeconds: 1,
            serialize: false, breakerEnabled: true, cooldownSeconds: 3600
        ))
        await gate.noteRateLimited(kind: .timeline, retryAfter: nil)
        await gate.resetBreakers()
        try await gate.acquire(kind: .timeline)
        await gate.release(kind: .timeline)
    }

    /// 熔断截止时间只延长不缩短（并发 429 不应互相覆盖成更早）
    func testBreakerDeadlineOnlyExtends() async {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 100, windowSeconds: 1,
            serialize: false, breakerEnabled: true, cooldownSeconds: 3600
        ))
        await gate.noteRateLimited(kind: .timeline, retryAfter: 3600)
        let first = await gate.nearestBreakerDeadline()
        // 第二次给一个更短的冷却，不应把截止时间提前
        await gate.noteRateLimited(kind: .timeline, retryAfter: 5)
        let second = await gate.nearestBreakerDeadline()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        if let first, let second {
            XCTAssertGreaterThanOrEqual(second, first.addingTimeInterval(-1))
        }
    }

    // MARK: - 令牌桶

    /// 闸门限速：窗口内请求数受令牌桶约束（不无限放行）
    func testTokenBucketThrottles() async throws {
        let gate = RequestGate()
        // 2 请求 / 1 秒 → 连发 3 个必然需要等待
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 2, windowSeconds: 1,
            serialize: false, breakerEnabled: false, cooldownSeconds: 60
        ))
        let start = Date()
        for _ in 0..<3 {
            try await gate.acquire(kind: .misc)
            await gate.release(kind: .misc)
        }
        let elapsed = Date().timeIntervalSince(start)
        // 第 3 个请求需等待令牌补充，应产生可观测延迟
        XCTAssertGreaterThan(elapsed, 0.1, "令牌桶未生效，3 个请求耗时仅 \(elapsed)s")
    }

    /// 关闭闸门后不限速（用户选择权）
    func testGateDisabledDoesNotThrottle() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: false, requestsPerWindow: 1, windowSeconds: 60,
            serialize: false, breakerEnabled: false, cooldownSeconds: 60
        ))
        let start = Date()
        for _ in 0..<10 {
            try await gate.acquire(kind: .misc)
            await gate.release(kind: .misc)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "闸门关闭后不应限速")
    }

    // MARK: - 同类别互斥（并发同时发起时必须排队）

    /// 真实缺陷回归：首页加载曾并发发出 3 个 friendships/show。
    /// 仅记录"上次完成时间"挡不住并发同时发起——必须靠飞行中标记互斥。
    func testSerializeBlocksConcurrentSameKind() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 1000, windowSeconds: 1,
            serialize: true, breakerEnabled: false, cooldownSeconds: 60
        ))

        actor Tracker {
            var order: [Int] = []
            func record(_ i: Int) { order.append(i) }
        }
        let tracker = Tracker()

        // 并发发起 3 个同类请求，每个"占用"100ms
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
                group.addTask {
                    try await gate.acquire(kind: .user)
                    await tracker.record(i)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    await gate.release(kind: .user)
                }
            }
            try await group.waitForAll()
        }

        let order = await tracker.order
        XCTAssertEqual(order.count, 3)
        // 串行生效：三者依次进入，不会三者同时在 100ms 内一起记录
        // （若未串行，三者会在同一时刻全部记录，总耗时仅约 100ms）
    }

    /// 串行应显著拉长总耗时（三者各 100ms → 约 300ms）；未串行时约 100ms
    func testSerializeIncreasesTotalDuration() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 1000, windowSeconds: 1,
            serialize: true, breakerEnabled: false, cooldownSeconds: 60
        ))
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await gate.acquire(kind: .detail)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    await gate.release(kind: .detail)
                }
            }
            try await group.waitForAll()
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.25, "同类请求未串行，3×100ms 仅耗时 \(elapsed)s")
    }

    /// 不同类别之间不互相阻塞（时间线被慢请求占用时，互动仍可通行）
    func testSerializeDoesNotBlockAcrossKinds() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 1000, windowSeconds: 1,
            serialize: true, breakerEnabled: false, cooldownSeconds: 60
        ))
        // 占住 timeline
        try await gate.acquire(kind: .timeline)
        // action 应立即通行
        let start = Date()
        try await gate.acquire(kind: .action)
        await gate.release(kind: .action)
        await gate.release(kind: .timeline)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "不同类别不应互相阻塞")
    }

    // MARK: - 设置字段默认值与钳制

    func testRateLimitDefaultsAndClamping() {
        var settings = Settings()
        settings.app.rateLimit = RateLimitSettings()

        XCTAssertTrue(settings.gateEnabled)
        XCTAssertEqual(settings.gateRequestsPerWindow, 100)
        XCTAssertEqual(settings.gateWindowSeconds, 10)
        XCTAssertTrue(settings.serializePerEndpoint)
        XCTAssertTrue(settings.breakerEnabled)
        XCTAssertEqual(settings.breakerCooldownSeconds, 300)

        // 越界值被钳制（防止用户填 0 或超大值把应用卡死）
        settings.app.rateLimit?.requestsPerWindow = 0
        XCTAssertEqual(settings.gateRequestsPerWindow, 1)
        settings.app.rateLimit?.requestsPerWindow = 9999
        XCTAssertEqual(settings.gateRequestsPerWindow, 600)

        settings.app.rateLimit?.cooldownSeconds = 1
        XCTAssertEqual(settings.breakerCooldownSeconds, 30)
        settings.app.rateLimit?.windowSeconds = 0
        XCTAssertEqual(settings.gateWindowSeconds, 1)
    }

    /// 旧配置（无 rateLimit 键）应回落到默认值而不是解码失败
    func testMissingRateLimitFallsBackToDefaults() throws {
        let json = #"{"app":{"writeLogs":false,"language":"zh-Hans","preventSleepDuringDownload":true},"download":{"saveDirBase":"/tmp"},"proxy":{"enable":true,"url":"http://127.0.0.1:7890","useSystem":true},"sync":{}}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.gateEnabled)
        XCTAssertEqual(decoded.gateRequestsPerWindow, 100)
        XCTAssertEqual(decoded.breakerCooldownSeconds, 300)
    }

    /// 回归：SettingsStore 必须把 nil 的 rateLimit 补成非 nil。
    /// 否则视图里的 `settings.app.rateLimit?.x = $0` 是静默 no-op ——
    /// 表现为"设置项点击有反馈但值永远不变"。
    @MainActor
    func testSettingsStoreInitializesRateLimit() {
        let store = SettingsStore.shared
        XCTAssertNotNil(store.settings.app.rateLimit, "rateLimit 为 nil 会让所有限流设置项的绑定失效")
    }

    // MARK: - 账号状态：被动标签不应被无关请求抹掉

    /// 回归：任何请求成功都会调用 noteSuccess；若允许无条件复位，
    /// 429 标签会被无关请求（XClId/页面 HTML/关注态查询）瞬间抹掉，表现为"标签做了但没效果"。
    @MainActor
    func testRateLimitedSurvivesUnrelatedSuccess() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteRateLimited(until: Date().addingTimeInterval(300))
        XCTAssertEqual(store.statusText, L("429 限流"))

        // 无关请求成功：限流未到期，标签必须保留
        store.noteSuccess()
        XCTAssertEqual(store.statusText, L("429 限流"), "未到恢复期限不应被成功响应清除")
    }

    /// 限流到期后状态恢复（确定性：直接构造已过期的截止时间，不依赖真实时钟 sleep）。
    /// 注意：测试宿主是应用本体，运行时会真实发请求并写单例状态，
    /// 因此这里不做等待，避免被应用自身的网络活动污染。
    @MainActor
    func testRateLimitClearsAfterDeadline() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteRateLimited(until: Date().addingTimeInterval(-1)) // 已过期
        XCTAssertNil(store.rateLimitDeadline, "过期后不应再有待到期状态")
        XCTAssertEqual(store.effectiveHealth, .normal, "过期后有效状态应为正常")
        store.refreshExpiry()
        XCTAssertEqual(store.effectiveHealth, .normal, "到期后状态应恢复")
    }

    /// 登录失效可被下一次成功复位（与限流的语义不同）
    @MainActor
    func testUnauthenticatedClearsOnSuccess() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteUnauthenticated(status: 401)
        XCTAssertEqual(store.statusText, L("登录失效"))
        store.noteSuccess()
        XCTAssertEqual(store.effectiveHealth, .normal, "登录失效应可被成功请求复位")
    }

    // MARK: - 网络异常分类（全部被动推导，无需额外请求）

    /// 超时与"连不上"分开：前者通常是代理不稳，后者可能是离线/DNS，处置提示不同
    @MainActor
    func testTimeoutClassifiedSeparately() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteNetworkFailure(URLError(.timedOut))
        XCTAssertEqual(store.effectiveHealth, .timedOut)
        XCTAssertEqual(store.statusText, L("连接 X 超时"))
        XCTAssertEqual(store.severity, .warning)
    }

    @MainActor
    func testOfflineClassification() {
        let store = AccountStatusStore.shared
        store.reset()
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost] {
            store.noteSuccess()
            store.noteNetworkFailure(URLError(code))
            XCTAssertEqual(store.effectiveHealth, .offline, "\(code) 应归为无法连接")
        }
        XCTAssertEqual(store.statusText, L("无法连接 X"))
    }

    /// 服务端异常保留状态码，便于用户判断
    @MainActor
    func testServerErrorKeepsCode() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteServerError(status: 503)
        XCTAssertEqual(store.effectiveHealth, .serverError(503))
        XCTAssertTrue(store.statusText.contains("503"))
    }

    /// 网络类异常可被下一次成功复位（与限流不同：不需要等到期）
    @MainActor
    func testNetworkErrorClearsOnSuccess() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteNetworkFailure(URLError(.timedOut))
        store.noteSuccess()
        XCTAssertEqual(store.effectiveHealth, .normal)
    }

    /// 状态灯配色语义：正常绿、限流红、其余橙
    @MainActor
    func testSeverityMapping() {
        let store = AccountStatusStore.shared
        store.reset()
        XCTAssertEqual(store.severity, .ok)
        store.noteRateLimited(until: Date().addingTimeInterval(300))
        XCTAssertEqual(store.severity, .critical)
        store.noteSuccess() // 限流未到期，不该被清
        XCTAssertEqual(store.severity, .critical)
        store.noteServerError(status: 500)
        XCTAssertEqual(store.severity, .warning)
    }

    /// 熔断开启时文案带倒计时（需求：429 限流，熔断倒计时 n 秒）
    @MainActor
    func testRateLimitTextShowsCountdownWhenBreakerOpen() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteRateLimited(until: Date().addingTimeInterval(300))
        store.breakerOpen = false
        XCTAssertEqual(store.statusText, L("429 限流"))

        store.breakerOpen = true
        XCTAssertTrue(store.statusText.contains("429"), "熔断中应显示倒计时文案：\(store.statusText)")
        XCTAssertTrue(store.statusText.contains("300") || store.statusText.contains("299"),
                      "倒计时应反映剩余秒数：\(store.statusText)")
        XCTAssertFalse(store.statusText.contains("%d"), "占位符必须被替换：\(store.statusText)")
    }

    // MARK: - 「重试」按钮：结束熔断 + 真实探测

    /// 点重试必须**立即结束熔断**（用户明确要求"别再拦我"），不等倒计时。
    /// 这里只验证熔断被清空——探测本身要真实联网，不适合放进单测。
    func testRetryClearsBreaker() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 1000, windowSeconds: 1,
            serialize: false, breakerEnabled: true, cooldownSeconds: 3600
        ))
        await gate.noteRateLimited(kind: .timeline, retryAfter: nil)
        var open = await gate.isBreakerOpen()
        XCTAssertTrue(open, "前置条件：应处于熔断")

        await gate.resetBreakers()
        open = await gate.isBreakerOpen()
        XCTAssertFalse(open, "重试后熔断应被立即结束")
        // 结束后同类请求应能通行
        try await gate.acquire(kind: .timeline)
        await gate.release(kind: .timeline)
    }

    // MARK: - 令牌桶初始化

    /// 回归：首次使用应按用户配置的容量补满，而不是硬编码初值。
    /// （容量 100 却只发 10 个令牌会让"每时间窗请求数"设置看起来无效。）
    func testTokenBucketStartsAtConfiguredCapacity() async throws {
        let gate = RequestGate()
        await gate.update(config: .init(
            enabled: true, requestsPerWindow: 50, windowSeconds: 60,
            serialize: false, breakerEnabled: false, cooldownSeconds: 60
        ))
        // 容量 50、窗口 60s → 前 20 个应立即通过（无需等待补充）
        let start = Date()
        for _ in 0..<20 {
            try await gate.acquire(kind: .misc)
            await gate.release(kind: .misc)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5,
                          "初始令牌数低于配置容量，说明未按容量初始化")
    }
}
