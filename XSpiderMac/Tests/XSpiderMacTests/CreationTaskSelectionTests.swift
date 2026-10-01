import XCTest
@testable import XSpiderMac

/// 创建任务与选择集的接线：**全选后取消几个**能真正让爬虫跳过那几个。
///
/// 这组不跑真实爬虫（那要网络），而是验证"选择集 → 任务 → 过滤判据"这条链路：
/// 爬虫循环里对每个媒体的取舍逻辑，抽出来单独断言。
final class CreationTaskSelectionTests: XCTestCase {

    private func media(_ id: String, type: MediaType = .photo) -> TwitterMedia {
        TwitterMedia(id: id, url: "https://x/\(id).jpg", width: 10, height: 10,
                     type: type, videoInfo: nil, createdTime: nil)
    }

    private func post(_ id: String, mediaIds: [String],
                      createdAt: Date? = Date(), type: MediaType = .photo) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                                      mediaCount: nil, registerTime: nil),
                    createdAt: createdAt, fullText: "t", tags: [], views: nil, lang: nil,
                    retweeted: nil, retweetCount: nil, replyCount: nil,
                    possiblySensitive: nil, favorited: nil, favoriteCount: nil,
                    bookmarkCount: nil, bookmarked: nil,
                    medias: mediaIds.map { media($0, type: type) })
    }

    /// 取舍判据：**直接调生产代码**（`CreationTaskStore.decide`）。
    ///
    /// 以前这里复刻了一份同样的逻辑——生产代码改了它照样绿，那种测试只证明
    /// "我抄的那份是对的"。现在判据只有一份，改坏了这里就会红。
    ///
    /// 日期边界用"无限宽"：这组用例只验选择集；日期与去重有各自的用例（见文件末尾）。
    private func decide(post: TwitterPost, media: TwitterMedia, task: CreationTask)
        -> (enqueue: Bool, countedAsSkip: Bool) {
        var seen = Set<String>()
        return decide(post: post, media: media, task: task, seen: &seen)
    }

    private func decide(post: TwitterPost, media: TwitterMedia, task: CreationTask,
                        seen: inout Set<String>, since: Date = .distantPast,
                        until: Date = .distantFuture) -> (enqueue: Bool, countedAsSkip: Bool) {
        switch CreationTaskStore.decide(post: post, media: media, task: task,
                                        since: since, until: until, seenDownloadURLs: &seen) {
        case .enqueue: return (true, false)
        case .countedAsSkip: return (false, true)
        case .ignored: return (false, false)
        }
    }

    private func task(excluded: Set<String> = [], included: Set<String> = [],
                      types: [MediaType] = [.photo, .video, .gif]) -> CreationTask {
        CreationTask(id: "t", user: TwitterUser(screenName: "u", avatar: "", name: "U",
                                                id: "1", mediaCount: nil, registerTime: nil),
                     filter: DownloadFilter(mediaTypes: types, source: .medias),
                     excludedKeys: excluded, includedKeys: included)
    }

    /// 默认（无选择集）= 全量：所有媒体都入队
    func testNoSelectionEnqueuesEverything() {
        let p = post("100", mediaIds: ["m1", "m2"])
        let t = task()
        for m in p.medias! {
            let r = decide(post: p, media: m, task: t)
            XCTAssertTrue(r.enqueue, "无选择集时全部入队（等价旧「下载全部」）")
            XCTAssertFalse(r.countedAsSkip)
        }
    }

    /// **核心需求**：全选后取消 m1、m2 → 创建任务时跳过它们，其余入队
    func testExcludedMediaAreSkippedAndCounted() {
        let p = post("100", mediaIds: ["m1", "m2", "m3", "m4"])
        let t = task(excluded: ["100/m1", "100/m2"])
        var enqueued: [String] = []
        var skipped = 0
        for m in p.medias! {
            let r = decide(post: p, media: m, task: t)
            if r.enqueue { enqueued.append(m.id!) }
            if r.countedAsSkip { skipped += 1 }
        }
        XCTAssertEqual(enqueued, ["m3", "m4"], "取消的两个不进队列")
        XCTAssertEqual(skipped, 2, "取消的计入 skipCount（用户能看到跳过了几个）")
    }

    /// 只勾了几个（include 态）：只为它们建任务，其余不入队
    func testIncludedOnlyEnqueuesPicked() {
        let p = post("100", mediaIds: ["m1", "m2", "m3"])
        let t = task(included: ["100/m3"])
        let enqueued = p.medias!.filter { decide(post: p, media: $0, task: t).enqueue }
        XCTAssertEqual(enqueued.map(\.id), ["m3"], "只处理勾选的那一个")
    }

    /// 排除集与包含集同时存在时，排除优先（不会被包含集"救回来"）
    func testExclusionWinsOverInclusion() {
        let p = post("100", mediaIds: ["m1", "m2"])
        let t = task(excluded: ["100/m1"], included: ["100/m1", "100/m2"])
        let r1 = decide(post: p, media: p.medias![0], task: t)
        XCTAssertFalse(r1.enqueue, "排除优先：即使同时被勾选也不下载")
        XCTAssertTrue(r1.countedAsSkip)
        XCTAssertTrue(decide(post: p, media: p.medias![1], task: t).enqueue)
    }

    /// 排除项不由媒体类型过滤"顺带"跳过（它必须被单独计数）
    func testExcludedAcrossDifferentPosts() {
        let p1 = post("100", mediaIds: ["m1"])
        let p2 = post("200", mediaIds: ["m1"])   // 同 mediaId 不同 post
        let t = task(excluded: ["100/m1"])
        XCTAssertFalse(decide(post: p1, media: p1.medias![0], task: t).enqueue)
        XCTAssertTrue(decide(post: p2, media: p2.medias![0], task: t).enqueue,
                      "键含 postId，不能误伤其他推文下的同名 mediaId")
    }

    // MARK: - 防重复创建要考虑选择集

    @MainActor
    func testDuplicateCheckDistinguishesSelections() {
        let store = CreationTaskStore()
        let user = TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                               mediaCount: nil, registerTime: nil)
        let filter = DownloadFilter(mediaTypes: [.photo], source: .medias)

        var all = MediaSelection(); all.selectAll()
        store.createCreationTask(user: user, filter: filter, selection: all)
        XCTAssertNil(store.creationBlockedReason, "第一个任务应能入队")
        XCTAssertEqual(store.creationTasks.count, 1)

        // 完全相同（同样全选、无排除）→ 拒绝
        store.createCreationTask(user: user, filter: filter, selection: all)
        XCTAssertEqual(store.creationTasks.count, 1, "相同条件不应重复入队")
        XCTAssertNotNil(store.creationBlockedReason)

        // 全选但排除了一个 → 是**不同**任务，应允许
        var withExclusion = MediaSelection(); withExclusion.selectAll(); withExclusion.toggle("1/m1")
        store.createCreationTask(user: user, filter: filter, selection: withExclusion)
        XCTAssertEqual(store.creationTasks.count, 2, "排除集不同属于不同任务")

        // 清理（避免影响其他测试）
        for t in store.creationTasks { store.removeCreationTask(t.id) }
    }

    // MARK: - 日期边界（本地日历，精确的一层由外壳做）

    /// `since`/`until` 是**本地日历**边界；组件的粗筛按 UTC 天、比它宽一天，
    /// 所以精确判定必须留在这里——否则 UTC+8 下开始日的最初 8 小时会被丢掉。
    func testDateBoundaryIsDecidedLocally() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let until = since.addingTimeInterval(3600)
        let t = task()
        var seen = Set<String>()

        let inside = post("100", mediaIds: ["m1"], createdAt: since.addingTimeInterval(60))
        XCTAssertTrue(decide(post: inside, media: inside.medias![0], task: t,
                             seen: &seen, since: since, until: until).enqueue)

        let tooOld = post("200", mediaIds: ["m2"], createdAt: since.addingTimeInterval(-1))
        let r = decide(post: tooOld, media: tooOld.medias![0], task: t,
                       seen: &seen, since: since, until: until)
        XCTAssertFalse(r.enqueue)
        XCTAssertTrue(r.countedAsSkip, "日期以外的媒体要计入跳过数（用户看得到）")

        let tooNew = post("300", mediaIds: ["m3"], createdAt: until.addingTimeInterval(1))
        XCTAssertFalse(decide(post: tooNew, media: tooNew.medias![0], task: t,
                              seen: &seen, since: since, until: until).enqueue)
    }

    /// **没有 `created_at` 的条目放行**（docs/02 §D4：不能因为解析不到时间就丢内容）。
    func testPostWithoutCreatedAtIsKept() {
        let p = post("100", mediaIds: ["m1"], createdAt: nil)
        var seen = Set<String>()
        XCTAssertTrue(decide(post: p, media: p.medias![0], task: task(), seen: &seen,
                             since: .distantFuture, until: .distantFuture).enqueue,
                      "时间缺失不该被当成「不符合日期范围」")
    }

    // MARK: - 媒体类型与去重

    /// 类型不符的媒体**不入队、也不计入跳过数**（它在旧的 `where` 里就被滤掉了）。
    func testMediaTypeMismatchIsIgnoredNotCounted() {
        let photo = post("100", mediaIds: ["m1"], type: .photo)
        let t = task(types: [.video])
        var seen = Set<String>()
        let r = decide(post: photo, media: photo.medias![0], task: t, seen: &seen)
        XCTAssertFalse(r.enqueue)
        XCTAssertFalse(r.countedAsSkip, "类型不符不是「跳过」，不该进跳过计数")
    }

    /// 同一次任务内同一个 URL 只入队一次（块的边界可能让同一媒体再次出现）。
    func testSameURLIsEnqueuedOnlyOncePerTask() {
        let p = post("100", mediaIds: ["m1", "m2"])
        // 两个媒体指向同一个 URL → 第二个要静默跳过
        let same = TwitterMedia(id: "m2", url: p.medias![0].url, width: 10, height: 10,
                                type: .photo, videoInfo: nil, createdTime: nil)
        var seen = Set<String>()
        XCTAssertTrue(decide(post: p, media: p.medias![0], task: task(), seen: &seen).enqueue)
        let second = decide(post: p, media: same, task: task(), seen: &seen)
        XCTAssertFalse(second.enqueue)
        XCTAssertFalse(second.countedAsSkip, "重复不是「跳过」")
    }

    // MARK: - 爬取策略

    /// 策略把日期**各放宽一天**交给组件（组件按 UTC 天比较），
    /// 精确边界由外壳按候选的 `created_at` 再判一次。
    func testCrawlStrategyWidensTheDateWindowByOneDay() {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 12))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12))!
        let filter = DownloadFilter(dateRange: .init(start: start, end: end),
                                    mediaTypes: [.photo, .video], source: .medias)

        let strategy = CreationTaskStore.crawlStrategy(for: filter)
        XCTAssertEqual(strategy[string: "since"], "2026-09-09", "开始日放宽一天")
        XCTAssertEqual(strategy[string: "until"], "2026-09-21", "结束日放宽一天（end 是当天零点）")

        let limits = strategy[object: "limits"]
        XCTAssertEqual(limits?[int: "max_pages"], CreationTaskStore.crawlChunkPages,
                       "分块大小要传下去，否则一次调用会跑到底（进度看不见、取消不响应）")
        XCTAssertEqual(limits?[int: "empty_page_limit"], CreationTaskStore.maxConsecutiveEmptyPages)
        XCTAssertEqual(strategy[array: "media_types"]?.compactMap(\.asString),
                       ["photo", "video"], "媒体类型作为粗筛透传")
    }

    /// 没有日期范围时不传 since/until（无限宽），否则会把全部内容挡掉。
    func testCrawlStrategyOmitsDatesWhenNoRange() {
        let strategy = CreationTaskStore.crawlStrategy(
            for: DownloadFilter(mediaTypes: [.photo], source: .medias))
        XCTAssertNil(strategy[string: "since"])
        XCTAssertNil(strategy[string: "until"])
    }
}
