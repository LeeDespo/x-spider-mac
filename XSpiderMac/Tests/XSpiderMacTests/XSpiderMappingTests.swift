import XCTest
@testable import XSpiderMac

/// `XSpiderMapping.replyNodes` 的行为与**崩溃回归**。
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
                "screen_name": .string("user_\(id)"),
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
}
