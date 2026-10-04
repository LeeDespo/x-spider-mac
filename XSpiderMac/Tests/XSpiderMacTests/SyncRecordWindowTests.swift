import XCTest
@testable import XSpiderMac

/// 同步窗口语义（`MEDIA_RECORDS.md` §6.3）——第 2 阶段实现。
///
/// 覆盖契约钉住的五条：
/// 1. 停止条件：见到「本地日期 < anchor_day 减 1 天」的内容即可停；
/// 2. 窗口 `[anchor-1, anchor+1]` 内：id 在记录里 → 跳过，不在 → 走下载判定；
/// 3. 窗口外（晚于 anchor+1）→ 常规处理；
/// 4. 写回：anchor_day = 本轮见到的最新媒体日期；
///    ids = 窗口内已确认存在的全部媒体 id（含本轮跳过的）；
/// 5. 时区 / DST 跨天由 ±1 天窗口兜住。
///
/// 这些用例只打**纯函数**（`SyncWindow` / `SyncWindowRound`）——
/// 它们不读设置、不碰网络、不碰磁盘，所以结论就是窗口语义本身的结论。
final class SyncRecordWindowTests: XCTestCase {

    // MARK: - 日期加减（窗口边界的计算底座）

    func testShiftedDayHandlesMonthAndYearBoundaries() {
        XCTAssertEqual(SyncWindow.shiftedDay("2026-09-29", byDays: -1), "2026-09-28")
        XCTAssertEqual(SyncWindow.shiftedDay("2026-09-29", byDays: 1), "2026-09-30")
        XCTAssertEqual(SyncWindow.shiftedDay("2026-10-01", byDays: -1), "2026-09-30")
        // 跨月 / 跨年
        XCTAssertEqual(SyncWindow.shiftedDay("2026-03-01", byDays: -1), "2026-02-28")
        XCTAssertEqual(SyncWindow.shiftedDay("2026-01-01", byDays: -1), "2025-12-31")
        XCTAssertEqual(SyncWindow.shiftedDay("2025-12-31", byDays: 1), "2026-01-01")
        // 闰年
        XCTAssertEqual(SyncWindow.shiftedDay("2028-03-01", byDays: -1), "2028-02-29")
        // 空串（无锚点）原样返回，不做无意义的换算
        XCTAssertEqual(SyncWindow.shiftedDay("", byDays: -1), "")
    }

    /// 窗口边界是 [anchor-1, anchor+1]（契约原文），闭区间。
    func testWindowBoundsAreAnchorPlusMinusOne() {
        let window = SyncWindow(anchorDay: "2026-09-29", recordedIds: [])
        XCTAssertEqual(window.lowerBound, "2026-09-28")
        XCTAssertEqual(window.upperBound, "2026-09-30")
        XCTAssertEqual(SyncWindow.windowBounds(anchorDay: "2026-09-29").lower, "2026-09-28")
        XCTAssertEqual(SyncWindow.windowBounds(anchorDay: "2026-09-29").upper, "2026-09-30")
        XCTAssertEqual(SyncWindow.windowBounds(anchorDay: "").lower, "")
    }

    // MARK: - 停止条件

    func testStopWhenDayIsOlderThanAnchorMinusOne() {
        let window = SyncWindow(anchorDay: "2026-09-29", recordedIds: [])
        // 本地日期 < 2026-09-28 → 停
        XCTAssertEqual(window.position(postDay: "2026-09-27"), .stopsCrawl)
        XCTAssertEqual(window.decision(postDay: "2026-09-27", mediaId: "1"), .stop)
        XCTAssertEqual(window.position(postDay: "2026-01-01"), .stopsCrawl)
    }

    func testWindowLowerBoundItselfDoesNotStop() {
        let window = SyncWindow(anchorDay: "2026-09-29", recordedIds: [])
        // 恰好在 anchor-1 上 = 窗口内，不满足"更早"（严格小于）→ 不停
        XCTAssertEqual(window.position(postDay: "2026-09-28"), .inWindow)
        XCTAssertNotEqual(window.decision(postDay: "2026-09-28", mediaId: "x"), .stop)
    }

    func testNoAnchorNeverStops() {
        // 首次同步（没有记录）：整轮常规处理，任何老内容都不停
        let window = SyncWindow.empty
        XCTAssertEqual(window.anchorDay, "")
        XCTAssertEqual(window.position(postDay: "2020-01-01"), .undecided)
        XCTAssertEqual(window.decision(postDay: "2020-01-01", mediaId: "1"), .regular)
    }

    func testMissingDateIsTreatedAsRegularHex() {
        // 缺 created_at（历史数据）：无法判位置 → 常规处理，不误停
        let window = SyncWindow(anchorDay: "2026-09-29", recordedIds: [])
        XCTAssertEqual(window.position(postDay: ""), .undecided)
        XCTAssertEqual(window.decision(postDay: "", mediaId: "1"), .regular)
    }

    // MARK: - 窗口内：命中跳过 / 不命中走下载判定

    func testInWindowRecordedIdSkips() {
        let window = SyncWindow(anchorDay: "2026-09-29", recordedIds: ["2104966797669830656"])
        XCTAssertEqual(window.decision(postDay: "2026-09-29", mediaId: "2104966797669830656"),
                       .skipRecorded)
        // 窗口两侧各一天同样算窗口内（时区跨天兜底）
        XCTAssertEqual(window.decision(postDay: "2026-09-28", mediaId: "2104966797669830656"),
                       .skipRecorded)
        XCTAssertEqual(window.decision(postDay: "2026-09-30", mediaId: "2104966797669830656"),
                       .skipRecorded)
    }

    func testInWindowUnrecordedIdGoesToDownloadJudgement() {
        let window = SyncWindow(anchorDay: "2026-09-29", recordedIds: ["111"])
        // 窗口内、记录里没有 → 走下载判定（该下就下）
        XCTAssertEqual(window.decision(postDay: "2026-09-29", mediaId: "222"), .windowUnrecorded)
        // 没有 id 的媒体也要走下载判定（不能因为没法比对记录就跳过）
        XCTAssertEqual(window.decision(postDay: "2026-09-29", mediaId: nil), .windowUnrecorded)
        XCTAssertEqual(window.decision(postDay: "2026-09-29", mediaId: ""), .windowUnrecorded)
    }

    // MARK: - 窗口外：常规处理

    func testNewerThanWindowIsRegular() {
        let window = SyncWindow(anchorDay: "2026-09-29", recordedIds: ["111"])
        // 晚于 anchor+1（09-30）→ 常规处理，且即使 id 命中记录也**不**跳过
        // （记录只声明"窗口内"的确认结果）
        XCTAssertEqual(window.position(postDay: "2026-10-01"), .newerThanWindow)
        XCTAssertEqual(window.decision(postDay: "2026-10-01", mediaId: "111"), .regular)
        XCTAssertEqual(window.decision(postDay: "2026-12-31", mediaId: "111"), .regular)
    }

    func testUpperBoundItselfIsInWindow() {
        let window = SyncWindow(anchorDay: "2026-09-29", recordedIds: ["111"])
        XCTAssertEqual(window.position(postDay: "2026-09-30"), .inWindow)
        XCTAssertEqual(window.decision(postDay: "2026-09-30", mediaId: "111"), .skipRecorded)
    }

    // MARK: - 时区边界（±1 天窗口）

    /// 同一条内容因时区 / DST 变化在本地日历上跨天：锚点 09-29 的内容
    /// 下次可能被算成 09-30，或反过来被算成 09-28——两侧都在窗口内，
    /// 不会被误判成"更新"（重复走常规处理）或"更老"（提前停止）。
    func testTimezoneShiftedDaysStayInWindow() {
        let window = SyncWindow(anchorDay: "2026-09-29", recordedIds: ["777"])
        for day in ["2026-09-28", "2026-09-29", "2026-09-30"] {
            XCTAssertEqual(window.decision(postDay: day, mediaId: "777"), .skipRecorded,
                           "本地日历 ±1 天内的同一媒体应命中记录：\(day)")
        }
        // 再远一天就越界了：+2 走常规、-2 停
        XCTAssertEqual(window.decision(postDay: "2026-10-01", mediaId: "777"), .regular)
        XCTAssertEqual(window.decision(postDay: "2026-09-27", mediaId: "777"), .stop)
    }

    /// DST 切换日（美国 2026-11-01 回拨）：窗口边界仍按日历天算，不受时区影响。
    func testDSTBoundaryDays() {
        let window = SyncWindow(anchorDay: "2026-11-01", recordedIds: ["42"])
        XCTAssertEqual(window.lowerBound, "2026-10-31")
        XCTAssertEqual(window.upperBound, "2026-11-02")
        XCTAssertEqual(window.decision(postDay: "2026-10-31", mediaId: "42"), .skipRecorded)
        XCTAssertEqual(window.decision(postDay: "2026-11-02", mediaId: "42"), .skipRecorded)
        XCTAssertEqual(window.decision(postDay: "2026-11-03", mediaId: "42"), .regular)
        XCTAssertEqual(window.decision(postDay: "2026-10-30", mediaId: "42"), .stop)
    }

    // MARK: - 写回：anchor 与 ids

    func testWrittenBackUsesLatestDayAndWindowConfirmations() {
        var round = SyncWindowRound()
        round.observe(postDay: "2026-09-30")
        round.observe(postDay: "2026-09-29")
        round.observe(postDay: "2026-09-30")   // 乱序 / 重复都要收敛到最大值
        // 窗口内确认（含命中跳过的）：新锚点 09-30 → 窗口 [09-29, 10-01]
        round.confirm(mediaDay: "2026-09-29", mediaId: "100")
        round.confirm(mediaDay: "2026-09-30", mediaId: "200")
        round.confirm(mediaDay: "2026-10-01", mediaId: "300")
        // 窗口外确认：不该写进 ids（契约：ids = 窗口内已确认存在的全部媒体 id）
        round.confirm(mediaDay: "2026-09-28", mediaId: "050")   // 比新窗口下界还早一天
        round.confirm(mediaDay: "2026-09-20", mediaId: "900")
        round.confirm(mediaDay: "2026-10-05", mediaId: "901")   // 比新窗口上界更晚

        let written = round.writtenBack(existingAnchor: "")
        XCTAssertEqual(written.anchorDay, "2026-09-30")
        XCTAssertEqual(written.ids, ["100", "200", "300"],
                       "只写窗口 [anchor-1, anchor+1] 内的确认结果")
    }

    func testWrittenBackFallsBackToExistingAnchorWhenNoDatedMediaSeen() {
        var round = SyncWindowRound()
        let written = round.writtenBack(existingAnchor: "2026-09-29")
        XCTAssertEqual(written.anchorDay, "2026-09-29", "本轮没见到带日期的媒体，不清空锚点")
        XCTAssertEqual(written.ids, [])
    }

    func testWrittenBackOnFirstSyncWithoutAnythingSeenIsEmpty() {
        let round = SyncWindowRound()
        let written = round.writtenBack(existingAnchor: "")
        XCTAssertEqual(written.anchorDay, "")
        XCTAssertEqual(written.ids, [])
    }

    /// 写回的 ids 只包含**确认存在**的：本轮才建任务、还没落盘的不算
    /// （写进去 = "没下成也算已同步"，是静默丢数据）。
    func testWrittenBackOnlyIncludesConfirmedIds() {
        var round = SyncWindowRound()
        round.observe(postDay: "2026-09-30")
        round.confirm(mediaDay: "2026-09-30", mediaId: "downloaded-already")
        // "newly-enqueued" 不被 confirm（循环里只在 already == true 时 confirm）
        let written = round.writtenBack(existingAnchor: "")
        XCTAssertEqual(written.ids, ["downloaded-already"])
        XCTAssertFalse(written.ids.contains("newly-enqueued"))
    }

    func testWrittenBackDedupesAndSortsIds() {
        var round = SyncWindowRound()
        round.observe(postDay: "2026-09-29")
        round.confirm(mediaDay: "2026-09-29", mediaId: "b")
        round.confirm(mediaDay: "2026-09-28", mediaId: "a")
        round.confirm(mediaDay: "2026-09-29", mediaId: "b")   // 同一条重复确认
        round.confirm(mediaDay: "2026-09-29", mediaId: "c")
        let written = round.writtenBack(existingAnchor: "")
        XCTAssertEqual(written.ids, ["a", "b", "c"])
    }

    /// 跨页累积：一轮同步里页与页共用同一本账
    /// （第 1 页的确认不能在第 2 页被丢掉）。
    func testRoundAccumulatesAcrossPages() {
        var round = SyncWindowRound()
        // 第 1 页
        round.observe(postDay: "2026-09-30")
        round.confirm(mediaDay: "2026-09-30", mediaId: "p1")
        // 第 2 页（更老）
        round.observe(postDay: "2026-09-29")
        round.confirm(mediaDay: "2026-09-29", mediaId: "p2")
        let written = round.writtenBack(existingAnchor: "")
        XCTAssertEqual(written.anchorDay, "2026-09-30")
        XCTAssertEqual(written.ids, ["p1", "p2"])
    }

    /// 锚点由**本轮最新媒体日**决定，不是旧锚点；ids 的窗口按**新锚点**取。
    func testWindowForWriteBackUsesTheNewAnchor() {
        var round = SyncWindowRound()
        // 本轮见到的最新是 10-02（旧锚点 09-29）
        round.observe(postDay: "2026-10-02")
        // 09-28 的确认在旧窗口 [09-28, 09-30] 内，但在新窗口 [10-01, 10-03] 外
        round.confirm(mediaDay: "2026-09-28", mediaId: "old-window")
        round.confirm(mediaDay: "2026-10-02", mediaId: "new-window")
        let written = round.writtenBack(existingAnchor: "2026-09-29")
        XCTAssertEqual(written.anchorDay, "2026-10-02")
        XCTAssertEqual(written.ids, ["new-window"])
    }

    func testConfirmedIdWithoutDayIsNotRecorded() {
        var round = SyncWindowRound()
        round.observe(postDay: "2026-09-30")
        round.confirm(mediaDay: "", mediaId: "no-day")
        round.confirm(mediaDay: "2026-09-30", mediaId: "")
        round.confirm(mediaDay: "2026-09-30", mediaId: nil)
        let written = round.writtenBack(existingAnchor: "")
        XCTAssertEqual(written.ids, [], "没有日期的确认不进窗口；空 id 不记")
    }

    // MARK: - 与判定路径的关系

    /// 「按文件名」不该有窗口：它复用下载判定的同一实现。
    /// 这里只钉"窗口结构在无记录时不拦路"，具体复用由 SyncStore 侧保证。
    func testFileNameModeSkipsWindowEntirely() {
        let window = SyncWindow.empty
        XCTAssertEqual(window.decision(postDay: "2001-01-01", mediaId: "x"), .regular)
        XCTAssertEqual(window.recordedIds, [])
    }
}
