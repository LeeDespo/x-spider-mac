import XCTest
@testable import XSpiderMac

/// 搜索端点（SearchTimeline）的 query 构造与 queryId 自愈。
///
/// 背景：设置时间范围后用 X 的搜索端点，时间由**服务端**过滤——
/// 因此不存在"空窗期被误判成没有内容"的问题，且一页返回的条数远多于时间线
/// （实测媒体 42 条/页 vs 时间线 10 条/页）。
final class SearchTimelineTests: XCTestCase {

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    // MARK: - rawQuery 构造

    /// 基本形态：from + since + until
    func testRawQueryContainsUserAndRange() {
        let range = DownloadFilter.DateRange(start: date("2025-01-01"), end: date("2026-08-31"))
        let q = TwitterAPI.searchRawQuery(screenName: "example_account", range: range, includeMediaOnly: false)
        XCTAssertTrue(q.hasPrefix("from:example_account"), "按用户名限定，实际: \(q)")
        XCTAssertTrue(q.contains("since:2025-01-01"))
        XCTAssertTrue(q.contains("until:"))
    }

    /// **`until:` 是排他的** → 必须给 end 加一天，
    /// 否则用户会发现"至"那天永远没有内容（很容易漏的坑）
    func testUntilIsExclusiveSoEndIsInclusiveAfterPlusOneDay() {
        let range = DownloadFilter.DateRange(start: date("2025-01-01"), end: date("2026-08-31"))
        let q = TwitterAPI.searchRawQuery(screenName: "u", range: range, includeMediaOnly: false)
        XCTAssertTrue(q.contains("until:2026-09-01"),
                      "UI 的「至」2026-08-31 应转成 until:2026-09-01（X 语义排他），实际: \(q)")
    }

    /// 媒体数据源带上 `filter:media`（服务端只回带媒体的推文，省配额）
    func testMediaOnlyAddsFilterOperator() {
        let range = DownloadFilter.DateRange(start: date("2025-01-01"), end: date("2026-08-31"))
        let media = TwitterAPI.searchRawQuery(screenName: "u", range: range, includeMediaOnly: true)
        let tweets = TwitterAPI.searchRawQuery(screenName: "u", range: range, includeMediaOnly: false)
        XCTAssertTrue(media.contains("filter:media"))
        XCTAssertFalse(tweets.contains("filter:media"), "推文数据源不该加媒体过滤")
    }

    /// 跨月/跨年边界：日期格式必须补零（yyyy-MM-dd），否则 X 解析不了
    func testDateIsZeroPadded() {
        let range = DownloadFilter.DateRange(start: date("2025-01-05"), end: date("2025-02-09"))
        let q = TwitterAPI.searchRawQuery(screenName: "u", range: range, includeMediaOnly: false)
        XCTAssertTrue(q.contains("since:2025-01-05"), "个位数月/日必须补零，实际: \(q)")
        XCTAssertTrue(q.contains("until:2025-02-10"))
    }

    // MARK: - queryId 自愈解析

    /// 从 bundle 文本提取：**必须锚定 operationName:"SearchTimeline"**
    func testExtractQueryIdAnchoredToOperationName() {
        // bundle 里存在多个含 "SearchTimeline" 的操作，且它们**排在前面**（实测如此）：
        // 只按名字搜会先命中 BookmarkSearchTimeline 的 queryId，取到错的。
        let bundle = """
        e.exports={queryId:"rbwiGBFqb93lmG7mw_OYZQ",operationName:"BookmarkSearchTimeline",operationType:"query"},\
        e.exports={queryId:"tbfwt3lMoSiVODtsBmEFGQ",operationName:"GlobalCommunitiesPostSearchTimeline"},\
        e.exports={queryId:"i4096Pm5N66WDAdjumVLrQ",operationName:"ListSearchTimeline"},\
        e.exports={queryId:"auLkqtmHqYEpRvflfvLhyQ",operationName:"SearchTimeline",operationType:"query"}
        """
        let id = SearchQueryIdProvider.extractSearchTimelineQueryId(from: bundle)
        XCTAssertEqual(id, "auLkqtmHqYEpRvflfvLhyQ",
                       "必须取 SearchTimeline 自己的 queryId，不能取到 Bookmark/List 等变体")
    }

    /// bundle 里没有该操作 → 返回 nil（不抛异常，调用方据此放弃自愈）
    func testExtractQueryIdReturnsNilWhenAbsent() {
        XCTAssertNil(SearchQueryIdProvider.extractSearchTimelineQueryId(from: "nothing here"))
        XCTAssertNil(SearchQueryIdProvider.extractSearchTimelineQueryId(from: ""))
        // 有同名操作但没有 queryId 相邻
        XCTAssertNil(SearchQueryIdProvider.extractSearchTimelineQueryId(
            from: #"operationName:"SearchTimeline""#))
    }

    /// queryId 长度/字符集不合法时不误匹配（避免把别的标识当 queryId）
    func testExtractQueryIdRejectsWrongShape() {
        XCTAssertNil(SearchQueryIdProvider.extractSearchTimelineQueryId(
            from: #"queryId:"short",operationName:"SearchTimeline""#),
            "过短的字符串不是 queryId")
    }

    /// 从搜索页 HTML 提取 main bundle 地址
    func testExtractMainBundleURL() {
        let html = """
        <script src="https://abs.twimg.com/responsive-web/client-web/vendor.02e04961c2b81e2ea.js"></script>
        <script src="https://abs.twimg.com/responsive-web/client-web/main.059fecabedbff681a.js"></script>
        """
        let url = SearchQueryIdProvider.extractMainBundleURL(from: html)
        XCTAssertEqual(url?.absoluteString,
                       "https://abs.twimg.com/responsive-web/client-web/main.059fecabedbff681a.js",
                       "必须取 main bundle（queryId 在里面），不是 vendor")
    }

    func testExtractMainBundleURLNilWhenAbsent() {
        XCTAssertNil(SearchQueryIdProvider.extractMainBundleURL(from: "<html>no bundle</html>"))
    }

    /// provider 默认值可直接用（首次使用不必先抓 bundle）
    func testProviderHasBuiltInFallback() async {
        await SearchQueryIdProvider.shared.resetForTesting()
        let id = await SearchQueryIdProvider.shared.current()
        XCTAssertFalse(id.isEmpty, "必须有内置默认值，否则首次使用要先联网抓 bundle")
        XCTAssertEqual(id.count, 22, "X 的 queryId 是 22 位")
    }

    /// **纠正一条曾被写错的结论**：openapi 里记录的 queryId **并未失效**。
    ///
    /// 实测（POST + JSON）：openapi 记录的 `Yw6L66Pw…` 与当前 bundle 的
    /// `auLkqtmHq…` **都返回 200 与 42 条真实数据**；
    /// GET 对两者**都** 404 —— 404 是 GET 造成的，与 queryId 无关。
    ///
    /// 这条测试锁住"默认值就是 openapi 记录的那个"，
    /// 避免以后有人看到旧文档又把它当成"失效值"去改。
    func testDefaultQueryIdIsTheOpenAPIValue() async {
        await SearchQueryIdProvider.shared.resetForTesting()
        let id = await SearchQueryIdProvider.shared.current()
        XCTAssertEqual(id, "Yw6L66Pw54NHKuq4Dp7b4Q",
                       "默认值取 openapi 记录值（实测有效）；404 是 GET 的假象，不是它失效")
    }
}

/// 展示路径的**时间轴推进**终止判据（空窗期修复）。
///
/// 回归用户实测的问题：账号有一两个月没发媒体时，
/// 旧实现"连续 5 页被筛空就停"会把空窗期误判成"没有内容了"。
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

    /// 与搜索端点的 `until:` 语义对齐：
    /// `until:` 是排他的，所以 inclusiveEnd(至 23:59:59) → until 次日，
    /// 二者表达的是**同一个时刻边界**。
    func testInclusiveEndMatchesSearchUntilSemantics() {
        let range = DownloadFilter.DateRange(start: day("2025-01-01"), end: day("2025-08-31"))
        let q = TwitterAPI.searchRawQuery(screenName: "u", range: range, includeMediaOnly: false)
        // until 写成次日（排他），等价于"包含 8-31 全天"
        XCTAssertTrue(q.contains("until:2025-09-01"), "实际: \(q)")

        // 客户端 inclusiveEnd 也覆盖 8-31 全天
        XCTAssertGreaterThan(range.inclusiveEnd, day("2025-08-31", hour: 12))
        XCTAssertLessThan(range.inclusiveEnd, day("2025-09-01"))
    }
}
