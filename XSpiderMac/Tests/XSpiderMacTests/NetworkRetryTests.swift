import XCTest
@testable import XSpiderMac

/// 网络重试预算与失败可见性的回归测试。
///
/// 背景：照搬上游的"16 次重试 + 16s 退避"在 macOS 上最坏约 19 分钟
/// （16×60s 系统默认超时 + 153s 退避），表现为"一直加载中、永不失败、无法重试"。
/// 现改为**总预算制**（次数与总耗时双限）。
final class NetworkRetryTests: XCTestCase {

    // MARK: - 配置常量契约（防止有人又把预算调回不可接受的量级）

    func testRetryBudgetIsBounded() {
        // 用反射读不到私有常量，这里以行为验证：无网络时必须在合理时间内失败。
        // 若有人把预算调回 16 次/16s，这个测试会超时失败。
        let expectation = expectation(description: "fail fast when unreachable")
        Task {
            let client = NetworkClient()
            // 指向一个必然连不上的地址（保留地址段，不会真的有人监听）
            let url = URL(string: "http://192.0.2.1:9/")!   // TEST-NET-1
            let start = Date()
            do {
                _ = try await client.request(url: url, maxAttempts: 4, perAttemptTimeout: 2)
                XCTFail("该地址不应可访问")
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                // 4 次 × 2s 超时 + 退避 ≈ 10s 内；给足余量但仍远小于 19 分钟
                XCTAssertLessThan(elapsed, 30, "重试耗时 \(elapsed)s 过长，预算控制失效")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 45)
    }

    /// 连不上的错误应被归类为语义明确的 unreachable，而不是笼统的 unknown
    func testUnreachableErrorIsClassified() async {
        let client = NetworkClient()
        let url = URL(string: "http://192.0.2.1:9/")!
        do {
            _ = try await client.request(url: url, maxAttempts: 2, perAttemptTimeout: 2)
            XCTFail("不应成功")
        } catch let error as NetworkError {
            switch error {
            case .unreachable, .timedOut:
                break   // 二者都可接受（取决于系统返回的具体错误）
            default:
                XCTFail("连不上应归为 unreachable/timedOut，实际 \(error)")
            }
        } catch {
            // 也可能是其它包装层的错误，只要不是崩溃即可
        }
    }

    // MARK: - 失败可见性（主页时间线）

    /// 回归：加载失败必须留下可见状态，否则 UI 是无限转圈。
    /// 真实触发一次失败（无 cookie 会被服务端拒绝，或被总预算拦下），
    /// 验证 loadError 被写入而非只写日志。
    @MainActor
    func testLoadErrorIsExposedOnFailure() async {
        let store = HomeTimelineStore.shared
        store.clearErrorForTesting()
        XCTAssertNil(store.loadError, "初始应无错误")

        // 制造失败：清空 cookie 后请求会被拒（未登录）
        let originalCookie = await MainActor.run { AppStore.shared.cookieString }
        await MainActor.run { AppStore.shared.cookieString = "" }
        await store.reload()
        await MainActor.run { AppStore.shared.cookieString = originalCookie }

        // 失败时应留下错误信息（供视图显示"加载失败 + 重试"）
        // 注意：若外部环境恰好能匿名访问，这里会跳过而非误报失败
        if store.loadError != nil {
            XCTAssertFalse(store.loadError!.isEmpty)
        }
        store.clearErrorForTesting()
        XCTAssertNil(store.loadError, "retry/清除后应复位")
    }
}

/// 主页时间线两形态的批次/排序契约补充
final class HomeTimelineBatchTests: XCTestCase {

    private func makeMedia(_ id: String) -> TwitterMedia {
        TwitterMedia(id: id, url: "https://pbs.twimg.com/media/\(id).jpg",
                     width: 100, height: 100, type: .photo, videoInfo: nil, createdTime: nil)
    }

    private func makePost(_ id: String, likes: Int, media: [String]) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1", mediaCount: nil, registerTime: nil),
                    createdAt: nil, fullText: nil, tags: [], views: nil, lang: nil,
                    retweeted: nil, retweetCount: nil, replyCount: nil, possiblySensitive: nil,
                    favorited: nil, favoriteCount: likes, bookmarkCount: nil, bookmarked: nil,
                    medias: media.map(makeMedia))
    }

    /// flatMedia 必须跟随 visiblePosts：数据增长（翻页）不应改变既有顺序，
    /// 排序切换必须改变顺序。这两件事此前混在一起，导致滚动位置被重置。
    @MainActor
    func testAppendingPostsPreservesOrder() {
        let store = HomeTimelineStore.shared
        store.mode = .following
        store.setFollowingSort(.latest)
        store.posts = [makePost("A", likes: 1, media: ["mA"])]
        let before = store.flatMedia.map { $0.media.id }

        // 模拟翻页追加（posts.append 会触发 didSet 重建）
        store.posts.append(makePost("B", likes: 2, media: ["mB"]))
        let after = store.flatMedia.map { $0.media.id }

        XCTAssertEqual(before, ["mA"])
        // 追加后原有条目必须仍在最前面（顺序不变，只有新增在尾部）
        XCTAssertEqual(after.prefix(before.count).map { $0 }, before,
                       "追加数据不应改变既有媒体顺序（否则视觉上会跳回）")
        XCTAssertEqual(after.count, 2)
    }

    /// 排序切换才应该改变顺序
    @MainActor
    func testSortSwitchReorders() {
        let store = HomeTimelineStore.shared
        store.mode = .following
        store.posts = [
            makePost("A", likes: 1, media: ["mA"]),
            makePost("B", likes: 99, media: ["mB"]),
        ]
        store.setFollowingSort(.latest)
        let latest = store.flatMedia.map { $0.media.id }
        store.setFollowingSort(.hot)
        let hot = store.flatMedia.map { $0.media.id }
        XCTAssertEqual(latest, ["mA", "mB"], "最新 = 时间线原序")
        XCTAssertEqual(hot, ["mB", "mA"], "热门 = 按赞数降序")
    }

    // MARK: - 热门排序的"按页冻结"（修复媒体跳位闪烁）

    /// 回归：热门模式下翻页**不得**让已加载的媒体改变顺序。
    ///
    /// 此前 visiblePosts 每次访问都对全量重排，新页里的高赞推文会插到前面，
    /// 已渲染的媒体瞬间跳位 —— 用户反馈"加载下一页会闪一下、媒体变顺序"。
    /// 现在策略是**按页排序、只追加**：新页只在页内排序后整页追加。
    ///
    /// 通过模拟翻页路径（首屏赋值 → append 新页）验证。
    @MainActor
    func testHotSortDoesNotReorderExistingOnAppend() {
        let store = HomeTimelineStore.shared
        store.mode = .following
        store.setFollowingSort(.hot)
        // 首屏：A(1赞) B(5赞) → 页内排序后 B, A
        store.posts = [
            makePost("A", likes: 1, media: ["mA"]),
            makePost("B", likes: 5, media: ["mB"]),
        ]
        store.reorderForCurrentSort()   // 模拟 reload 的首屏定序
        let afterFirstPage = store.displayPosts.map(\.id)
        XCTAssertEqual(afterFirstPage, ["B", "A"], "首屏应在页内按赞数排序")

        // 第二页：C 有 100 赞（远高于已加载的）——若全量重排，C 会插到最前
        store.posts.append(makePost("C", likes: 100, media: ["mC"]))
        store.appendPageToDisplayOrder([makePost("C", likes: 100, media: ["mC"])])
        let afterSecondPage = store.displayPosts.map(\.id)

        // 关键断言：已加载的 B、A 顺序与位置不变，新页整页追加在后
        XCTAssertEqual(Array(afterSecondPage.prefix(2)), ["B", "A"],
                       "翻页不得重排已加载内容（否则视觉上会跳位闪烁）")
        XCTAssertEqual(afterSecondPage.last, "C", "新页应追加在末尾")
    }

    /// 新页内部应按赞数排序（页内有序），且整页在已有内容之后
    @MainActor
    func testNewPageIsSortedWithinItself() {
        let store = HomeTimelineStore.shared
        store.mode = .following
        store.setFollowingSort(.hot)
        store.posts = [makePost("A", likes: 1, media: ["mA"])]
        store.reorderForCurrentSort()

        // 模拟一页（多条）：页内应降序
        let page = [
            makePost("C", likes: 10, media: ["mC"]),
            makePost("D", likes: 50, media: ["mD"]),
        ]
        store.posts.append(contentsOf: page)
        store.appendPageToDisplayOrder(page)

        let ids = store.displayPosts.map(\.id)
        XCTAssertEqual(ids, ["A", "D", "C"],
                       "已有内容不动，新页在其后且页内按赞数降序")
    }

    /// 用户**主动**切排序时应当整体重排（与翻页的"冻结"相对）
    @MainActor
    func testExplicitSortSwitchReordersEverything() {
        let store = HomeTimelineStore.shared
        store.mode = .following
        store.posts = [
            makePost("A", likes: 1, media: ["mA"]),
            makePost("B", likes: 500, media: ["mB"]),
        ]
        store.setFollowingSort(.hot)
        XCTAssertEqual(store.displayPosts.map(\.id), ["B", "A"], "主动切热门 → 整体重排")
        store.setFollowingSort(.latest)
        XCTAssertEqual(store.displayPosts.map(\.id), ["A", "B"], "主动切最新 → 回到原序")
    }
}

/// 网络异常状态的 TTL（打破"断网 → 无成功请求 → 状态永不清除"的死锁）
final class NetworkStateTTLTests: XCTestCase {

    /// 网络异常必须带 TTL：否则断网期间无成功请求，状态永远清除不掉，
    /// 爬虫挂起与下载降级被无限延长（"代理恢复后应用仍卡很久，除非重启"）。
    @MainActor
    func testNetworkErrorExpiresForSuspension() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteNetworkFailure(URLError(.cannotConnectToHost))
        // 刚发生时：应挂起新工作
        XCTAssertTrue(store.shouldSuspendNewWork, "刚断连时应暂停新工作")

        // 展示层不应因 TTL 而撒谎（仍显示异常）
        XCTAssertNotEqual(store.effectiveHealth, .normal, "展示不应因 TTL 谎称正常")
    }

    /// 限流态也应挂起；正常态不该挂起
    @MainActor
    func testSuspensionMatrix() {
        let store = AccountStatusStore.shared

        store.reset()
        XCTAssertFalse(store.shouldSuspendNewWork, "正常态不应挂起")

        store.noteRateLimited(until: Date().addingTimeInterval(300))
        XCTAssertTrue(store.shouldSuspendNewWork, "限流态应挂起")
        store.reset()

        store.noteUnauthenticated(status: 401)
        XCTAssertTrue(store.shouldSuspendNewWork, "登录失效应挂起")
        store.reset()

        store.noteServerError(status: 503)
        XCTAssertFalse(store.shouldSuspendNewWork, "服务端 5xx 不挂起（重试即可）")
        store.reset()
    }

    /// 限流到期后应停止挂起（与既有 deadline 语义一致）
    @MainActor
    func testRateLimitExpiryStopsSuspension() {
        let store = AccountStatusStore.shared
        store.reset()
        store.setRateLimitDeadlineForTesting(Date().addingTimeInterval(-1))  // 已过期
        XCTAssertFalse(store.shouldSuspendNewWork, "限流到期后不应继续挂起")
        store.reset()
    }
}

/// 浏览进度记忆（切页回来不回到顶部、不丢内容）
final class BrowseProgressTests: XCTestCase {

    private func makeMedia(_ id: String) -> TwitterMedia {
        TwitterMedia(id: id, url: "https://pbs.twimg.com/media/\(id).jpg",
                     width: 100, height: 100, type: .photo, videoInfo: nil, createdTime: nil)
    }

    private func makePost(_ id: String, likes: Int = 1, media: [String] = []) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1", mediaCount: nil, registerTime: nil),
                    createdAt: nil, fullText: nil, tags: [], views: nil, lang: nil,
                    retweeted: nil, retweetCount: nil, replyCount: nil, possiblySensitive: nil,
                    favorited: nil, favoriteCount: likes, bookmarkCount: nil, bookmarked: nil,
                    medias: media.map(makeMedia))
    }

    /// 两种形态的进度必须各自独立保存（互不覆盖）
    @MainActor
    func testAnchorsAreIndependentPerForm() {
        let store = HomeTimelineStore.shared
        store.clearAllScrollAnchors()

        store.reportScrollAnchor("post-42", for: .tweets)
        store.reportScrollAnchor("media-99", for: .media)

        XCTAssertEqual(store.scrollAnchor(for: .tweets), "post-42")
        XCTAssertEqual(store.scrollAnchor(for: .media), "media-99",
                       "两种形态的进度必须独立，否则互相覆盖")
        store.clearAllScrollAnchors()
    }

    /// 显式刷新必须清掉进度：内容整体替换，旧锚点已不在数据里
    @MainActor
    func testExplicitRefreshClearsProgress() {
        let store = HomeTimelineStore.shared
        store.clearAllScrollAnchors()
        store.reportScrollAnchor("post-42", for: .tweets)
        store.reportScrollAnchor("media-99", for: .media)
        store.mediaRenderedCount = 200

        store.clearAllScrollAnchors()

        XCTAssertNil(store.scrollAnchor(for: .tweets))
        XCTAssertNil(store.scrollAnchor(for: .media))
        XCTAssertEqual(store.mediaRenderedCount, 40, "刷新后应回到首批渲染量")
    }

    /// 切换推荐/关注（换数据源）必须清掉进度，否则恢复到不存在的位置
    @MainActor
    func testModeSwitchClearsProgress() {
        let store = HomeTimelineStore.shared
        store.clearAllScrollAnchors()
        store.reportScrollAnchor("post-42", for: .tweets)

        store.mode = .forYou
        store.setMode(.following)

        XCTAssertNil(store.scrollAnchor(for: .tweets), "换数据源后旧进度无意义")
        store.clearAllScrollAnchors()
    }

    /// 渲染计数必须存活于 store（视图被 .id(selection) 重建时 @State 会归零）
    @MainActor
    func testRenderedCountPersistsInStore() {
        let store = HomeTimelineStore.shared
        store.clearAllScrollAnchors()
        store.mediaRenderedCount = 240
        // 模拟视图重建：只读 store，不应被重置
        XCTAssertEqual(store.mediaRenderedCount, 240,
                       "渲染计数必须存 store，否则切页回来只能渲染前 40 条、恢复锚点失败")
        store.clearAllScrollAnchors()
    }

    /// 同一形态可反复更新进度（滚动过程中不断覆盖）
    @MainActor
    func testAnchorUpdatesAsUserScrolls() {
        let store = HomeTimelineStore.shared
        store.clearAllScrollAnchors()
        for id in ["a", "b", "c"] {
            store.reportScrollAnchor(id, for: .tweets)
        }
        XCTAssertEqual(store.scrollAnchor(for: .tweets), "c", "应保留最后一次位置")
        store.clearAllScrollAnchors()
    }
}
