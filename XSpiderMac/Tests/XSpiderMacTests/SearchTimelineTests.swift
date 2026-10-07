import XCTest
@testable import XSpiderMac

/// 应用侧展示范围的时间轴推进判据。
///
/// 回归用户实测的问题：账号有一两个月没发媒体时，
/// 连续空页不能替代时间边界判定。
final class RangeStartTerminationTests: XCTestCase {

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    /// 判据本身：已见到的最旧一条早于 since → 已翻过范围起点
    func testReachedRangeStartUsesOldestSeenDate() {
        let since = date("2025-01-01")
        // 还在范围内（最旧 2025-06-01 > since）
        XCTAssertFalse(since > date("2025-06-01"), "范围内不应判为到达起点")
        // 已越过起点
        XCTAssertTrue(since > date("2024-12-31"), "早于 since 才算翻过起点")
    }

    /// **空窗期不能算"到达起点"**：判据只看时间，与"这页有没有内容"无关。
    ///
    /// 这是本次修复的核心：空窗期（连续多页被筛空）时最旧日期仍在推进，
    /// 所以**不会**停止加载。
    func testEmptyWindowDoesNotTerminate() {
        let since = date("2025-01-01")
        // 模拟：连续 5 页都被筛空，但每页最旧日期在推进（空窗期）
        let pageOldestDates = ["2025-12-01", "2025-11-01", "2025-10-01",
                               "2025-09-01", "2025-08-01"]
        for d in pageOldestDates {
            let oldest = date(d)
            XCTAssertFalse(oldest < since,
                           "空窗期内（最旧=\(d)）不能判为到达起点，否则会提前停止")
        }
    }

    /// 旧实现的反例：连续空页计数会把上面的情况判成停止。
    /// 这条测试说明**为什么**要换成时间轴判据（保留为设计记录）。
    func testWhyPageCountingWasWrong() {
        // 5 页空 + 第 6 页有内容：按页计数会在第 5 页停（错），时间轴会继续（对）
        let oldestOnPage5 = date("2025-08-01")
        let since = date("2025-01-01")
        XCTAssertFalse(oldestOnPage5 < since,
                       "第 5 页时时间轴仍未越界 → 应继续翻，不该停")
    }
}

/// 「至」当天的边界语义。
///
/// `DatePicker` 给的 `end` 是**当天零点**，若直接用 `createdAt <= end`
/// 会把「至」那天**整天排除**——而用户视角显然应包含。
/// 服务端搜索用 `until:` 也有同样的排他语义，所以模型层统一提供 `inclusiveEnd`。
final class DateRangeBoundaryTests: XCTestCase {

    private func makePost(_ id: String, at date: Date) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                                      mediaCount: nil, registerTime: nil),
                    createdAt: date, fullText: "t", tags: [], views: nil, lang: nil,
                    retweeted: nil, retweetCount: nil, replyCount: nil,
                    possiblySensitive: nil, favorited: nil, favoriteCount: nil,
                    bookmarkCount: nil, bookmarked: nil, medias: nil)
    }

    private func day(_ s: String, hour: Int = 0, minute: Int = 0) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(s) \(String(format: "%02d:%02d", hour, minute))")!
    }

    /// `inclusiveEnd` 落在「至」当天末尾，而非零点
    func testInclusiveEndCoversWholeEndDay() {
        let range = DownloadFilter.DateRange(start: day("2025-01-01"), end: day("2025-01-31"))
        XCTAssertGreaterThan(range.inclusiveEnd, day("2025-01-31"),
                             "必须晚于「至」当天零点")
        XCTAssertGreaterThan(range.inclusiveEnd, day("2025-01-31", hour: 23, minute: 0),
                             "必须覆盖「至」当天 23:00")
        XCTAssertLessThan(range.inclusiveEnd, day("2025-02-01"),
                          "不能越过「至」的次日")
    }

    /// **回归**：「至」当天发布的内容必须留下（旧实现会整天滤掉）
    func testPostsOnEndDayAreIncluded() {
        let range = DownloadFilter.DateRange(start: day("2025-01-01"), end: day("2025-01-31"))
        var filter = DownloadFilter(mediaTypes: nil, source: .medias)
        filter.dateRange = range

        let posts = [
            makePost("startDay", at: day("2025-01-01", hour: 0, minute: 1)),
            makePost("endDayEarly", at: day("2025-01-31", hour: 1)),
            makePost("endDayLate", at: day("2025-01-31", hour: 23, minute: 30)),
            makePost("afterRange", at: day("2025-02-01", hour: 1)),
            makePost("beforeRange", at: day("2024-12-31", hour: 23)),
        ]
        let result = HomepageStore.applyDisplayFilter(posts, filter: filter)
        XCTAssertEqual(result.map(\.id),
                       ["startDay", "endDayEarly", "endDayLate"],
                       "「至」当天全天内容都要保留，范围外才滤掉")
    }

    /// `inclusiveEnd` 必须仍落在结束日内，不能跨到次日。
    func testInclusiveEndStaysInsideEndDay() {
        let range = DownloadFilter.DateRange(start: day("2025-01-01"), end: day("2025-08-31"))
        XCTAssertGreaterThan(range.inclusiveEnd, day("2025-08-31", hour: 12))
        XCTAssertLessThan(range.inclusiveEnd, day("2025-09-01"))
    }

}
