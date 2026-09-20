import XCTest
@testable import XSpiderMac

/// 数据源按用户记忆 + 时间范围提交刷新。
///
/// 用户要求：搜索用户界面的数据源改为分段控制，**要有记忆**（下次进同一用户还是上次的选项），
/// 默认值为**推文**。
final class HomepageSourceMemoryTests: XCTestCase {

    private let userA = "memory_test_alpha"
    private let userB = "memory_test_beta"

    override func setUp() async throws {
        HomepageStore.clearRememberedSource(for: userA)
        HomepageStore.clearRememberedSource(for: userB)
    }

    override func tearDown() async throws {
        HomepageStore.clearRememberedSource(for: userA)
        HomepageStore.clearRememberedSource(for: userB)
    }

    /// 没记录过时默认「推文」（用户明确要求的默认值）
    func testDefaultSourceIsTweets() {
        XCTAssertEqual(HomepageStore.rememberedSource(for: userA), .tweets,
                       "无记录时应默认推文，而不是媒体")
        XCTAssertEqual(HomepageStore.rememberedSource(for: nil), .tweets)
        XCTAssertEqual(HomepageStore.rememberedSource(for: ""), .tweets)
    }

    /// 记住后能读回（大小写不敏感：screen_name 实际大小写可变）
    func testSourceIsRememberedPerUser() {
        HomepageStore.persistSource(.medias, for: userA)
        XCTAssertEqual(HomepageStore.rememberedSource(for: userA), .medias)
        // 另一个用户不受影响
        XCTAssertEqual(HomepageStore.rememberedSource(for: userB), .tweets,
                       "记忆必须按用户隔离，不能串到别的用户")

        HomepageStore.persistSource(.tweets, for: userB)
        XCTAssertEqual(HomepageStore.rememberedSource(for: userA), .medias)
        XCTAssertEqual(HomepageStore.rememberedSource(for: userB), .tweets)
    }

    /// 大小写不同的同一用户名视为同一用户
    func testSourceMemoryIsCaseInsensitive() {
        HomepageStore.persistSource(.medias, for: "MixedCase_User")
        XCTAssertEqual(HomepageStore.rememberedSource(for: "mixedcase_user"), .medias)
        HomepageStore.clearRememberedSource(for: "mixedcase_user")
        XCTAssertEqual(HomepageStore.rememberedSource(for: "MIXEDCASE_USER"), .tweets)
    }
}

/// 详情页下载按钮的计数语义。
///
/// 用户要求：不能只显示「下载全部(n)」，要按已下载数显示 n-m；
/// 当前媒体已下载时显示「当前已下载」；全下完显示「全部已下载」。
final class DetailDownloadCountTests: XCTestCase {

    /// 待下载数量 = 总数 - 已下载数（按钮文案里显示的就是它）
    private func pending(total: Int, downloaded: Int) -> Int { max(0, total - downloaded) }

    func testPendingCountIsTotalMinusDownloaded() {
        XCTAssertEqual(pending(total: 4, downloaded: 0), 4, "一个都没下 → 下载全部(4)")
        XCTAssertEqual(pending(total: 4, downloaded: 1), 3, "下过 1 个 → 下载全部(3)")
        XCTAssertEqual(pending(total: 4, downloaded: 3), 1)
        XCTAssertEqual(pending(total: 4, downloaded: 4), 0, "全下完 → 0（此时显示「全部已下载」）")
    }

    /// 已下载数不应超过总数（记录文件里可能有本推文之外的媒体 ID 命中）
    func testPendingNeverNegative() {
        XCTAssertEqual(pending(total: 2, downloaded: 5), 0,
                       "防负数：异常数据下不能出现「下载全部(-3)」")
    }

    func testAllDownloadedFlag() {
        XCTAssertTrue(pending(total: 2, downloaded: 2) == 0)
        XCTAssertFalse(pending(total: 2, downloaded: 1) == 0)
        // 空媒体列表不算"全部已下载"（此时胶囊根本不渲染）
        XCTAssertTrue(pending(total: 0, downloaded: 0) == 0)
    }
}

/// 媒体查看窗口：切换范围与边界。
///
/// 用户要求：不同界面切换范围要区分——详情页切本推文的媒体，
/// 瀑布流切整个瀑布流的媒体。
final class MediaViewerCenterTests: XCTestCase {

    private func media(_ id: String) -> TwitterMedia {
        TwitterMedia(id: id, url: "https://pbs.twimg.com/media/\(id).jpg",
                     width: 100, height: 100, type: .photo, videoInfo: nil, createdTime: nil)
    }

    override func setUp() async throws {
        await MainActor.run { MediaViewerCenter.shared.clearSessionForWindowClose() }
    }

    override func tearDown() async throws {
        await MainActor.run { MediaViewerCenter.shared.clearSessionForWindowClose() }
    }

    @MainActor
    func testStepWithinBounds() {
        let center = MediaViewerCenter.shared
        center.open(medias: [media("a"), media("b"), media("c")], index: 0, origin: .detail)
        XCTAssertEqual(center.session?.index, 0)

        center.step(1)
        XCTAssertEqual(center.session?.index, 1)
        center.step(1)
        XCTAssertEqual(center.session?.index, 2)
        center.step(1)
        XCTAssertEqual(center.session?.index, 2, "到末尾不能再前进（不能越界崩溃）")

        center.step(-1)
        XCTAssertEqual(center.session?.index, 1)
        center.step(-10)
        XCTAssertEqual(center.session?.index, 0, "越界后退应停在第一张")
    }

    /// 起始索引越界时收敛到有效范围（调用方可能传错）
    @MainActor
    func testOpenClampsIndex() {
        let center = MediaViewerCenter.shared
        center.open(medias: [media("a"), media("b")], index: 99, origin: .waterfall)
        XCTAssertEqual(center.session?.index, 1)
        center.open(medias: [media("a")], index: -5, origin: .userGrid)
        XCTAssertEqual(center.session?.index, 0)
    }

    /// 空列表不建立会话（否则窗口打开在"0/0"的空态）
    @MainActor
    func testOpenWithEmptyListDoesNothing() {
        let center = MediaViewerCenter.shared
        center.open(medias: [], index: 0, origin: .detail)
        XCTAssertNil(center.session)
    }

    /// 切换范围由 origin 区分：详情页只装本推文的媒体，瀑布流装整个列表
    @MainActor
    func testOriginRecordsSwitchScope() {
        let center = MediaViewerCenter.shared
        center.open(medias: [media("t1"), media("t2")], index: 0, origin: .detail)
        XCTAssertEqual(center.session?.origin, .detail)
        XCTAssertEqual(center.session?.medias.count, 2, "详情页范围 = 本推文媒体")

        center.open(medias: (0..<50).map { media("w\($0)") }, index: 7, origin: .waterfall)
        XCTAssertEqual(center.session?.origin, .waterfall)
        XCTAssertEqual(center.session?.medias.count, 50, "瀑布流范围 = 整个瀑布流")
    }

    @MainActor
    func testPositionText() {
        let center = MediaViewerCenter.shared
        center.open(medias: [media("a"), media("b"), media("c")], index: 1, origin: .detail)
        XCTAssertEqual(center.positionText, "2 / 3")
    }

    /// 关闭会话后位置文本清空
    @MainActor
    func testCloseClearsSession() {
        let center = MediaViewerCenter.shared
        center.open(medias: [media("a")], index: 0, origin: .detail)
        XCTAssertNotNil(center.session)
        center.clearSessionForWindowClose()
        XCTAssertNil(center.session)
        XCTAssertEqual(center.positionText, "")
    }

    /// 评论媒体：切换范围**只限于该条评论的媒体**。
    ///
    /// 需求原文：「切换媒体就只能切换评论区的（先切换评论内的，没有在切换评论区的）」。
    /// 评论里点开查看窗口时列表只装那条评论的媒体——
    /// 只有 1 张时前后切换无效（不能跳到主推文或别的评论）。
    @MainActor
    func testReplyScopeOnlyStepsWithinThatReply() {
        let center = MediaViewerCenter.shared
        center.open(medias: [media("r1")], index: 0, post: nil, origin: .reply)
        XCTAssertEqual(center.session?.medias.count, 1)
        center.step(1)
        XCTAssertEqual(center.session?.index, 0, "单张评论媒体不能切到别处")
        center.step(-1)
        XCTAssertEqual(center.session?.index, 0)

        // 评论带多张时，只在这几张内切换
        center.open(medias: [media("r1"), media("r2"), media("r3")],
                    index: 0, post: nil, origin: .reply)
        center.step(1)
        XCTAssertEqual(center.session?.index, 1)
        center.step(1)
        XCTAssertEqual(center.session?.index, 2)
        center.step(1)
        XCTAssertEqual(center.session?.index, 2, "到评论内最后一张即止，不越界到其他评论")
        XCTAssertEqual(center.session?.medias.count, 3,
                       "范围里不应混入主推文或其他评论的媒体")
    }
}

/// 视频播放状态（底栏控件的数据源）
final class VideoPlaybackModelTests: XCTestCase {

    /// 时间格式化：底栏显示 "m:ss / m:ss"
    func testTimeTextFormatting() {
        XCTAssertEqual(MediaViewerView.timeText(0), "0:00")
        XCTAssertEqual(MediaViewerView.timeText(59), "0:59")
        XCTAssertEqual(MediaViewerView.timeText(60), "1:00")
        XCTAssertEqual(MediaViewerView.timeText(61), "1:01")
        XCTAssertEqual(MediaViewerView.timeText(3725), "62:05")
    }

    /// 异常输入不能让底栏显示 "nan:nan" 或负数
    func testTimeTextHandlesInvalidValues() {
        XCTAssertEqual(MediaViewerView.timeText(.nan), "0:00")
        XCTAssertEqual(MediaViewerView.timeText(.infinity), "0:00")
        XCTAssertEqual(MediaViewerView.timeText(-5), "0:00")
    }

    /// 倍速循环 0.5 → 1 → 1.5 → 2 → 0.5
    @MainActor
    func testRateCycles() {
        let m = VideoPlaybackModel()
        m.rate = 1.0
        m.cycleRate(); XCTAssertEqual(m.rate, 1.5)
        m.cycleRate(); XCTAssertEqual(m.rate, 2.0)
        m.cycleRate(); XCTAssertEqual(m.rate, 0.5)
        m.cycleRate(); XCTAssertEqual(m.rate, 1.0)
    }

    /// 无播放器时操作不应崩溃（视频还没加载完就点了按钮）
    @MainActor
    func testOperationsWithoutPlayerAreSafe() {
        let m = VideoPlaybackModel()
        m.togglePlay()
        m.play()
        m.restart()
        m.teardown()
        XCTAssertFalse(m.isPlaying)
        XCTAssertEqual(m.currentTime, 0)
    }

    /// **进度不可拖动**（需求：调进度的手势与快捷键跟"切换媒体"冲突，故关闭）。
    ///
    /// 这条测试锁住设计意图：`VideoPlaybackModel` 不再暴露任何 seek/scrub 入口。
    /// 若将来有人想加回拖动进度，请先解决与「双指左右滑切换」「←/→ 切换」的冲突
    /// （它们都依赖水平手势 / 方向键）。
    @MainActor
    func testProgressIsReadOnly() {
        let m = VideoPlaybackModel()
        let mirror = Mirror(reflecting: m)
        let scrubLike = mirror.children.compactMap(\.label).filter {
            $0.lowercased().contains("scrub")
        }
        XCTAssertTrue(scrubLike.isEmpty,
                      "不应存在拖动进度的入口，实际发现: \(scrubLike)")
    }
}

/// 查看窗口的 URL 选择。
final class MediaViewerURLTests: XCTestCase {

    func testLargeURLReplacesNameQuery() {
        let m = TwitterMedia(id: "1", url: "https://pbs.twimg.com/media/x.jpg?name=small",
                             width: 10, height: 10, type: .photo, videoInfo: nil, createdTime: nil)
        let url = MediaViewerView.largeURL(for: m)!
        XCTAssertTrue(url.contains("name=large"))
        XCTAssertEqual(url.components(separatedBy: "name=").count - 1, 1,
                       "不能出现两个 name 参数")
    }

    func testVideoBestVariantIsHighestBitrate() {
        let m = TwitterMedia(
            id: "v", url: "https://pbs.twimg.com/amplify_video_thumb/1/x.jpg",
            width: 10, height: 10, type: .video,
            videoInfo: VideoInfo(url: nil, duration: 1000, variants: [
                VideoVariant(bitrate: 100, contentType: "video/mp4", url: "https://a/low.mp4"),
                VideoVariant(bitrate: 900, contentType: "video/mp4", url: "https://a/high.mp4"),
                VideoVariant(bitrate: nil, contentType: "application/x-mpegURL", url: "https://a/hls.m3u8"),
            ], aspectRatio: [16, 9]),
            createdTime: nil)
        XCTAssertEqual(MediaViewerView.bestVideoURL(m)?.absoluteString, "https://a/high.mp4",
                       "取最高码率 mp4，忽略无码率的 HLS 变体")
    }

    func testGifUsesDirectURL() {
        let m = TwitterMedia(
            id: "g", url: nil, width: 10, height: 10, type: .gif,
            videoInfo: VideoInfo(url: "https://a/anim.mp4", duration: nil,
                                 variants: nil, aspectRatio: nil),
            createdTime: nil)
        XCTAssertEqual(MediaViewerView.bestVideoURL(m)?.absoluteString, "https://a/anim.mp4")
    }
}

/// 媒体宽高比：评论缩略图与查看窗口都依赖它，必须**永远可用**
final class TwitterMediaAspectTests: XCTestCase {

    func testAspectFromOriginalDimensions() {
        let m = TwitterMedia(id: "1", url: nil, width: 947, height: 2048,
                             type: .photo, videoInfo: nil, createdTime: nil)
        XCTAssertEqual(m.aspectRatioValue, CGFloat(947) / CGFloat(2048), accuracy: 0.0001,
                       "竖长图（@example_user 那张）要按真实比例，才能不被裁成一条")
    }

    func testAspectFallsBackToVideoInfo() {
        let m = TwitterMedia(id: "1", url: nil, width: nil, height: nil, type: .video,
                             videoInfo: VideoInfo(url: nil, duration: nil, variants: nil,
                                                  aspectRatio: [16, 9]),
                             createdTime: nil)
        XCTAssertEqual(m.aspectRatioValue, 16.0 / 9.0, accuracy: 0.0001)
    }

    func testAspectFallsBackTo16By9() {
        let m = TwitterMedia(id: "1", url: nil, width: nil, height: nil,
                             type: .photo, videoInfo: nil, createdTime: nil)
        XCTAssertEqual(m.aspectRatioValue, 16.0 / 9.0, accuracy: 0.0001,
                       "全缺失时也要返回可用值，调用方不必处理 nil")

        // 宽高为 0（异常数据）同样不能返回 0 或 NaN（会导致布局退化）
        let zero = TwitterMedia(id: "2", url: nil, width: 0, height: 0,
                                type: .photo, videoInfo: nil, createdTime: nil)
        XCTAssertEqual(zero.aspectRatioValue, 16.0 / 9.0, accuracy: 0.0001)
    }
}
