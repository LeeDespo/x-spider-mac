import XCTest
@testable import XSpiderMac

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

    /// 与搜索端点的「至含当天」语义对齐：契约 `fetch.search_timeline` 的
    /// `until` 按**本地日历**理解且**含当天**（组件内部再按排他语义 +1 天），
    /// 外壳只交本地日期串、不再自己加一天；客户端侧的等价物是
    /// `inclusiveEnd`——同样覆盖「至」全天。
    func testInclusiveEndMatchesSearchUntilSemantics() {
        let range = DownloadFilter.DateRange(start: day("2025-01-01"), end: day("2025-08-31"))
        XCTAssertGreaterThan(range.inclusiveEnd, day("2025-08-31", hour: 12))
        XCTAssertLessThan(range.inclusiveEnd, day("2025-09-01"))
    }
}
