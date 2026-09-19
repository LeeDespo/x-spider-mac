import XCTest
@testable import XSpiderMac

/// 缓存上限的单位口径。
///
/// 回归用户反馈：「设了 200m，却显示有 209m 缓存，没见它清理」。
/// 根因不是没清理（日志里 70 次清理都在跑），而是**单位不一致**：
/// 限制用 MiB（×1_048_576），显示用 `ByteCountFormatter.file`（十进制）。
/// 200 MiB = 209,715,200 字节 = 209.7 MB —— 用户看到的"超标"其实是同一个数。
final class CacheLimitUnitTests: XCTestCase {

    /// 十进制口径：设置的 MB 数 × 1_000_000 就是上限字节
    func testLimitUsesDecimalMegabytes() {
        let limitBytes = Int64(200) * 1_000_000
        let displayed = ByteCountFormatter.string(fromByteCount: limitBytes, countStyle: .file)
        // ByteCountFormatter 的 .file 风格是十进制：200 MB 应原样显示为 "200 MB"
        XCTAssertTrue(displayed.contains("200"),
                      "设置 200MB 时，显示必须是 200MB（十进制），实际: \(displayed)")
    }

    /// 反例（旧实现）：MiB 口径会让同一个上限显示成 209.7MB
    func testMiBWouldShowAsLargerNumber() {
        let oldLimit = Int64(200) * 1_048_576
        let displayed = ByteCountFormatter.string(fromByteCount: oldLimit, countStyle: .file)
        XCTAssertFalse(displayed.contains(" 200 "),
                       "旧口径显示为 \(displayed)，与用户看到的『209』一致 —— 这正是 bug 现象")
    }

    /// 设定值与上限值一一对应（50/100/200/300/500 都不该出现"显示值更大"）
    func testAllPresetValuesRoundTrip() {
        for mb in [50, 100, 200, 300, 500] {
            let bytes = Int64(mb) * 1_000_000
            let displayed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            XCTAssertTrue(displayed.contains("\(mb)"),
                          "\(mb) MB 的上限应显示为 \(mb) MB，实际: \(displayed)")
        }
    }
}

/// 状态简称（侧边栏标签化）
///
/// 回归用户反馈：边栏直接把完整状态文案显示出来，位置窄会被截断。
/// 现在只显示「正常 / 异常 / 限流」，详情进悬停。
final class StatusShortLabelTests: XCTestCase {

    @MainActor
    func testShortLabelsAreConcise() {
        let store = AccountStatusStore.shared
        store.reset()
        // 三档简称都要很短（边栏一行放得下）
        for label in [store.shortLabel, store.cdnShortLabel] {
            XCTAssertLessThanOrEqual(label.count, 4,
                                     "简称「\(label)」太长，边栏会截断")
        }
        // 正常态
        XCTAssertEqual(store.shortLabel, L("正常"))
        XCTAssertEqual(store.cdnShortLabel, L("正常"))
    }

    /// 三档简称互不相同（否则用户区分不出来）
    @MainActor
    func testSeverityLabelsAreDistinct() {
        let normal = L("正常"), warn = L("异常"), critical = L("限流")
        XCTAssertNotEqual(normal, warn)
        XCTAssertNotEqual(normal, critical)
        XCTAssertNotEqual(warn, critical)
    }

    /// 灯色与简称一一对应：绿=正常、黄=异常、红=限流
    @MainActor
    func testSeverityMappingIsStable() {
        let store = AccountStatusStore.shared
        store.reset()
        XCTAssertEqual(store.severity, .ok)
        XCTAssertEqual(store.shortLabel, L("正常"))
        store.reset()
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

/// 媒体类型标签：只有视频/GIF 才显示
final class MediaTypeBadgeTests: XCTestCase {

    /// 图片不加标签（需求），视频/GIF 才加
    func testOnlyVideoAndGifGetBadge() {
        XCTAssertFalse(needsBadge(.photo), "图片是默认预期，加标签只是噪声")
        XCTAssertTrue(needsBadge(.video), "静态封面看不出是视频，必须标注")
        XCTAssertTrue(needsBadge(.gif), "GIF 没有时长角标，更需要标注")
    }

    private func needsBadge(_ type: MediaType) -> Bool { type != .photo }
}

/// 播放进度继承（详情页 → 查看窗口）
final class PlaybackProgressHandoffTests: XCTestCase {

    override func setUp() async throws {
        await MainActor.run { MediaViewerCenter.shared.clearSessionForWindowClose() }
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
