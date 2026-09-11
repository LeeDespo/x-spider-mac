import XCTest
@testable import XSpiderMac

final class DownloadEngineTests: XCTestCase {

    // MARK: - 下载 URL 解析（上游 getDownloadUrl）

    func testPhotoDownloadURL() {
        let media = TwitterMedia(id: "m1", url: "https://pbs.twimg.com/media/foo.jpg", width: nil, height: nil, type: .photo, videoInfo: nil)
        XCTAssertEqual(downloadURL(for: media), "https://pbs.twimg.com/media/foo.jpg?name=orig")
    }

    func testVideoDownloadURLUsesHighestBitrate() {
        let media = TwitterMedia(id: "v1", url: nil, width: nil, height: nil, type: .video, videoInfo: VideoInfo(
            url: nil,
            duration: 1000,
            variants: [
                VideoVariant(bitrate: 100, contentType: "video/mp4", url: "http://low.mp4"),
                VideoVariant(bitrate: 500, contentType: "video/mp4", url: "http://high.mp4"),
                VideoVariant(bitrate: nil, contentType: "application/x-mpegURL", url: "http://hls.m3u8"),
            ],
            aspectRatio: nil
        ))
        XCTAssertEqual(downloadURL(for: media), "http://high.mp4")
    }

    func testGifDownloadURL() {
        let media = TwitterMedia(id: "g1", url: nil, width: nil, height: nil, type: .gif, videoInfo: VideoInfo(
            url: "http://gif.mp4",
            duration: nil,
            variants: nil,
            aspectRatio: nil
        ))
        XCTAssertEqual(downloadURL(for: media), "http://gif.mp4")
    }

    // MARK: - GraphQL 解析（上游 extractPostsFromModuleInstructions / extractPostsFromTweetEntries）

    func testUserMediaModuleParsing() {
        let instructions: [[String: Any]] = [[
            "type": "TimelineAddEntries",
            "entries": [
                [
                    "entryId": "profile-grid-0",
                    "content": [
                        "entryType": "TimelineTimelineModule",
                        "items": [
                            [
                                "item": [
                                    "itemContent": [
                                        "tweet_results": [
                                            "result": [
                                                "__typename": "Tweet",
                                                "rest_id": "123",
                                                "legacy": [
                                                    "full_text": "hello",
                                                    "created_at": "Sat Jan 20 15:15:36 +0000 2024",
                                                    "entities": [
                                                        "media": [
                                                            [
                                                                "id_str": "m1",
                                                                "type": "photo",
                                                                "media_url_https": "https://pbs.twimg.com/media/a.jpg",
                                                                "original_info": ["width": 100, "height": 200],
                                                            ]
                                                        ]
                                                    ]
                                                ],
                                                "core": [
                                                    "user_results": [
                                                        "result": [
                                                            "rest_id": "456",
                                                            "legacy": [
                                                                "screen_name": "alice",
                                                                "name": "Alice",
                                                                "profile_image_url_https": "https://x.com/avatar.jpg",
                                                            ]
                                                        ] as [String: Any]
                                                    ] as [String: Any]
                                                ] as [String: Any]
                                            ] as [String: Any]
                                        ] as [String: Any]
                                    ] as [String: Any]
                                ] as [String: Any]
                            ] as [String: Any]
                        ]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        ]]

        let posts = TwitterAPI.extractPostsFromModuleInstructions(instructions)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].id, "123")
        XCTAssertEqual(posts[0].user.screenName, "alice")
        XCTAssertEqual(posts[0].medias?.count, 1)
        XCTAssertEqual(posts[0].medias?[0].type, .photo)
        XCTAssertEqual(posts[0].createdAt, TwitterDate.parse("Sat Jan 20 15:15:36 +0000 2024"))
    }

    func testTweetWithVisibilityResultsUnwrap() {
        let wrapped: [String: Any] = [
            "__typename": "TweetWithVisibilityResults",
            "tweet": ["rest_id": "789", "legacy": [:]] as [String: Any]
        ]
        let unwrapped = TwitterAPI.unwrapVisibility(wrapped)
        XCTAssertEqual(unwrapped["rest_id"] as? String, "789")
    }

    func testBottomCursorExtraction() {
        let instructions: [[String: Any]] = [[
            "type": "TimelineAddEntries",
            "entries": [
                ["entryId": "tweet-1", "content": ["itemContent": [:]]],
                ["entryId": "cursor-bottom-1", "content": ["cursorType": "Bottom", "value": "DAABCgABGIC"]],
            ]
        ]]
        XCTAssertEqual(TwitterAPI.extractBottomCursor(instructions), "DAABCgABGIC")
    }

    func testUserTweetsEntryParsingAndRetweetFilter() {
        let tweetResult: [String: Any] = [
            "__typename": "Tweet",
            "rest_id": "111",
            "legacy": [
                "entities": ["media": [["type": "photo", "id_str": "m1", "media_url_https": "u"]]]
            ] as [String: Any]
        ]
        let retweetResult: [String: Any] = [
            "__typename": "Tweet",
            "rest_id": "222",
            "legacy": [
                "retweeted_status_result": ["tweet": [:]],
                "entities": ["media": [["type": "photo"]]]
            ] as [String: Any]
        ]
        let instructions: [[String: Any]] = [[
            "type": "TimelineAddEntries",
            "entries": [
                ["entryId": "tweet-111", "content": ["itemContent": ["tweet_results": ["result": tweetResult]]]],
                ["entryId": "tweet-222", "content": ["itemContent": ["tweet_results": ["result": retweetResult]]]],
            ]
        ]]
        let posts = TwitterAPI.extractPostsFromTweetEntries(instructions)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].id, "111")
    }

    // MARK: - Cookie 工具（上游 parseCookie / stringifyCookie）

    func testCookieParseAndStringify() {
        let cookieString = "auth_token=abc123; ct0=xyz789; k3=v3"
        let parsed = Cookie.parse(cookieString)
        XCTAssertEqual(parsed["auth_token"], "abc123")
        XCTAssertEqual(parsed["ct0"], "xyz789")
        XCTAssertEqual(parsed["k3"], "v3")

        let stringified = Cookie.stringify(["auth_token": "abc", "ct0": "xyz"])
        XCTAssertTrue(stringified.contains("auth_token=abc"))
        XCTAssertTrue(stringified.contains("ct0=xyz"))
    }

    // MARK: - X 日期解析

    func testTwitterDateParsing() {
        let date = TwitterDate.parse("Sat Jan 20 15:15:36 +0000 2024")
        XCTAssertNotNil(date)
        let formatted = date?.formatted(fileNameFormat: "yyyy-MM-dd HH-mm-ss")
        XCTAssertEqual(formatted, "2024-01-20 15-15-36")
    }
}
