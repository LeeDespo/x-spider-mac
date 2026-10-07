import XCTest
@testable import XSpiderMac

/// 应用侧时间线填充策略回归测试。
///
/// X 的请求、游标推进、服务端停止条件与原始响应解析由 `x-spider-core` 负责；
/// 本文件只锁住 mac UI “何时继续补拉” 的产品行为。
final class TimelinePagingTests: XCTestCase {

    // MARK: - 应用侧视口填充策略

    /// 内容底部在视口顶以下不足两屏 → 继续补拉。
    func testContinueFillingWhenContentFitsWithinTwoViewports() {
        // 内容底距视口顶 300pt，视口 400pt → 300 <= 800，需继续
        XCTAssertTrue(HomepageStore.shouldContinueFilling(contentBottomY: 300, viewportHeight: 400))
        // 正好两屏边界
        XCTAssertTrue(HomepageStore.shouldContinueFilling(contentBottomY: 800, viewportHeight: 400))
    }

    /// 内容已超出两屏 → 停止，等用户滚动，避免应用层无节制补拉。
    func testStopFillingWhenContentExceedsTwoViewports() {
        XCTAssertFalse(HomepageStore.shouldContinueFilling(contentBottomY: 801, viewportHeight: 400))
        XCTAssertFalse(HomepageStore.shouldContinueFilling(contentBottomY: 5000, viewportHeight: 400))
    }

    /// 视口未知/未布局时不得触发请求（避免拿 0 高度去比值）。
    func testNoFillingBeforeViewportKnown() {
        XCTAssertFalse(HomepageStore.shouldContinueFilling(contentBottomY: 100, viewportHeight: 0))
    }

    /// 哨兵未上报（初值 .greatestFiniteMagnitude）→ 不触发。
    func testNoFillingBeforeSentinelReported() {
        XCTAssertFalse(HomepageStore.shouldContinueFilling(
            contentBottomY: .greatestFiniteMagnitude, viewportHeight: 400))
    }
}
