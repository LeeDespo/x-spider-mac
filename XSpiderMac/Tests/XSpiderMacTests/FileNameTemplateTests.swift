import XCTest
@testable import XSpiderMac

final class FileNameTemplateTests: XCTestCase {
    func testBasicTemplate() {
        let user = TwitterUser(screenName: "alice", avatar: "", name: "Alice", id: "1", mediaCount: nil, registerTime: nil)
        let post = TwitterPost(id: "123", user: user, createdAt: nil, fullText: nil, tags: nil, views: nil, lang: nil, retweeted: nil, retweetCount: nil, replyCount: nil, possiblySensitive: nil, favorited: nil, favoriteCount: nil, bookmarkCount: nil, bookmarked: nil, medias: nil)
        let media = TwitterMedia(id: "m1", url: nil, width: nil, height: nil, type: .photo, videoInfo: nil)
        let data = FileNameTemplateData(post: post, media: media)
        let result = FileNameTemplate.resolve(template: "%USER_SCREEN_NAME%_%POST_ID%_%MEDIA_INDEX%%EXT%", data: data)
        XCTAssertEqual(result, "alice_123_1.jpg")
    }
}
