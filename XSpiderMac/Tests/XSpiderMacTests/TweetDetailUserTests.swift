import XCTest
@testable import XSpiderMac

final class TweetDetailUserTests: XCTestCase {
    /// TweetDetail 新版用户结构：result.core.user_results.result 下无 legacy，
    /// name/screen_name 在 result.core，头像在 result.avatar.image_url
    func testMapTwitterPostWithNewUserStructure() {
        let item: [String: Any] = [
            "rest_id": "2097753253027221817",
            "legacy": [
                "created_at": "Wed Sep 09 18:25:24 +0000 2026",
                "entities": [
                    "media": [[
                        "id_str": "2097752152336969728",
                        "type": "photo",
                        "media_url_https": "https://pbs.twimg.com/media/ABC.jpg",
                        "original_info": ["width": 100, "height": 100],
                    ] as [String: Any]],
                ] as [String: Any],
            ] as [String: Any],
            "core": [
                "user_results": [
                    "result": [
                        "rest_id": "2067675948074582016",
                        "__typename": "User",
                        "core": [
                            "name": "John Ternus",
                            "screen_name": "johnternus",
                            "created_at": "Thu Jun 18 18:28:56 +0000 2026",
                        ] as [String: Any],
                        "avatar": ["image_url": "https://pbs.twimg.com/profile_images/x_normal.jpg"],
                        "tweet_counts": ["media_tweets": 2, "tweets": 3],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]

        let post = TwitterAPI.mapTwitterPost(item)
        XCTAssertNotNil(post)
        XCTAssertEqual(post?.user.screenName, "johnternus")
        XCTAssertEqual(post?.user.name, "John Ternus")
        XCTAssertEqual(post?.user.avatar, "https://pbs.twimg.com/profile_images/x_normal.jpg")
        XCTAssertEqual(post?.user.id, "2067675948074582016")
        XCTAssertEqual(post?.user.mediaCount, 2)
        XCTAssertEqual(post?.medias?.count, 1)
    }

    /// 旧版结构（legacy 存在）不受影响
    func testMapTwitterPostWithLegacyUserStructure() {
        let item: [String: Any] = [
            "rest_id": "1",
            "legacy": [
                "entities": ["media": []],
                "created_at": "Wed Sep 09 18:25:24 +0000 2026",
            ] as [String: Any],
            "core": [
                "user_results": [
                    "result": [
                        "rest_id": "9",
                        "legacy": [
                            "screen_name": "olduser",
                            "name": "Old User",
                            "profile_image_url_https": "https://pbs.twimg.com/old.jpg",
                            "media_count": 7,
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let post = TwitterAPI.mapTwitterPost(item)
        XCTAssertEqual(post?.user.screenName, "olduser")
        XCTAssertEqual(post?.user.name, "Old User")
        XCTAssertEqual(post?.user.avatar, "https://pbs.twimg.com/old.jpg")
        XCTAssertEqual(post?.user.mediaCount, 7)
    }
}
