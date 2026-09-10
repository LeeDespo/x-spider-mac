import XCTest
@testable import XSpiderMac

final class DownloadEngineTests: XCTestCase {
    func testPhotoDownloadURL() {
        let media = TwitterMedia(id: "m1", url: "https://pbs.twimg.com/media/foo.jpg", width: nil, height: nil, type: .photo, videoInfo: nil)
        XCTAssertEqual(downloadURL(for: media), "https://pbs.twimg.com/media/foo.jpg?name=orig")
    }

    func testVideoDownloadURLUsesHighestBitrate() {
        let media = TwitterMedia(id: "v1", url: nil, width: nil, height: nil, type: .video, videoInfo: VideoInfo(duration: 1000, variants: [
            VideoVariant(bitrate: 100, contentType: "video/mp4", url: "http://low.mp4"),
            VideoVariant(bitrate: 500, contentType: "video/mp4", url: "http://high.mp4"),
        ], aspectRatio: nil))
        XCTAssertEqual(downloadURL(for: media), "http://high.mp4")
    }
}
