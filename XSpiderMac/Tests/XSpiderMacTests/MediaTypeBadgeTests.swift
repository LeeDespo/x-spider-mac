import XCTest
@testable import XSpiderMac

/// 媒体类型标签的显示规则：只有视频 / GIF 才加标签，图片不加。
final class MediaTypeBadgeTests: XCTestCase {

    func testOnlyVideoAndGifGetBadge() {
        XCTAssertFalse(MediaTypeBadge.showsBadge(for: .photo), "图片是默认预期，加标签只是噪声")
        XCTAssertTrue(MediaTypeBadge.showsBadge(for: .video), "静态封面看不出是视频，必须标注")
        XCTAssertTrue(MediaTypeBadge.showsBadge(for: .gif), "GIF 没有时长角标，更需要标注")
    }
}
