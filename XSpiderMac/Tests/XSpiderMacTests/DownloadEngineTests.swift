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
