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

/// 同页 / 跨页按 `post.id` 去重（`HomepageStore.dedupeNewPosts`）。
///
/// 回归：同页重复 id 会让 SwiftUI `ForEach` 只渲染第一个、其余留空白
/// （同一账号连续转推同一条推文时，展平后多条 `post.id` 都等于原推文 id）。
final class PostDedupeTests: XCTestCase {

    private func post(_ id: String) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                                      mediaCount: nil, registerTime: nil),
                    createdAt: nil, fullText: "t", tags: [], views: nil, lang: nil,
                    retweeted: nil, retweetCount: nil, replyCount: nil,
                    possiblySensitive: nil, favorited: nil, favoriteCount: nil,
                    bookmarkCount: nil, bookmarked: nil, medias: nil)
    }

    /// 同页重复 id 只留一条
    func testSamePageDuplicatesRemoved() {
        var seen = Set<String>()
        let deduped = HomepageStore.dedupeNewPosts(
            [post("1"), post("1"), post("1"), post("2")], into: &seen)
        XCTAssertEqual(deduped.map(\.id), ["1", "2"])
    }

    /// 跨页去重：同一个 `seen` 账本在两页之间累积
    func testCrossPageDuplicatesRemoved() {
        var seen = Set<String>()
        let page1 = HomepageStore.dedupeNewPosts([post("a"), post("b")], into: &seen)
        let page2 = HomepageStore.dedupeNewPosts([post("b"), post("c")], into: &seen)
        XCTAssertEqual(page1.map(\.id), ["a", "b"])
        XCTAssertEqual(page2.map(\.id), ["c"], "跨页重复也要去掉")
    }

    /// 账本记下首次出现的 id（去重后的 id 全部在 `seen` 里）
    func testSeenCollectsFirstOccurrences() {
        var seen = Set<String>()
        _ = HomepageStore.dedupeNewPosts([post("x"), post("y"), post("x")], into: &seen)
        XCTAssertEqual(seen, ["x", "y"])
    }
}
