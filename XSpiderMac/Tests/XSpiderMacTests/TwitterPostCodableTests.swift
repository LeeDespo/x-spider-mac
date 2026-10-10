import XCTest
@testable import XSpiderMac

/// 应用模型的引用推文持久化语义。
final class QuotedPostModelTests: XCTestCase {
    func testLegacyCodableStillDecodes() throws {
        let legacyJSON = """
        {"id":"1","user":{"screenName":"u","avatar":"","name":"U","id":"1"},
         "createdAt":null,"fullText":"旧记录","tags":null,"views":null,"lang":null,
         "retweeted":null,"retweetCount":null,"replyCount":null,"possiblySensitive":null,
         "favorited":null,"favoriteCount":null,"bookmarkCount":null,"bookmarked":null,
         "medias":null}
        """
        let post = try JSONDecoder().decode(TwitterPost.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(post.id, "1")
        XCTAssertNil(post.quotedPost)
        XCTAssertNil(post.retweetedBy)
    }

    func testQuotedPostRoundTrip() throws {
        let inner = TwitterPost(
            id: "999",
            user: TwitterUser(screenName: "a", avatar: "", name: "A", id: "1", mediaCount: nil, registerTime: nil),
            createdAt: nil, fullText: "内层", tags: nil, views: nil, lang: nil,
            retweeted: nil, retweetCount: nil, replyCount: nil, possiblySensitive: nil,
            favorited: nil, favoriteCount: nil, bookmarkCount: nil, bookmarked: nil, medias: nil)
        let outer = TwitterPost(
            id: "111", user: inner.user, createdAt: nil, fullText: "外层",
            tags: nil, views: nil, lang: nil, retweeted: nil, retweetCount: nil,
            replyCount: nil, possiblySensitive: nil, favorited: nil,
            favoriteCount: nil, bookmarkCount: nil, bookmarked: nil, medias: nil,
            quotedPost: QuotedPostBox(inner))
        let data = try JSONEncoder().encode(outer)
        let back = try JSONDecoder().decode(TwitterPost.self, from: data)
        XCTAssertEqual(back.quotedPost?.value.id, "999")
        XCTAssertEqual(back.quotedPost?.value.fullText, "内层")
    }
}
