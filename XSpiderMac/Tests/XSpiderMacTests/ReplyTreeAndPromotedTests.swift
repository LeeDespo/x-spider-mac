import XCTest
@testable import XSpiderMac

/// 评论展示层：缩略图与排序只依赖已经归一化的应用模型。
final class ReplyPresentationTests: XCTestCase {
    /// 评论缩略图 URL：`/media/` 图片加 `name=small`；非 media 路径（视频封面）原样返回
    func testReplyThumbnailURLUsesSmallVariant() {
        let photo = TwitterMedia(
            id: "m1",
            url: "https://pbs.twimg.com/media/HSbGNYhXQAAKuL1.jpg",
            width: 947, height: 2048, type: .photo, videoInfo: nil, createdTime: nil)
        let url = ReplyMediaThumb.thumbnailURL(for: photo)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.contains("name=small"),
                      "缩略图必须走 name=small（680px），不能按原图解码，实际: \(url!)")

        // 已有 name 参数时替换而不是追加，避免出现两个 name
        let already = TwitterMedia(
            id: "m2",
            url: "https://pbs.twimg.com/media/x.jpg?name=orig",
            width: 100, height: 100, type: .photo, videoInfo: nil, createdTime: nil)
        let replaced = ReplyMediaThumb.thumbnailURL(for: already)!
        XCTAssertEqual(replaced.components(separatedBy: "name=").count - 1, 1,
                       "不能出现两个 name 参数：\(replaced)")
        XCTAssertTrue(replaced.contains("name=small"))

        // 视频封面路径不带 /media/：原样返回，不加 query
        let video = TwitterMedia(
            id: "m3",
            url: "https://pbs.twimg.com/amplify_video_thumb/123/img/x.jpg",
            width: 100, height: 100, type: .video, videoInfo: nil, createdTime: nil)
        XCTAssertEqual(ReplyMediaThumb.thumbnailURL(for: video),
                       "https://pbs.twimg.com/amplify_video_thumb/123/img/x.jpg")

        let noURL = TwitterMedia(id: "m4", url: nil, width: nil, height: nil,
                                 type: .photo, videoInfo: nil, createdTime: nil)
        XCTAssertNil(ReplyMediaThumb.thumbnailURL(for: noURL))
    }

    // MARK: - 评论排序

    private func node(_ id: String, likes: Int, minutesAgo: Int, depth: Int = 1) -> ReplyNode {
        let created = Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo * 60))
        let post = TwitterPost(
            id: id,
            user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                              mediaCount: nil, registerTime: nil),
            createdAt: created, fullText: "t", tags: [], views: nil, lang: "en",
            retweeted: nil, retweetCount: nil, replyCount: nil, possiblySensitive: nil,
            favorited: nil, favoriteCount: likes, bookmarkCount: nil, bookmarked: nil,
            medias: nil)
        return ReplyNode(post: post, parentId: nil, depth: depth, isPartialParent: false)
    }

    /// 相关 = 保持组件返回顺序（不做本地重排）
    func testRelevanceKeepsComponentOrder() {
        let nodes = [node("a", likes: 1, minutesAgo: 5),
                     node("b", likes: 99, minutesAgo: 1),
                     node("c", likes: 50, minutesAgo: 30)]
        XCTAssertEqual(ReplySort.relevance.sorted(nodes).map(\.post.id), ["a", "b", "c"],
                       "「相关」必须保持组件返回顺序，应用侧不做二次重排")
    }

    /// 喜欢 = 按点赞数降序
    func testLikesSortDescending() {
        let nodes = [node("a", likes: 1, minutesAgo: 5),
                     node("b", likes: 99, minutesAgo: 1),
                     node("c", likes: 50, minutesAgo: 30)]
        XCTAssertEqual(ReplySort.likes.sorted(nodes).map(\.post.id), ["b", "c", "a"])
    }

    /// 最近 = 按时间降序
    func testRecentSortDescending() {
        let nodes = [node("a", likes: 1, minutesAgo: 5),
                     node("b", likes: 99, minutesAgo: 1),
                     node("c", likes: 50, minutesAgo: 30)]
        XCTAssertEqual(ReplySort.recent.sorted(nodes).map(\.post.id), ["b", "a", "c"])
    }

    /// 同键值保持原有相对顺序（稳定排序）——避免每次刷新评论顺序乱跳
    func testSortIsStableForEqualKeys() {
        let nodes = [node("a", likes: 10, minutesAgo: 5),
                     node("b", likes: 10, minutesAgo: 5),
                     node("c", likes: 10, minutesAgo: 5)]
        XCTAssertEqual(ReplySort.likes.sorted(nodes).map(\.post.id), ["a", "b", "c"])
        XCTAssertEqual(ReplySort.recent.sorted(nodes).map(\.post.id), ["a", "b", "c"])
    }

    /// 排序不改变集合内容（只换顺序）
    func testSortPreservesAllNodes() {
        let nodes = [node("a", likes: 1, minutesAgo: 5), node("b", likes: 2, minutesAgo: 1)]
        for sort in ReplySort.allCases {
            XCTAssertEqual(Set(sort.sorted(nodes).map(\.post.id)), ["a", "b"],
                           "\(sort) 不能丢评论")
        }
    }
}


/// 详情缓存：回看刚看过的推文不该再打一次 TweetDetail。
///
/// 存在意义：浮层按推文 ID 重建视图（`.id(post.id)`，否则 @State 串味），
/// 重建会重跑 `.task`。没有缓存时，「点引用推文 → 返回」会把 A 的详情重新请求一遍。
final class TweetDetailCacheTests: XCTestCase {

    private func makePost(_ id: String) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                                      mediaCount: nil, registerTime: nil),
                    createdAt: nil, fullText: "t", tags: [], views: nil, lang: "en",
                    retweeted: nil, retweetCount: nil, replyCount: nil,
                    possiblySensitive: nil, favorited: nil, favoriteCount: nil,
                    bookmarkCount: nil, bookmarked: nil, medias: nil)
    }

    override func setUp() async throws {
        await MainActor.run { TweetDetailCache.shared.clear() }
    }

    override func tearDown() async throws {
        await MainActor.run { TweetDetailCache.shared.clear() }
    }

    @MainActor
    func testPutThenGetReturnsSameContent() {
        let cache = TweetDetailCache.shared
        let post = makePost("1000")
        let reply = ReplyNode(post: makePost("2000"), parentId: "1000", depth: 1)
        cache.put("1000", focal: post, replies: [reply])

        let hit = cache.get("1000")
        XCTAssertEqual(hit?.focal.id, "1000")
        XCTAssertEqual(hit?.replies.map(\.post.id), ["2000"])
        XCTAssertNil(cache.get("nope"), "未缓存的 ID 返回 nil（调用方回落网络）")
    }

    /// 用户操作后失效：否则回看会看到旧的点赞态
    @MainActor
    func testInvalidateRemovesEntry() {
        let cache = TweetDetailCache.shared
        cache.put("1000", focal: makePost("1000"), replies: [])
        XCTAssertNotNil(cache.get("1000"))
        cache.invalidate("1000")
        XCTAssertNil(cache.get("1000"), "失效后必须回落网络请求")
    }

    /// 容量上限：长期浏览不会无限增长
    @MainActor
    func testCacheIsBounded() {
        let cache = TweetDetailCache.shared
        for i in 0..<40 { cache.put("p\(i)", focal: makePost("p\(i)"), replies: []) }
        XCTAssertNil(cache.get("p0"), "最旧的应被淘汰")
        XCTAssertNotNil(cache.get("p39"), "最近的应保留")
    }

    /// 重复 put 同一 ID 不重复占用名额
    @MainActor
    func testRePutSameIdDoesNotDuplicate() {
        let cache = TweetDetailCache.shared
        for _ in 0..<30 {
            cache.put("1000", focal: makePost("1000"), replies: [])
        }
        XCTAssertNotNil(cache.get("1000"))
        // 若每次 put 都追加 order，30 次后 1000 会被自己挤掉
        XCTAssertNotNil(cache.get("1000"), "同一 ID 反复写入不应该把自己淘汰掉")
    }
}

/// 导航历史栈：返回语义。
final class NavigationHistoryTests: XCTestCase {

    override func setUp() async throws {
        await MainActor.run { NavigationHistory.shared.reset() }
    }

    override func tearDown() async throws {
        await MainActor.run { NavigationHistory.shared.reset() }
    }

    @MainActor
    func testBackPopsInReversePushOrder() {
        let history = NavigationHistory.shared
        history.push(.detail(postId: "a"))
        history.push(.detail(postId: "b"))
        history.push(.home(nil))

        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.stack.last?.key, "home:")
        history.back()
        XCTAssertEqual(history.stack.last?.key, "detail:b", "先回到最近压入的界面")
        history.back()
        XCTAssertEqual(history.stack.last?.key, "detail:a")
        history.back()
        XCTAssertFalse(history.canGoBack)
    }

    /// 连续压入同一目标只保留一条（重复搜索同一用户不该产生两层返回）
    @MainActor
    func testDuplicateConsecutivePushIsIgnored() {
        let history = NavigationHistory.shared
        history.push(.detail(postId: "a"))
        history.push(.detail(postId: "a"))
        XCTAssertEqual(history.stack.count, 1)
    }

    /// 栈空时 back() 返回 false（调用方据此兜底关闭浮层）
    @MainActor
    func testBackOnEmptyStackReturnsFalse() {
        XCTAssertFalse(NavigationHistory.shared.back())
    }

    /// 容量上限：长时间浏览不会无限增长
    @MainActor
    func testStackIsBounded() {
        let history = NavigationHistory.shared
        for i in 0..<100 { history.push(.detail(postId: "p\(i)")) }
        XCTAssertLessThanOrEqual(history.stack.count, 32, "历史栈必须有上限")
        // 保留的是最近的那批
        XCTAssertEqual(history.stack.last?.key, "detail:p99")
    }

    /// 重放动作被调用（ContentView 注入的还原路径）
    @MainActor
    func testBackInvokesReplay() {
        let history = NavigationHistory.shared
        var replayed: [String] = []
        history.replay = { entry in replayed.append(entry.key) }
        history.push(.detail(postId: "a"))
        history.back()
        XCTAssertEqual(replayed, ["detail:a"])
        history.replay = nil
    }

    /// 截断：关闭详情浮层时，本次会话攒的返回记录必须作废。
    ///
    /// 回归场景：关闭详情 A → 从主页打开详情 C → 按返回。
    /// 若 A 的记录残留，返回会跳到无关的 A。
    @MainActor
    func testTruncateDropsSessionEntries() {
        let history = NavigationHistory.shared
        history.push(.home(nil))            // 进入浮层前就有的历史（应保留）
        let entryDepth = history.depth

        // 浮层内跳转攒下记录
        history.push(.detail(postId: "A"))
        history.push(.detail(postId: "B"))
        XCTAssertEqual(history.depth, entryDepth + 2)

        // 用户关闭浮层
        history.truncate(to: entryDepth)
        XCTAssertEqual(history.depth, entryDepth, "会话内的记录必须被丢弃")
        XCTAssertEqual(history.stack.last?.key, "home:", "进入浮层前的历史要保留")

        // 再次打开详情时不会指向上一次的推文
        XCTAssertFalse(history.stack.contains { $0.key == "detail:A" })
    }

    /// 截断到更深/相同深度是空操作
    @MainActor
    func testTruncateToDeeperOrEqualIsNoOp() {
        let history = NavigationHistory.shared
        history.push(.detail(postId: "a"))
        history.truncate(to: 5)
        history.truncate(to: 1)
        XCTAssertEqual(history.depth, 1)
    }
}
