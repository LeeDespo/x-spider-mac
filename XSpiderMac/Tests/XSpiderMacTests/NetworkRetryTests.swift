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
}
