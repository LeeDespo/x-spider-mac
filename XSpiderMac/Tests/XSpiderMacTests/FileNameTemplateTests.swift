import XCTest
@testable import XSpiderMac

final class FileNameTemplateTests: XCTestCase {

    private func makeData(
        createdAt: Date? = TwitterDate.parse("Sat Jan 20 15:15:36 +0000 2024"),
        fullText: String? = "这里是推文内容，这里是推文内容。",
        tags: [String]? = ["标签1", "标签2"],
        mediaType: MediaType = .photo,
        mediaUrl: String? = "https://pbs.twimg.com/media/GESdifpaMAA6rth.jpg"
    ) -> FileNameTemplateData {
        let user = TwitterUser(
            screenName: "userscreenname", avatar: "", name: "这是用户昵称",
            id: "1145141919", mediaCount: 8888,
            registerTime: TwitterDate.parse("2024-01-01 00:00:00")
        )
        let media = TwitterMedia(
            id: "1748695771262889984",
            url: mediaUrl, width: 1323, height: 1136,
            type: mediaType,
            videoInfo: mediaType == .photo ? nil : VideoInfo(
                url: "https://video.twimg.com/ext_tw_video/1.mp4",
                duration: 1234,
                variants: [VideoVariant(bitrate: 500, contentType: "video/mp4", url: "https://video.twimg.com/high.mp4")],
                aspectRatio: [16, 9]
            )
        )
        let post = TwitterPost(
            id: "1145141919810", user: user, createdAt: createdAt,
            fullText: fullText, tags: tags, views: 13496, lang: "ja",
            retweeted: false, retweetCount: 24, replyCount: 21,
            possiblySensitive: false, favorited: false, favoriteCount: 228,
            bookmarkCount: 1, bookmarked: false,
            medias: [media]
        )
        return FileNameTemplateData(post: post, media: media)
    }

    // MARK: - 上游默认模板

    func testDefaultTemplate() {
        let data = makeData()
        let result = FileNameTemplate.resolve(
            template: "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%",
            data: data
        )
        XCTAssertEqual(result, "2024-01-20 15-15-36 userscreenname 1145141919810-1.jpg")
    }

    // MARK: - 全部 13 个变量

    func testAllVariables() {
        let data = makeData()
        XCTAssertEqual(FileNameTemplate.resolve(template: "%POST_ID%", data: data), "1145141919810")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%POST_TIME%", data: data), "2024-01-20 15-15-36")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%USER_ID%", data: data), "1145141919")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%USER_NAME%", data: data), "这是用户昵称")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%USER_SCREEN_NAME%", data: data), "userscreenname")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%MEDIA_ID%", data: data), "1748695771262889984")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%MEDIA_WIDTH%", data: data), "1323")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%MEDIA_HEIGHT%", data: data), "1136")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%MEDIA_INDEX%", data: data), "1")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%MEDIA_TYPE%", data: data), "photo")
        XCTAssertEqual(FileNameTemplate.resolve(template: "%TAGS%", data: data), "标签1,标签2")
    }

    // MARK: - 参数语法（上游 %VAR,k=v%）

    func testParamSyntax() {
        let data = makeData()
        // d=1 仅日期
        XCTAssertEqual(FileNameTemplate.resolve(template: "%POST_TIME,d=1%", data: data), "2024-01-20")
        // d=0 完整时间
        XCTAssertEqual(FileNameTemplate.resolve(template: "%POST_TIME,d=0%", data: data), "2024-01-20 15-15-36")
        // t 截断长度（按 unicode 索引，即字符数）
        let short = FileNameTemplate.resolve(template: "%CONTENT,t=6%", data: data)
        XCTAssertEqual(short, "这里是推文内")
        // t 默认 16（上游 params.t 缺省 16）
        let defaulted = FileNameTemplate.resolve(template: "%CONTENT%", data: data)
        XCTAssertEqual(defaulted, "这里是推文内容，这里是推文内容。")
    }

    // MARK: - 扩展名取自下载 URL（上游 EXT 从 getDownloadUrl 取）

    func testExtFromDownloadUrl() {
        XCTAssertEqual(FileNameTemplate.resolve(template: "%EXT%", data: makeData()), ".jpg")
        // 视频：取最高码率变体 URL 的扩展名
        let videoData = makeData(mediaType: .video)
        XCTAssertEqual(FileNameTemplate.resolve(template: "%EXT%", data: videoData), ".mp4")
    }

    // MARK: - 文件名安全化（上游 unicodeFilenamify）

    func testFilenamify() {
        // 保留字符替换为 !
        let data = makeData(fullText: "hello/world:name*test")
        let result = FileNameTemplate.resolve(template: "%CONTENT,t=99%", data: data)
        XCTAssertEqual(result, "hello!world!name!test")
        // Windows 保留名
        XCTAssertEqual(UnicodeFilename.filenamify("con"), "con!")
        XCTAssertEqual(UnicodeFilename.filenamify("normal"), "normal")
    }

    // MARK: - 缺失字段

    func testMissingFields() {
        let data = makeData(createdAt: nil)
        XCTAssertEqual(FileNameTemplate.resolve(template: "%POST_TIME%", data: data), "未知日期")
        let noText = makeData(fullText: nil)
        XCTAssertEqual(FileNameTemplate.resolve(template: "%CONTENT%", data: noText), "")
    }
}
