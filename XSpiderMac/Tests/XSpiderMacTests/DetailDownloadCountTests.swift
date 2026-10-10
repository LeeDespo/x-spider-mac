import XCTest
@testable import XSpiderMac

/// 详情页下载按钮的计数语义（`MediaDetailView.downloadCapsuleState`）。
///
/// 不能只显示「下载全部(n)」：要按已下载数显示 n-m；全下完显示「全部已下载」。
final class DetailDownloadCountTests: XCTestCase {

    private func state(total: Int, downloaded: Int) -> (allDone: Bool, pending: Int) {
        MediaDetailView.downloadCapsuleState(total: total, downloaded: downloaded)
    }

    func testPendingIsTotalMinusDownloaded() {
        XCTAssertEqual(state(total: 4, downloaded: 0).pending, 4, "一个都没下 → 下载全部(4)")
        XCTAssertEqual(state(total: 4, downloaded: 1).pending, 3, "下过 1 个 → 下载全部(3)")
        XCTAssertEqual(state(total: 4, downloaded: 3).pending, 1)
    }

    /// 全部下完 → 走「全部已下载」分支（胶囊禁用）
    func testAllDownloadedWhenEveryMediaDone() {
        let done = state(total: 2, downloaded: 2)
        XCTAssertTrue(done.allDone)
        XCTAssertEqual(done.pending, 0)
        XCTAssertFalse(state(total: 2, downloaded: 1).allDone, "还差一个就不是全部已下载")
    }

    /// 空媒体列表不算「全部已下载」（胶囊本就不渲染），且 `pending` 不出负数
    func testEmptyMediaIsNotAllDownloaded() {
        let empty = state(total: 0, downloaded: 0)
        XCTAssertFalse(empty.allDone)
        XCTAssertEqual(empty.pending, 0)
    }

    /// 异常数据下 `pending` 不得为负（正常 `downloaded` 由 medias 过滤得出，不会超过 total）
    func testPendingNeverNegative() {
        XCTAssertEqual(state(total: 2, downloaded: 5).pending, 0,
                       "不能出现「下载全部(-3)」")
    }
}
