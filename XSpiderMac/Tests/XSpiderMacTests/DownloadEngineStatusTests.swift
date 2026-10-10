import XCTest
@testable import XSpiderMac

/// 下载引擎选择（按文件大小）回归测试
final class EngineSelectionTests: XCTestCase {

    /// 阈值越界钳制：防止用户填 0 或超大值
    func testThresholdClamping() {
        var settings = Settings()
        settings.download.aria2SizeThresholdMB = 0
        XCTAssertEqual(settings.aria2SizeThresholdMB, 1)
        settings.download.aria2SizeThresholdMB = 99999
        XCTAssertEqual(settings.aria2SizeThresholdMB, 2048)
    }

    /// aria2 端口：默认 6801，钳制 1024–65535
    func testAria2PortDefaultsAndClamping() {
        var settings = Settings()
        XCTAssertEqual(settings.aria2Port, 6801)
        XCTAssertEqual(settings.aria2PortMode, .fixed)

        settings.download.aria2Port = 80          // 特权端口
        XCTAssertEqual(settings.aria2Port, 1024)
        settings.download.aria2Port = 99999
        XCTAssertEqual(settings.aria2Port, 65535)
    }

    /// CDN 限流设置默认值与钳制
    func testCDNSettingsDefaults() {
        var settings = Settings()
        settings.app.rateLimit = RateLimitSettings()
        XCTAssertTrue(settings.cdnThrottleEnabled)
        XCTAssertEqual(settings.cdnMaxConcurrent, 1)
        XCTAssertEqual(settings.cdnCooldownSeconds, 120)

        settings.app.rateLimit?.cdnMaxConcurrent = 0
        XCTAssertEqual(settings.cdnMaxConcurrent, 1)
        settings.app.rateLimit?.cdnCooldownSeconds = 1
        XCTAssertEqual(settings.cdnCooldownSeconds, 10)
    }

    /// 旧配置（无新字段）应回落到默认值而非解码失败
    func testLegacyDownloadSettingsDecode() throws {
        let json = #"{"download":{"saveDirBase":"/tmp","fileNameTemplate":"%POST_ID%%EXT%"}}"#
        let decoded = try JSONDecoder().decode(DownloadSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.aria2SizeThresholdMB, 5)
        XCTAssertEqual(decoded.aria2Port, 6801)
        XCTAssertEqual(decoded.engine, .aria2)
    }
}
/// CDN 状态与 API 状态相互独立（不同资源、独立状态）
final class CDNStatusTests: XCTestCase {

    override func setUp() async throws {
        await MainActor.run { TestStores.resetEphemeral() }
    }

    override func tearDown() async throws {
        await MainActor.run { TestStores.resetEphemeral() }
    }

    @MainActor
    func testCDNStateIsIndependentFromAPIState() {
        let store = AccountStatusStore.shared

        // API 正常但 CDN 限流 → 两行应分别反映
        store.noteCDNRateLimited(retryAfter: 60)
        XCTAssertTrue(store.cdnThrottled)
        XCTAssertEqual(store.effectiveHealth, .normal, "CDN 限流不应把 API 状态也标成异常")
        XCTAssertNotNil(store.cdnStatusText)

        // API 限流不应影响 CDN 行
        store.noteRateLimited(until: Date().addingTimeInterval(300))
        XCTAssertTrue(store.cdnThrottled, "API 限流不应清除 CDN 限流")
    }

    @MainActor
    func testCDNSuccessClearsThrottle() {
        let store = AccountStatusStore.shared
        store.noteCDNRateLimited(retryAfter: 60)
        XCTAssertTrue(store.cdnThrottled)
        store.noteCDNSuccess()
        XCTAssertFalse(store.cdnThrottled)
        XCTAssertNil(store.cdnStatusText)
    }

    /// CDN 失败（非限流）也应展示，便于用户区分"限流"与"资源不存在"
    @MainActor
    func testCDNFailureIsReported() {
        let store = AccountStatusStore.shared
        store.noteCDNFailure("HTTP 404")
        XCTAssertFalse(store.cdnThrottled)
        XCTAssertNotNil(store.cdnStatusText)
        XCTAssertTrue(store.cdnStatusText?.contains("404") ?? false)
    }

    /// 限流冷却只延长不退步（并发 429 不应互相覆盖成更短的等待）
    @MainActor
    func testCDNCooldownOnlyExtends() {
        let store = AccountStatusStore.shared
        store.noteCDNRateLimited(retryAfter: 300)
        let first = store.cdnRateLimitedUntil
        store.noteCDNRateLimited(retryAfter: 10)
        let second = store.cdnRateLimitedUntil
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        if let first, let second {
            XCTAssertGreaterThanOrEqual(second, first.addingTimeInterval(-1))
        }
    }

    // MARK: - 恢复必须唤醒下载队列（曾静默卡住的缺口）

    /// 限流到期时必须触发恢复回调。
    /// 回归：早前 refreshCDNExpiry 只清标记、不通知队列 → 并发上限虽恢复，
    /// waiting 任务却无人拉起，队列静默卡住直到用户下次操作。
    @MainActor
    func testExpiryNotifiesRecovery() {
        let store = AccountStatusStore.shared
        var notified = 0
        store.onCDNRecovered = { notified += 1 }
        defer { store.onCDNRecovered = nil }

        store.noteCDNRateLimited(retryAfter: nil)
        store.setCDNThrottleDeadlineForTesting(Date().addingTimeInterval(-1))  // 构造已过期
        store.refreshCDNExpiry()
        XCTAssertFalse(store.cdnThrottled)
        XCTAssertEqual(notified, 1, "到期恢复必须通知下载队列（否则等待任务卡住）")
    }

    /// 任务成功确认 CDN 正常时也必须通知
    @MainActor
    func testSuccessNotifiesRecovery() {
        let store = AccountStatusStore.shared
        var notified = 0
        store.onCDNRecovered = { notified += 1 }
        defer { store.onCDNRecovered = nil }

        store.noteCDNRateLimited(retryAfter: 60)
        store.noteCDNSuccess()
        XCTAssertEqual(notified, 1, "成功恢复必须通知下载队列")
    }

    /// 未处于限流时不应触发恢复回调（避免无谓的 pump）
    @MainActor
    func testNoRecoveryCallbackWhenNotThrottled() {
        let store = AccountStatusStore.shared
        var notified = 0
        store.onCDNRecovered = { notified += 1 }
        defer { store.onCDNRecovered = nil }

        store.noteCDNSuccess()   // 本来就没限流
        store.refreshCDNExpiry() // 本来就没到期状态
        XCTAssertEqual(notified, 0)
    }

    /// 用户点重试：即使随后探测失败，也应先解除限流并唤醒一次
    /// （用户明确表达"别再拦我"）
    @MainActor
    func testProbeClearsThrottleAndNotifies() async {
        let store = AccountStatusStore.shared
        store.noteCDNRateLimited(retryAfter: 3600)
        XCTAssertTrue(store.cdnThrottled)

        // 不等待网络结果，只验证"先解除 + 通知"这一步的语义
        var notified = 0
        store.onCDNRecovered = { notified += 1 }
        defer { store.onCDNRecovered = nil }

        // probeCDN 会真发一次网络请求；测试环境可能失败，但解除与通知必须先发生
        await store.probeCDN()
        XCTAssertFalse(store.cdnThrottled, "用户重试应立即解除限流")
        XCTAssertGreaterThanOrEqual(notified, 1, "用户重试应唤醒队列")
    }
}
/// 判定依据的语义契约（重构后见 `MEDIA_RECORDS.md` §6；旧的"自动追加序号"已删除）
final class JudgmentSemanticsTests: XCTestCase {

    private func media(_ id: String) -> TwitterMedia {
        TwitterMedia(id: id, url: "https://pbs.twimg.com/media/\(id).jpg",
                     width: 100, height: 100, type: .photo, videoInfo: nil, createdTime: nil)
    }

    private func post(id: String, mediaIds: [String]) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1", mediaCount: nil, registerTime: nil),
                    createdAt: nil, fullText: nil, tags: [], views: nil, lang: nil,
                    retweeted: nil, retweetCount: nil, replyCount: nil, possiblySensitive: nil,
                    favorited: nil, favoriteCount: nil, bookmarkCount: nil, bookmarked: nil,
                    medias: mediaIds.map(media))
    }

    @MainActor
    private func store() -> DownloadStore { DownloadStore.shared }

    /// 唯一标识在扩展名前、用 `[ ]` 包裹（同推文多张媒体因此互不覆盖）
    func testUniqueIdSuffixKeepsMediaDistinct() {
        let p = post(id: "123", mediaIds: ["m1", "m2"])
        let n1 = MediaJudgement.appendingUniqueId("123.jpg", mediaId: p.medias?[0].id)
        let n2 = MediaJudgement.appendingUniqueId("123.jpg", mediaId: p.medias?[1].id)
        XCTAssertEqual(n1, "123[m1].jpg")
        XCTAssertEqual(n2, "123[m2].jpg")
        XCTAssertNotEqual(n1, n2, "同推文多张媒体必须得到不同文件名（否则判定只认第一个）")
    }

    /// 不再自动追加序号：模板解析结果 + 唯一标识，没有 `-1` / ` 1` 这种自动编号
    func testNoAutomaticIndexSuffix() {
        let p = post(id: "123", mediaIds: ["m1"])
        let name = MediaJudgement.fileName(post: p, media: p.medias![0],
                                           template: "%POST_ID%%EXT%", appendUniqueId: false)
        XCTAssertEqual(name, "123.jpg", "关闭唯一标识时不得自动补序号")
        let withId = MediaJudgement.fileName(post: p, media: p.medias![0],
                                             template: "%POST_ID%%EXT%", appendUniqueId: true)
        XCTAssertEqual(withId, "123[m1].jpg")
    }

    /// 判定版本号必须可自增（视图依赖它重算按钮状态）
    @MainActor
    func testJudgementVersionBumps() {
        let s = store()
        let before = s.judgementVersion
        s.invalidateJudgements()
        XCTAssertGreaterThan(s.judgementVersion, before,
                             "切换判定依据必须自增版本号，否则媒体卡按钮状态不更新")
    }

    /// `refreshDownloadedCaches` 与 `invalidateJudgements` 语义 =
    /// 失效记录层缓存 + judgementVersion++（后续阶段依赖这两个名字）
    @MainActor
    func testRefreshCachesInvalidatesAndBumps() {
        let s = store()
        let before = s.judgementVersion
        s.refreshDownloadedCaches()
        XCTAssertGreaterThan(s.judgementVersion, before)
    }
}
