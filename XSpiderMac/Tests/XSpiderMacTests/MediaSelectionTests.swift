import XCTest
@testable import XSpiderMac

/// 媒体选择模型：**勾选 = 要下载**，且「全选」必须表示"全部"。
///
/// 需求原文（已澄清）：
/// - 「全选后取消几个 → 跳过**取消的**这几个」；
/// - 「选了几个媒体后点击反选也是同样的道理」；
/// - 「全选 = 全部」，不能只是"已加载的那些"，否则用户不清楚选了什么。
///
/// 这组测试锁定 include/exclude 两种模式的语义与切换。
final class MediaSelectionTests: XCTestCase {

    // MARK: - 基本语义

    func testStartsEmptyInIncludeMode() {
        let s = MediaSelection()
        XCTAssertFalse(s.isAllSelected)
        XCTAssertTrue(s.includedKeys.isEmpty)
        XCTAssertTrue(s.excludedKeys.isEmpty)
        XCTAssertEqual(s.selectedCount(knownTotal: nil), 0)
    }

    /// 逐个点选：勾选集合 = 要下载
    func testIncludeModeTracksExplicitPicks() {
        var s = MediaSelection()
        s.toggle("a")
        s.toggle("b")
        XCTAssertTrue(s.isSelected("a"))
        XCTAssertTrue(s.isSelected("b"))
        XCTAssertFalse(s.isSelected("c"))
        XCTAssertEqual(s.selectedCount(knownTotal: 10), 2)
        XCTAssertEqual(s.includedKeys, ["a", "b"])
        XCTAssertTrue(s.excludedKeys.isEmpty, "逐项勾选态没有排除项")

        // 再点一下取消
        s.toggle("a")
        XCTAssertFalse(s.isSelected("a"))
        XCTAssertEqual(s.selectedCount(knownTotal: 10), 1)
    }

    /// 全选 = 除排除项外全部（含未加载部分）
    func testSelectAllMeansEverything() {
        var s = MediaSelection()
        s.selectAll()
        XCTAssertTrue(s.isAllSelected)
        XCTAssertTrue(s.isSelected("anything"), "全选后任意项都应算已选（含未加载的）")
        XCTAssertTrue(s.includedKeys.isEmpty, "全选态不列举具体项（未加载的列举不出来）")
        XCTAssertTrue(s.excludedKeys.isEmpty)
    }

    /// **需求核心**：全选后取消几个 → 构建任务时跳过**取消的**这几个
    func testSelectAllThenDeselectSkipsTheDeselected() {
        var s = MediaSelection()
        s.selectAll()
        s.toggle("x")   // 取消 x
        s.toggle("y")   // 取消 y

        XCTAssertEqual(s.excludedKeys, ["x", "y"], "取消的项进入排除集合（爬虫据此跳过）")
        XCTAssertFalse(s.isSelected("x"), "x 已被取消")
        XCTAssertFalse(s.isSelected("y"))
        XCTAssertTrue(s.isSelected("z"), "其余任意项仍要下载")
        XCTAssertTrue(s.isAllSelected, "仍是全选态（只是排除了两个）")
        XCTAssertTrue(s.includedKeys.isEmpty, "不能退化成 include：否则未加载部分就丢了")
    }

    /// 全选态选择数 = 总数 − 排除数；总数未知时返回 nil
    func testSelectAllCountNeedsTotal() {
        var s = MediaSelection()
        s.selectAll()
        s.toggle("a")
        XCTAssertNil(s.selectedCount(knownTotal: nil),
                     "未加载完不知道总数 → 返回 nil，UI 据此不显示分母")
        XCTAssertEqual(s.selectedCount(knownTotal: 10), 9)
        XCTAssertEqual(s.selectedCount(knownTotal: 0), 0, "不能出负数")
    }

    // MARK: - 反选

    /// 「选了几个后反选」：补集 = 剩下的全部（与全选+取消等价）
    func testInvertFromPartialSelection() {
        var s = MediaSelection()
        s.toggle("a")
        s.toggle("b")      // 选了 2 个
        s.invert()         // 反选

        XCTAssertTrue(s.isAllSelected, "反选后语义变成「除 a、b 外全部」")
        XCTAssertEqual(s.excludedKeys, ["a", "b"])
        XCTAssertFalse(s.isSelected("a"))
        XCTAssertTrue(s.isSelected("z"))
    }

    /// 反选是**对合**：连按两次回到原状
    func testInvertIsInvolution() {
        var s = MediaSelection()
        s.toggle("a")
        let before = s
        s.invert()
        s.invert()
        XCTAssertEqual(s, before, "反选两次应回到原状态（不丢不增）")

        var all = MediaSelection()
        all.selectAll()
        let allBefore = all
        all.invert()
        all.invert()
        XCTAssertEqual(all, allBefore)
    }

    /// 全选态反选 → 变成"只要被排除的那几个"（补集）
    func testInvertFromSelectAllKeepsOnlyExcluded() {
        var s = MediaSelection()
        s.selectAll()
        s.toggle("keep1")
        s.toggle("keep2")
        s.invert()
        XCTAssertFalse(s.isAllSelected)
        XCTAssertEqual(s.includedKeys, ["keep1", "keep2"],
                       "全选态反选 = 只要当初被取消的那几个")
        XCTAssertTrue(s.excludedKeys.isEmpty)
    }

    // MARK: - 全不选 / 撤销

    func testSelectNoneClearsEverything() {
        var s = MediaSelection()
        s.selectAll()
        s.toggle("a")
        s.selectNone()
        XCTAssertFalse(s.isAllSelected)
        XCTAssertTrue(s.includedKeys.isEmpty)
        XCTAssertTrue(s.excludedKeys.isEmpty)
        XCTAssertEqual(s.selectedCount(knownTotal: 100), 0)
    }

    func testResetReturnsToInitial() {
        var s = MediaSelection()
        s.selectAll()
        s.toggle("a")
        s.reset()
        XCTAssertEqual(s, MediaSelection())
    }

    // MARK: - 选择键

    /// 键必须**稳定可复现**（爬虫侧要用同一个键判断跳过），不能掺 UUID
    func testSelectionKeyIsStableAndDeterministic() {
        let post = TwitterPost(id: "100", user: mkUser(), createdAt: nil, fullText: "t",
                               tags: [], views: nil, lang: nil, retweeted: nil,
                               retweetCount: nil, replyCount: nil, possiblySensitive: nil,
                               favorited: nil, favoriteCount: nil, bookmarkCount: nil,
                               bookmarked: nil, medias: nil)
        let media = TwitterMedia(id: "m1", url: "https://x/a.jpg", width: 1, height: 1,
                                 type: .photo, videoInfo: nil, createdTime: nil)
        let k1 = MediaSelectionKey.make(post: post, media: media)
        let k2 = MediaSelectionKey.make(post: post, media: media)
        XCTAssertEqual(k1, "100/m1")
        XCTAssertEqual(k1, k2, "同一媒体每次生成的键必须一致（旧实现掺 UUID，无法与爬虫对应）")

        // id 缺失时用 url 兜底
        let noId = TwitterMedia(id: nil, url: "https://x/b.jpg", width: 1, height: 1,
                                type: .photo, videoInfo: nil, createdTime: nil)
        XCTAssertEqual(MediaSelectionKey.make(post: post, media: noId), "100/https://x/b.jpg")
    }

    private func mkUser() -> TwitterUser {
        TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                    mediaCount: nil, registerTime: nil)
    }
}

/// 展示筛选：日期范围与媒体类型在**浏览**路径生效。
///
/// 用户反馈「调了时间范围，点确认不能按时间范围显示，还是显示全部媒体」——
/// 根因是 `dateRange` 此前只被爬虫使用，展示路径完全没读它。
final class DisplayFilterTests: XCTestCase {

    private func post(_ id: String, daysAgo: Int?, mediaTypes: [MediaType] = []) -> TwitterPost {
        let created = daysAgo.map { Date().addingTimeInterval(-Double($0) * 86400) }
        let medias: [TwitterMedia]? = mediaTypes.isEmpty ? nil : mediaTypes.enumerated().map { i, t in
            TwitterMedia(id: "\(id)-m\(i)", url: "https://x/\(id)-\(i).jpg",
                         width: 10, height: 10, type: t, videoInfo: nil, createdTime: created)
        }
        return TwitterPost(id: id,
                           user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                                             mediaCount: nil, registerTime: nil),
                           createdAt: created, fullText: "t", tags: [], views: nil, lang: nil,
                           retweeted: nil, retweetCount: nil, replyCount: nil,
                           possiblySensitive: nil, favorited: nil, favoriteCount: nil,
                           bookmarkCount: nil, bookmarked: nil, medias: medias)
    }

    private func filter(days: Int? = nil, types: [MediaType]? = nil) -> DownloadFilter {
        var f = DownloadFilter(mediaTypes: types, source: .medias)
        if let days {
            f.dateRange = DownloadFilter.DateRange(
                start: Date().addingTimeInterval(-Double(days) * 86400),
                end: Date().addingTimeInterval(86400))
        }
        return f
    }

    /// 日期范围外的推文要被筛掉（这就是"点确定没反应"的修复点）
    func testDateRangeFiltersOutOldPosts() {
        let posts = [post("recent", daysAgo: 1), post("old", daysAgo: 100)]
        let result = HomepageStore.applyDisplayFilter(posts, filter: filter(days: 7))
        XCTAssertEqual(result.map(\.id), ["recent"], "范围外的推文必须被筛掉")
    }

    /// **无 createdAt 必须放行**（与爬虫同语义：缺字段不等于不在范围内）
    func testPostsWithoutDateAreKept() {
        let posts = [post("nodate", daysAgo: nil), post("old", daysAgo: 100)]
        let result = HomepageStore.applyDisplayFilter(posts, filter: filter(days: 7))
        XCTAssertTrue(result.map(\.id).contains("nodate"),
                      "无日期推文不能因为筛选而消失")
        XCTAssertFalse(result.map(\.id).contains("old"))
    }

    /// 无日期范围时不筛日期（默认全部保留）
    func testNoDateRangeKeepsAll() {
        let posts = [post("a", daysAgo: 1), post("b", daysAgo: 1000)]
        XCTAssertEqual(HomepageStore.applyDisplayFilter(posts, filter: filter()).count, 2)
    }

    /// 媒体类型：只勾图片时，纯视频推文被筛掉，含图片的留下
    func testMediaTypeFiltersPosts() {
        let posts = [
            post("photoOnly", daysAgo: 1, mediaTypes: [.photo]),
            post("videoOnly", daysAgo: 1, mediaTypes: [.video]),
            post("mixed", daysAgo: 1, mediaTypes: [.video, .photo]),
        ]
        let result = HomepageStore.applyDisplayFilter(posts, filter: filter(types: [.photo]))
        XCTAssertEqual(result.map(\.id), ["photoOnly", "mixed"],
                       "含所选类型的推文留下（mixed 有图片所以留下）")
    }

    /// 纯文字推文（无媒体）不受媒体类型筛选影响——否则勾掉"视频"会让纯文字推文一起消失
    func testTextOnlyPostsSurviveTypeFilter() {
        let posts = [post("text", daysAgo: 1), post("video", daysAgo: 1, mediaTypes: [.video])]
        let result = HomepageStore.applyDisplayFilter(posts, filter: filter(types: [.photo]))
        XCTAssertTrue(result.map(\.id).contains("text"), "无媒体推文不受类型筛选影响")
    }

    /// 全选三种类型 = 不筛（避免把"没勾任何类型"与"全勾"混为一谈）
    func testAllTypesSelectedDoesNotFilter() {
        let posts = [post("video", daysAgo: 1, mediaTypes: [.video])]
        let result = HomepageStore.applyDisplayFilter(
            posts, filter: filter(types: [.photo, .video, .gif]))
        XCTAssertEqual(result.count, 1)
    }

    /// 两个条件同时生效（与关系）
    func testDateAndTypeCombine() {
        let posts = [
            post("recentPhoto", daysAgo: 1, mediaTypes: [.photo]),
            post("recentVideo", daysAgo: 1, mediaTypes: [.video]),
            post("oldPhoto", daysAgo: 100, mediaTypes: [.photo]),
        ]
        let result = HomepageStore.applyDisplayFilter(posts, filter: filter(days: 7, types: [.photo]))
        XCTAssertEqual(result.map(\.id), ["recentPhoto"], "日期与类型是与关系")
    }
}
