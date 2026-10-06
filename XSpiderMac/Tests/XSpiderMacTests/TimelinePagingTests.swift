import XCTest
@testable import XSpiderMac

/// 无限滚动的停止条件（视口填充语义，防 429 风暴）。
///
/// cursor 推进时序与重复游标熔断现在都在组件 `crawl.run` 里（外壳只按
/// `done_reason` 消费），原先的本地模拟用例已随 legacy 清理删除；
/// 空页终结语义的契约形状覆盖在 `XSpiderMappingTests`。
final class TimelinePagingTests: XCTestCase {

    // MARK: - 无限滚动停止条件（上游 InfiniteScroll.tsx:35-50）

    /// 内容底部在视口顶以下不足两屏 → 继续补拉
    func testContinueFillingWhenContentFitsWithinTwoViewports() {
        // 内容底距视口顶 300pt，视口 400pt → 300 <= 800，需继续
        XCTAssertTrue(HomepageStore.shouldContinueFilling(contentBottomY: 300, viewportHeight: 400))
        // 正好两屏边界
        XCTAssertTrue(HomepageStore.shouldContinueFilling(contentBottomY: 800, viewportHeight: 400))
    }

    /// 内容已超出两屏 → 停止，等用户滚动（防 429 风暴的关键）
    func testStopFillingWhenContentExceedsTwoViewports() {
        XCTAssertFalse(HomepageStore.shouldContinueFilling(contentBottomY: 801, viewportHeight: 400))
        XCTAssertFalse(HomepageStore.shouldContinueFilling(contentBottomY: 5000, viewportHeight: 400))
    }

    /// 视口未知/未布局时不得触发请求（避免拿 0 高度去比值）
    func testNoFillingBeforeViewportKnown() {
        XCTAssertFalse(HomepageStore.shouldContinueFilling(contentBottomY: 100, viewportHeight: 0))
    }

    /// 哨兵未上报（初值 .greatestFiniteMagnitude）→ 不触发
    func testNoFillingBeforeSentinelReported() {
        XCTAssertFalse(HomepageStore.shouldContinueFilling(
            contentBottomY: .greatestFiniteMagnitude, viewportHeight: 400))
    }

}
