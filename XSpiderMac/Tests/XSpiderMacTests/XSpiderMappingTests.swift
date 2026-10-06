import XCTest
@testable import XSpiderMac

/// `XSpiderMapping` 的契约形状映射：引用推文、回复树、媒体/计数、分页与 user/post 基本字段。
///
/// 背景：迁移到组件后，回复树由 `XSpiderMapping.replyNodes` 从契约的扁平
/// `replies[]`（带 `parent_id` / `is_partial_parent`）重新建出来。
///
/// 第一条用例不是为了"测深度对不对"，而是为了**钉住一次真实崩溃**：
/// 算深度时如果写成 `byId[id]?.depth = depth(of: id)`，左侧持有对 `byId` 的写访问，
/// 而嵌套函数 `depth` 里又要读同一个字典——嵌套函数捕获的本地 var 走同一个访问盒，
/// Swift 运行时的独占性检查会直接 `fatalError`（SIGABRT）。
/// 症状是**打开任何带评论的推文，应用必崩**；而当时整套测试没有一条覆盖这里，
/// 所以它一路亮着绿灯。
final class XSpiderMappingTests: XCTestCase {

    // MARK: - 构造工具

    private func postJSON(
        id: String,
        text: String = "内容",
        authorScreenName: String? = nil,
        parentId: String? = nil,
        parentScreenName: String? = nil,
        isPartialParent: Bool = false
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "created_at": .string("2026-09-25T01:33:31Z"),
            "full_text": .string(text),
            "favorite_count": .int(0),
            "retweet_count": .int(0),
            "reply_count": .int(0),
            "possibly_sensitive": .bool(false),
            "favorited": .bool(false),
            "retweeted": .bool(false),
            "bookmarked": .bool(false),
            "author": .object([
                "id": .string("u-\(id)"),
                "screen_name": .string(authorScreenName ?? "user_\(id)"),
                "name": .string("User \(id)"),
                "avatar": .string("https://pbs.twimg.com/\(id)_bigger.jpg"),
            ]),
        ]
        if let parentId { fields["parent_id"] = .string(parentId) }
        if let parentScreenName { fields["in_reply_to_screen_name"] = .string(parentScreenName) }
        if isPartialParent { fields["is_partial_parent"] = .bool(true) }
        return .object(fields)
    }

    private func detail(focalId: String, replies: [JSONValue]) -> [String: JSONValue] {
        [
            "focal": postJSON(id: focalId, text: "主推"),
            "replies": .array(replies),
        ]
    }

    // MARK: - 引用推文

    /// `post.quoted` → `quotedPost`。
    ///
    /// 这一条以前是坏的：映射里写死 `quotedPost: nil`，于是**引用推文在界面上只剩空壳**
    /// （契约当时只有 `quoted_id`）。契约 1.4.0 给了内嵌对象，这里跟着接上。
    func testQuotedPostIsMappedAndOnlyOneLevelDeep() throws {
        // 内层自带一个 `quoted`，用来验证"只嵌一层"：内层不该再展开
        var inner = try XCTUnwrap(postJSON(id: "quoted").asObject, "内层样本要是个对象")
        inner["quoted_id"] = .string("222")
        inner["quoted"] = postJSON(id: "222")

        var outer = try XCTUnwrap(postJSON(id: "outer").asObject)
        outer["quoted_id"] = .string("quoted")
        outer["quoted"] = .object(inner)

        let post = try XCTUnwrap(XSpiderMapping.post(outer))

        let quoted = try XCTUnwrap(post.quotedPost?.value, "引用推文要映射成 quotedPost")
        XCTAssertEqual(quoted.id, "quoted")
        XCTAssertEqual(quoted.fullText, "内容")
        XCTAssertNil(quoted.quotedPost, "只嵌一层：内层的引用不该再展开")
    }

    /// 取不到被引用的推文时（被删/不可见）：**不能编造**，`quotedPost` 就是 nil。
    func testMissingQuotedBodyLeavesQuotedPostNil() throws {
        var outer = try XCTUnwrap(postJSON(id: "outer").asObject)
        outer["quoted_id"] = .string("777")
        // 没有 `quoted` 键

        let post = try XCTUnwrap(XSpiderMapping.post(outer))
        XCTAssertNil(post.quotedPost)
    }

    // MARK: - 崩溃回归

    /// **打开带评论的推文不能崩。**
    ///
    /// 修掉独占性冲突之前，这条会以 `Simultaneous accesses to ... (depth)` 直接 abort。
    func testReplyChainDoesNotCrashAndProducesDepths() {
        let result = detail(focalId: "focal", replies: [
            postJSON(id: "r1", parentId: "focal", parentScreenName: "bob"),
            postJSON(id: "r2", parentId: "r1"),
            postJSON(id: "r3", parentId: "r2"),
            postJSON(id: "orphan", parentId: "not-in-this-page", isPartialParent: true),
        ])

        let mapped = XSpiderMapping.replyNodes(result, focalId: "focal")

        XCTAssertEqual(mapped.focal?.id, "focal")
        // 顺序保持契约给的顺序（外壳按它渲染）
        XCTAssertEqual(mapped.replies.map(\.id), ["r1", "r2", "r3", "orphan"])
        XCTAssertEqual(mapped.replies.map(\.depth), [1, 2, 3, 1])
        // 孤儿**不能丢**，并且带着"父不在本页"的标记
        XCTAssertEqual(mapped.replies.last?.isPartialParent, true)
        XCTAssertEqual(mapped.replies.first?.parentScreenName, "bob")
    }

    /// 只有一条直接回复也要能过（`depth` 的最短路径）。
    func testSingleReplyIsDepthOne() {
        let mapped = XSpiderMapping.replyNodes(
            detail(focalId: "focal", replies: [postJSON(id: "only", parentId: "focal")]),
            focalId: "focal")
        XCTAssertEqual(mapped.replies.map(\.depth), [1])
    }

    /// 数据成环时要有环保护：**不能死循环**（父链互相指回对方）。
    func testCyclicParentsTerminate() {
        let mapped = XSpiderMapping.replyNodes(
            detail(focalId: "focal", replies: [
                postJSON(id: "a", parentId: "b"),
                postJSON(id: "b", parentId: "a"),
            ]),
            focalId: "focal")

        // 终止即通过：环保护在"再次遇到自己"时按 1 算，所以深度有界、不会爆栈。
        // 注意深度值本身会被抬高（a→b→a 得到 4 而不是 1）——**这是刻意的**：
        // 环是坏数据，这里只保证"不崩、不死循环"，不假装能算出正确层级。
        XCTAssertEqual(mapped.replies.count, 2)
        XCTAssertTrue(mapped.replies.allSatisfy { $0.depth >= 1 })
        XCTAssertTrue(mapped.replies.allSatisfy { $0.depth <= 8 })
    }

    /// 解析不出来的条目（缺作者等）被丢弃，不会让整页失败。
    func testUnparsableReplyIsDroppedNotFatal() {
        let broken = JSONValue.object(["id": .string("x"), "parent_id": .string("focal")])
        let mapped = XSpiderMapping.replyNodes(
            detail(focalId: "focal", replies: [broken, postJSON(id: "ok", parentId: "focal")]),
            focalId: "focal")
        XCTAssertEqual(mapped.replies.map(\.id), ["ok"])
    }

    // MARK: - 契约形状补遗（legacy 解析退役后，原 raw 用例的等价覆盖落在这里）

    /// 「回复 @xxx」必须用**被回复者**，不是本条作者——否则二级评论会显示成
    /// "bob 回复 bob"。一级回复由上面的链式用例覆盖，这条钉**二级评论**。
    func testSecondLevelReplyParentScreenNameIsTheRepliedToAuthor() {
        let mapped = XSpiderMapping.replyNodes(
            detail(focalId: "focal", replies: [
                postJSON(id: "r1", parentId: "focal", parentScreenName: "user_focal"),
                postJSON(id: "r2", authorScreenName: "bob",
                         parentId: "r1", parentScreenName: "alice"),
            ]),
            focalId: "focal")

        XCTAssertEqual(mapped.replies.last?.post.user.screenName, "bob", "本条作者是 bob")
        XCTAssertEqual(mapped.replies.last?.parentScreenName, "alice",
                       "被回复者是 alice——前缀必须用它，不能用本条作者")
        XCTAssertEqual(mapped.replies.last?.depth, 2)
    }

    /// 父不在本页（孤儿）时，「回复 @xxx」用契约自带的 `in_reply_to_screen_name`——
    /// 父节点不在场也能显示对的人。顺带钉住：完全没带父指针的顶层回复
    /// depth 1、不算孤儿、parentScreenName 为空。
    func testParentScreenNameComesFromContractFieldWhenParentMissing() {
        let mapped = XSpiderMapping.replyNodes(
            detail(focalId: "focal", replies: [
                postJSON(id: "orphan", parentId: "not-in-this-page",
                         parentScreenName: "carol", isPartialParent: true),
                postJSON(id: "top"),   // 无 parent_id / 无 in_reply_to_screen_name
            ]),
            focalId: "focal")

        XCTAssertEqual(mapped.replies.first?.isPartialParent, true)
        XCTAssertEqual(mapped.replies.first?.parentScreenName, "carol",
                       "父不在本页时用契约里的 in_reply_to_screen_name")
        XCTAssertEqual(mapped.replies.last?.depth, 1)
        XCTAssertEqual(mapped.replies.last?.isPartialParent, false, "无父指针不等于孤儿")
        XCTAssertNil(mapped.replies.last?.parentScreenName)
    }

    /// 评论自带的媒体与计数要映射出来（回归"评论区不显示媒体"：
    /// 解析层不带 medias，渲染层就没得画）。
    /// 视频顺带钉住 poster 语义：`url` 必须是封面（`poster_url`），
    /// 不能填可下载的 mp4——视频格子拿 `url` 当图片解码会整片空白。
    func testReplyMediasAndCountsAreMapped() throws {
        var reply = try XCTUnwrap(
            postJSON(id: "r1", authorScreenName: "example_user",
                     parentId: "focal", parentScreenName: "example_quoted").asObject)
        reply["favorite_count"] = .int(326)
        reply["reply_count"] = .int(3)
        reply["medias"] = .array([
            .object([
                "id": .string("m1"),
                "kind": .string("photo"),
                "url": .string("https://pbs.twimg.com/media/HSbGNYhXQAAKuL1.jpg"),
                "width": .int(947),
                "height": .int(2048),
            ]),
            .object([
                "id": .string("m2"),
                "kind": .string("video"),
                "url": .string("https://video.twimg.com/xxx.mp4"),
                "poster_url": .string("https://pbs.twimg.com/media/xxx.jpg"),
                "variants": .array([.object([
                    "url": .string("https://video.twimg.com/xxx.mp4"),
                    "content_type": .string("video/mp4"),
                    "bitrate": .int(500),
                ])]),
            ]),
        ])

        let mapped = XSpiderMapping.replyNodes(
            detail(focalId: "focal", replies: [.object(reply)]), focalId: "focal")
        let node = try XCTUnwrap(mapped.replies.first, "评论必须映射出来")

        XCTAssertEqual(node.post.medias?.count, 2)
        XCTAssertEqual(node.post.medias?[0].type, .photo)
        XCTAssertEqual(node.post.medias?[0].width, 947)
        XCTAssertEqual(node.post.medias?[0].height, 2048)
        XCTAssertEqual(node.post.medias?[0].url, "https://pbs.twimg.com/media/HSbGNYhXQAAKuL1.jpg")
        XCTAssertEqual(node.post.medias?[1].type, .video)
        XCTAssertEqual(node.post.medias?[1].url, "https://pbs.twimg.com/media/xxx.jpg",
                       "视频的 url 必须是封面 poster_url，不能是 mp4")
        XCTAssertEqual(node.post.medias?[1].videoInfo?.variants?.first?.url,
                       "https://video.twimg.com/xxx.mp4")
        XCTAssertEqual(node.post.favoriteCount, 326, "评论点赞数要映射出来")
        XCTAssertEqual(node.post.replyCount, 3, "评论的回复数要映射出来")
        XCTAssertEqual(node.parentScreenName, "example_quoted")
    }

    /// 没有媒体时 `medias` 必须是 nil（渲染层据此不画缩略图行），不能造出空数组。
    func testReplyWithoutMediaHasNilMedias() {
        let mapped = XSpiderMapping.replyNodes(
            detail(focalId: "focal", replies: [postJSON(id: "r1", parentId: "focal")]),
            focalId: "focal")
        XCTAssertNil(mapped.replies.first?.post.medias, "无媒体评论不应造出空数组")
    }

    /// 空页必须终结：契约里 **cursor 键不出现就是到头**，`postPage` 对空 items
    /// 返回空数组 + nil cursor，调用方据此停止翻页（原 raw 解析层的语义，
    /// 现随契约形状钉在这里）。
    func testEmptyPageYieldsNoPostsAndNilCursor() {
        let page = XSpiderMapping.postPage(["items": .array([])])
        XCTAssertTrue(page.posts.isEmpty)
        XCTAssertNil(page.cursor, "空页的 cursor 必须为 nil（到底信号）")

        // 连 items 键都没有（组件异常兜底）也要安全
        let bare = XSpiderMapping.postPage([:])
        XCTAssertTrue(bare.posts.isEmpty)
        XCTAssertNil(bare.cursor)
    }

    /// 契约 user/post → 应用模型的基本字段（作者映射的唯一入口是
    /// `XSpiderMapping.user`：`id` / `screen_name` 缺一即整条丢弃）。
    /// 接替已退役的 raw 用户结构用例；`retweeted_by` → `retweetedBy`
    /// 是「某某 转推」标签的数据源。
    func testContractUserAndPostMapToAppModel() throws {
        let post = try XCTUnwrap(XSpiderMapping.post([
            "id": .string("2097753253027221817"),
            "created_at": .string("2026-09-09T18:25:24Z"),
            "full_text": .string("hello"),
            "retweet_count": .int(5),
            "author": .object([
                "id": .string("2067675948074582016"),
                "screen_name": .string("johnternus"),
                "name": .string("John Ternus"),
                "avatar": .string("https://pbs.twimg.com/profile_images/x_bigger.jpg"),
                "media_count": .int(2),
                "register_time": .string("2026-06-18T18:28:56Z"),
            ]),
            "retweeted_by": .object([
                "id": .string("retweeter-id"),
                "screen_name": .string("retweeter"),
                "name": .string("转发者"),
            ]),
        ]))

        XCTAssertEqual(post.user.screenName, "johnternus")
        XCTAssertEqual(post.user.name, "John Ternus")
        XCTAssertEqual(post.user.id, "2067675948074582016")
        XCTAssertEqual(post.user.mediaCount, 2)
        XCTAssertEqual(post.user.registerTime, XSpiderMapping.date(.string("2026-06-18T18:28:56Z")))
        XCTAssertEqual(post.createdAt, XSpiderMapping.date(.string("2026-09-09T18:25:24Z")))
        XCTAssertEqual(post.retweetCount, 5)
        XCTAssertEqual(post.retweetedBy?.screenName, "retweeter",
                       "契约 retweeted_by 映射为转发者（转推标签数据源）")
    }
}
