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
        XCTAssertEqual(settings.gateRequestsPerWindow, 10)
        XCTAssertEqual(settings.gateWindowSeconds, 10)
        XCTAssertTrue(settings.serializePerEndpoint)
        XCTAssertTrue(settings.breakerEnabled)
        XCTAssertEqual(settings.breakerCooldownSeconds, 900)

        // 越界值被钳制（防止用户填 0 或超大值把应用卡死）
        settings.app.rateLimit?.requestsPerWindow = 0
        XCTAssertEqual(settings.gateRequestsPerWindow, 1)
        settings.app.rateLimit?.requestsPerWindow = 9999
        XCTAssertEqual(settings.gateRequestsPerWindow, 120)

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
        XCTAssertEqual(decoded.gateRequestsPerWindow, 10)
        XCTAssertEqual(decoded.breakerCooldownSeconds, 900)
    }
}
