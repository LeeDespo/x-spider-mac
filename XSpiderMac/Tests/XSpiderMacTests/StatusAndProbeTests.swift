import XCTest
@testable import XSpiderMac

/// 状态简称（侧边栏标签化）
///
/// 回归用户反馈：边栏直接把完整状态文案显示出来，位置窄会被截断。
/// 现在只显示「正常 / 异常 / 限流」，详情进悬停。
///
/// 下面的长度断言是**代理指标**（真正的截断取决于实际布局与字体），
/// 属纯逻辑冒烟，不等价于界面验收。
final class StatusShortLabelTests: XCTestCase {

    override func setUp() async throws {
        await MainActor.run { TestStores.resetEphemeral() }
    }

    override func tearDown() async throws {
        await MainActor.run { TestStores.resetEphemeral() }
    }

    @MainActor
    func testShortLabelsAreConcise() {
        let store = AccountStatusStore.shared
        // 三档简称都要很短（边栏一行放得下）
        for label in [store.shortLabel, store.cdnShortLabel] {
            XCTAssertLessThanOrEqual(label.count, 4,
                                     "简称「\(label)」太长，边栏会截断")
        }
        // 正常态
        XCTAssertEqual(store.shortLabel, L("正常"))
        XCTAssertEqual(store.cdnShortLabel, L("正常"))
    }

    /// 熔断（critical）时简称必须是「限流」，且仍是短标签
    @MainActor
    func testRateLimitedShortLabel() {
        let store = AccountStatusStore.shared
        store.noteRateLimited(until: Date().addingTimeInterval(300))
        XCTAssertEqual(store.shortLabel, L("限流"))
        XCTAssertLessThanOrEqual(store.shortLabel.count, 4, "行内文案要放得进边栏")
    }
}
/// 主动检测间隔的钳制
final class ActiveProbeIntervalTests: XCTestCase {

    /// 最低 5 秒：更短会被 X 视为异常流量（需求明确要求下限）
    func testIntervalFloorIsFiveSeconds() {
        var s = Settings()
        s.app.activeStatusProbeInterval = 1
        XCTAssertEqual(s.activeStatusProbeIntervalSeconds, 5, "低于下限必须钳到 5 秒")

        s.app.activeStatusProbeInterval = 0
        XCTAssertEqual(s.activeStatusProbeIntervalSeconds, 5)

        s.app.activeStatusProbeInterval = -100
        XCTAssertEqual(s.activeStatusProbeIntervalSeconds, 5)
    }

    func testIntervalDefaultIsThirty() {
        var s = Settings()
        s.app.activeStatusProbeInterval = nil
        XCTAssertEqual(s.activeStatusProbeIntervalSeconds, 30, "默认 30 秒")
    }

    func testValidIntervalPassesThrough() {
        var s = Settings()
        s.app.activeStatusProbeInterval = 60
        XCTAssertEqual(s.activeStatusProbeIntervalSeconds, 60)
    }

    /// 主动检测默认**开启**
    func testProbeEnabledByDefault() {
        var s = Settings()
        s.app.activeStatusProbe = nil
        XCTAssertTrue(s.activeStatusProbeEnabled, "默认开启（nil 视为开）")
        s.app.activeStatusProbe = false
        XCTAssertFalse(s.activeStatusProbeEnabled)
    }

    /// 下载提示框默认**显示**
    func testDownloadTipShownByDefault() {
        var s = Settings()
        s.app.showDownloadTip = nil
        XCTAssertTrue(s.showDownloadTipEnabled, "默认显示（nil 视为显示）")
        s.app.showDownloadTip = false
        XCTAssertFalse(s.showDownloadTipEnabled)
    }
}
/// 播放进度继承（详情页 → 查看窗口）
final class PlaybackProgressHandoffTests: XCTestCase {

    override func setUp() async throws {
        await MainActor.run { TestStores.resetEphemeral() }
    }

    @MainActor
    func testProgressIsRememberedAndRestored() {
        let center = MediaViewerCenter.shared
        let url = "https://video.twimg.com/x/1.mp4"
        XCTAssertEqual(center.resumeTime(forMediaId: url), 0, "无记录应从 0 开始")

        center.rememberProgress(mediaId: url, seconds: 42.5)
        XCTAssertEqual(center.resumeTime(forMediaId: url), 42.5,
                       "查看窗口应继承详情页的进度")

        center.clearProgress(mediaId: url)
        XCTAssertEqual(center.resumeTime(forMediaId: url), 0)
    }

    /// 0 或负值不记录（避免"刚打开就记住 0"覆盖掉真实进度）
    @MainActor
    func testZeroProgressIsNotRemembered() {
        let center = MediaViewerCenter.shared
        let url = "https://video.twimg.com/x/2.mp4"
        center.rememberProgress(mediaId: url, seconds: 0)
        XCTAssertEqual(center.resumeTime(forMediaId: url), 0)
    }

    /// nil 键不崩溃
    @MainActor
    func testNilMediaIdIsSafe() {
        let center = MediaViewerCenter.shared
        center.rememberProgress(mediaId: "", seconds: 10)
        XCTAssertEqual(center.resumeTime(forMediaId: nil), 0)
        center.clearProgress(mediaId: nil)
    }
}

// MARK: - F-defaults：新默认值与一次性覆盖
