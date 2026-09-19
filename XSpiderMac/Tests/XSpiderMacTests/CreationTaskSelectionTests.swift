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

    private func post(_ id: String, mediaIds: [String]) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                                      mediaCount: nil, registerTime: nil),
                    createdAt: Date(), fullText: "t", tags: [], views: nil, lang: nil,
                    retweeted: nil, retweetCount: nil, replyCount: nil,
                    possiblySensitive: nil, favorited: nil, favoriteCount: nil,
                    bookmarkCount: nil, bookmarked: nil,
                    medias: mediaIds.map { media($0) })
    }

    /// 复刻 `CreationTaskStore.runCreationTask` 里对单个媒体的取舍判断。
    /// 与生产代码保持一致：先查排除集（跳过并计数），再查包含集（只留勾选的）。
    private func decide(post: TwitterPost, media: TwitterMedia, task: CreationTask)
        -> (enqueue: Bool, countedAsSkip: Bool) {
        let key = MediaSelectionKey.make(post: post, media: media)
        if task.excludedKeys.contains(key) { return (false, true) }
        if !task.includedKeys.isEmpty {
            return (task.includedKeys.contains(key), false)
        }
        return (true, false)
    }

    private func task(excluded: Set<String> = [], included: Set<String> = []) -> CreationTask {
        CreationTask(id: "t", user: TwitterUser(screenName: "u", avatar: "", name: "U",
                                                id: "1", mediaCount: nil, registerTime: nil),
                     filter: DownloadFilter(mediaTypes: [.photo, .video, .gif], source: .medias),
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
}
