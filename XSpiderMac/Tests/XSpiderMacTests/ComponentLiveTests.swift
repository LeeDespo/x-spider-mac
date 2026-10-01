import XCTest
@testable import XSpiderMac

/// **接线的真实验证**：应用自己的那条路（`TwitterAPI` → 组件）能不能取到真数据。
///
/// 与 `XSpiderMacTests` 里其它测试不同，这条**要联网**，所以默认跳过：
///
/// ```bash
/// XSPIDER_LIVE=1 xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
///   -destination 'platform=macOS,arch=arm64' \
///   -derivedDataPath build/DerivedData \
///   test -only-testing:XSpiderMacTests/ComponentLiveTests
/// ```
///
/// 为什么不放进默认测试：它消耗账号配额、依赖代理与组件部署，跑在每次构建里
/// 只会让人学会"红了也继续"。要的是**按需跑、跑起来就能说明问题**。
final class ComponentLiveTests: XCTestCase {

    private var isLive: Bool { ProcessInfo.processInfo.environment["XSPIDER_LIVE"] == "1" }

    /// 应用启动时把 cookie 落在 UserDefaults 里（AppStore.cookieString 的 didSet）；
    /// 测试宿主就是应用本身，所以这里读得到。
    private var storedCookie: String {
        UserDefaults.standard.string(forKey: "app.cookieString") ?? ""
    }

    func testComponentIsReachableAndReportsTransport() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")

        let info = try await XSpiderComponent.shared.ensureStarted()
        XCTAssertEqual(info.transport, "sidecar", "组件应当自报 sidecar 形态")
        XCTAssertEqual(info.contractVersion.split(separator: ".").first.map(String.init), "1",
                       "契约主版本必须是 1.x")
        // 组件必须来自**外部目录**（这样换组件才是换文件，不必重新构建应用）
        XCTAssertTrue(info.binaryPath.contains("XSpiderCore"),
                      "应当加载外部目录里的组件，实际：\(info.binaryPath)")
    }

    func testFetchUserThroughTheAppPath() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")
        let cookie = storedCookie
        try XCTSkipIf(cookie.isEmpty, "应用里还没有 cookie，先在设置里导入一次")

        // 用**应用自己的设置**（代理等）配置组件——这正是接入后启动时的真实路径
        let proxy = await MainActor.run { SettingsStore.shared.settings.proxy }
        await TwitterAPI.shared.configure(cookie: cookie, proxy: proxy)

        let user = try await TwitterAPI.shared.getUser(screenName: "tesla")
        XCTAssertFalse(user.id.isEmpty, "id 不能为空（组件的 post/user 映射掉了字段）")
        XCTAssertEqual(user.screenName.lowercased(), "tesla")
        XCTAssertTrue(user.avatar.hasPrefix("https://"),
                      "头像必须是绝对 URL（组件已归一化），实际：\(user.avatar)")
        XCTAssertNotNil(user.mediaCount, "媒体数应当有值")
    }




    /// 账户信息改由组件回答（`auth.whoami`）：拿得到 screen_name 与头像就是通的。
    @MainActor
    func testWhoamiThroughTheAppPath() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")
        let cookie = storedCookie
        try XCTSkipIf(cookie.isEmpty, "应用里还没有 cookie")

        let proxy = await MainActor.run { SettingsStore.shared.settings.proxy }
        await TwitterAPI.shared.configure(cookie: cookie, proxy: proxy)

        let info = try await TwitterAPI.shared.getAccountInfo()
        XCTAssertFalse(info.screenName.isEmpty, "whoami 没拿到 screen_name（cookie 失效？）")
        XCTAssertTrue(info.avatar.hasPrefix("http"), "头像应当是绝对 URL：\(info.avatar)")
    }

    /// 关注态：拿得到布尔值即可（true/false 都算通过，我们不假设测试账号关注了谁）。
    @MainActor
    func testIsFollowingThroughTheAppPath() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")
        let cookie = storedCookie
        try XCTSkipIf(cookie.isEmpty, "应用里还没有 cookie")

        let proxy = await MainActor.run { SettingsStore.shared.settings.proxy }
        await TwitterAPI.shared.configure(cookie: cookie, proxy: proxy)

        // `useCache: false` 强制走一次真实请求（缓存命中不能算验证）
        _ = try await TwitterAPI.shared.isFollowing(screenName: "tesla", useCache: false)
    }

    /// **写操作的连线检查，但刻意不产生副作用**：用一个不存在的推文 id 调 `favorite`。
    ///
    /// 期望拿到结构化错误（`not_found` 或 `upstream`/`invalid_request`）——
    /// 这已经证明：参数被正确组装、请求被签名并带上了凭据、X 真的处理了它。
    /// **不拿真实推文试**：那会给作者发通知、在账号上留下痕迹，属于"测试不该做的事"。
    @MainActor
    func testMutateIsWiredWithoutSideEffects() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")
        let cookie = storedCookie
        try XCTSkipIf(cookie.isEmpty, "应用里还没有 cookie")

        let proxy = await MainActor.run { SettingsStore.shared.settings.proxy }
        await TwitterAPI.shared.configure(cookie: cookie, proxy: proxy)

        // 1) 参数校验：缺 tweet_id 必须在**发请求之前**就被挡住
        do {
            _ = try await XSpiderComponent.shared.call("fetch.mutate", ["action": .string("favorite")])
            XCTFail("缺 tweet_id 应当报 invalid_request")
        } catch let error as XSpiderComponent.ComponentError {
            XCTAssertEqual(error.code, "invalid_request", "实际：\(error)")
        }

        // 2) 一个**不可能存在**的推文 id：链路是真的，但什么都没改。
        //
        // 用超长数字而不是小整数：我第一次写的是 `"1"`（以为它不存在），
        // 结果 X **真的接受了那次点赞**——测试在用户的账号上留下了一个赞。
        // 教训：验证写操作时，"不存在的目标"必须选**结构上不可能存在**的，
        // 而不是"我觉得不存在"的。
        do {
            _ = try await XSpiderComponent.shared.call("fetch.mutate", [
                "action": .string("favorite"), "tweet_id": .string("99999999999999999999999"),
            ])
            XCTFail("对不存在（且格式越界）的推文点赞不该成功")
        } catch let error as XSpiderComponent.ComponentError {
            // 要的是"X **收到了**并**拒绝了**"：不是 unauthorized（凭据/签名没走通），
            // 也不是 transport（压根没连上）。
            //
            // 实测：越界的 id 会被 X 自己的 `strconv.ParseInt` 拒掉，返回 HTTP 200 +
            // 一条**没有 code** 的错误（落到 upstream）。144（"No status found"）是
            // "语法合法但不存在"的 id 才给的——那条映射由组件侧单测覆盖，
            // **不在这里试**：猜一个"看起来不存在"的小 id 有可能真的存在
            // （我第一次用 `"1"`，结果真的在账号上留下了一个赞）。
            //
            // **刻意不钉死具体的 code**：X 先校验账号的写权限还是先解析 id，
            // 决定了我们拿到 141（→ unauthorized）还是 ParseInt（→ upstream）。
            // 这里要证明的是"X 收到了并拒绝了"，不是"恰好是哪个码"。
            XCTAssertTrue(["upstream", "not_found", "unauthorized"].contains(error.code ?? ""),
                          "应当是 X 明确拒绝的结构化错误，实际：\(error)")
            XCTAssertFalse(error.isTransport, "连不上的话这条测试没有意义：\(error)")
        }
    }

    /// **视频这条路的回归测试**：封面必须是图片、可播放地址必须是 mp4，两者不能混。
    ///
    /// 用户实测报过"视频无法显示、图片正常"：原因是映射把 `TwitterMedia.url` 填成了
    /// **可下载的 mp4**，而界面拿它当封面图解码（`thumbnailURL(for:)` / `loadHD()`）
    /// → 视频格子整片空白。契约里当时根本没有封面字段，所以这条也是"接入才暴露"的缺口。
    @MainActor
    func testVideoMediaHasAPosterAndAPlayableURL() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")
        let cookie = storedCookie
        try XCTSkipIf(cookie.isEmpty, "应用里还没有 cookie")

        let proxy = await MainActor.run { SettingsStore.shared.settings.proxy }
        await TwitterAPI.shared.configure(cookie: cookie, proxy: proxy)

        let user = try await TwitterAPI.shared.getUser(screenName: "tesla")
        // 多取几页，视频不一定在第一页
        var videos: [TwitterMedia] = []
        var cursor: String?
        for _ in 0..<3 {
            let page = try await TwitterAPI.shared.getUserMedias(userId: user.id, cursor: cursor, count: 20)
            videos = page.posts.flatMap { $0.medias ?? [] }.filter { $0.type == .video }
            if !videos.isEmpty { break }
            cursor = page.cursor
            if cursor == nil { break }
        }
        let video = try XCTUnwrap(videos.first, "取不到任何视频（这条测试需要一条）")

        // 1) 封面：必须是图片地址，且**不等于**可播放地址
        let poster = try XCTUnwrap(video.url, "视频缺封面 URL（TwitterMedia.url 为空）")
        XCTAssertFalse(poster.contains(".mp4"),
                       "封面被填成了 mp4：\(poster)。界面会把它当图片解码 → 视频格子空白")
        XCTAssertTrue(poster.contains("twimg.com"), "封面不像 CDN 地址：\(poster)")

        // 2) 封面真的能当图片解码（这条是最接近"用户看到画面"的断言）
        let thumb = try XCTUnwrap(ReplyMediaThumb.thumbnailURL(for: video), "生成缩略图 URL 失败")
        let image = await ImageCache.shared.image(for: thumb, category: .mediaThumbnails, maxPixelSize: 600)
        XCTAssertNotNil(image, "封面解码失败（界面会显示空白）：\(thumb)")

        // 3) 可播放地址：来自 variants，且是 mp4
        let playable = try XCTUnwrap(MediaViewerView.bestVideoURL(video), "拿不到可播放地址（variants 丢了？）")
        XCTAssertTrue(playable.absoluteString.contains(".mp4"), "可播放地址不是 mp4：\(playable)")
        XCTAssertNotEqual(playable.absoluteString, poster, "封面与播放地址不该是同一个")
    }

    /// **真正跑一遍创建任务循环**（`CreationTaskStore.runCreationTask`）。
    ///
    /// 这条循环整段是新写的（翻页交给 `crawl.run`，外壳只做"分块 + 选择集 + 进度"），
    /// 别的地方测不到它：离线进不了网，而 `crawlPage` 那条只验了两个前提假设。
    ///
    /// 两个关键手法：
    /// - **窗口取一条真实推文的日期**（先取一页拿到 `createdAt`），这样那一天必然有内容，
    ///   于是这条路能真的走完"候选 → 回连完整推文 → 建下载任务"；
    /// - 落盘目录换成临时目录、跑完删掉，同一个测试里的媒体顺手取消掉——
    ///   不碰用户真实的下载目录与「跳过已下载」开关（先存后改、改完还原）。
    @MainActor
    func testCreationTaskLoopRunsEndToEnd() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")
        let cookie = storedCookie
        try XCTSkipIf(cookie.isEmpty, "应用里还没有 cookie")
        let proxy = await MainActor.run { SettingsStore.shared.settings.proxy }
        await TwitterAPI.shared.configure(cookie: cookie, proxy: proxy)

        let originalSaveDir = SettingsStore.shared.settings.download.saveDirBase
        let originalSkip = SettingsStore.shared.settings.download.sameFileSkip
        let outDir = NSTemporaryDirectory() + "xspider-live-crawl-\(UUID().uuidString)"
        SettingsStore.shared.settings.download.saveDirBase = outDir
        SettingsStore.shared.settings.download.sameFileSkip = false
        defer {
            SettingsStore.shared.settings.download.saveDirBase = originalSaveDir
            SettingsStore.shared.settings.download.sameFileSkip = originalSkip
            try? FileManager.default.removeItem(atPath: outDir)
        }

        let user = try await TwitterAPI.shared.getUser(screenName: "tesla")
        // 拿一条真实推文的日期当窗口 → 这一天必定有内容，循环不会空转
        let page = try await TwitterAPI.shared.getUserMedias(userId: user.id, count: 10)
        let reference = try XCTUnwrap(page.posts.compactMap(\.createdAt).max(),
                                      "需要一条带时间的推文来确定窗口")
        let day = Calendar.current.startOfDay(for: reference)
        let filter = DownloadFilter(dateRange: .init(start: day, end: day),
                                    mediaTypes: [.photo, .video, .gif],
                                    source: .medias)

        // 临时目录里已经有的任务先清掉，好让"这次新建了哪些"可判定
        let before = Set(DownloadStore.shared.tasks.map(\.gid))

        let store = CreationTaskStore()
        store.createCreationTask(user: user, filter: filter)
        let task = try XCTUnwrap(store.creationTasks.first, "任务没入队")

        // 循环在串行调度器里跑，等它把任务从队列里摘掉
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, store.creationTasks.contains(where: { $0.id == task.id }) {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertFalse(store.creationTasks.contains(where: { $0.id == task.id }),
                       "创建任务应当在超时前结束（循环卡住就是这条红）")

        // **候选真的变成了下载任务**：这正是"候选（有损）→ posts（完整）→ 建任务"那条链路
        let created = DownloadStore.shared.tasks.filter { !before.contains($0.gid) }
        XCTAssertFalse(created.isEmpty,
                       "这一天有媒体，循环应当至少建出一个下载任务（窗口=\(day)）")
        for download in created {
            XCTAssertTrue(download.dir.hasPrefix(outDir),
                          "任务落盘目录应当是我们给的临时目录，实际：\(download.dir)")
            AppLogger.info("live 创建任务产出", category: "DL", [
                "file": download.fileName, "type": download.media.type.rawValue,
            ])
        }

        // 收尾：把这些任务取消掉（清临时文件），不留半成品
        for download in created { DownloadStore.shared.remove(download.gid, alsoDeleteFiles: true) }
    }

    /// **下载路径的真实链路**：应用建任务 → 组件搬字节 → 应用验内容与记录。
    ///
    /// 这条是下载迁移的验收：`DownloadStore.launch` 现在只做"算好目录与文件名 → `dl.enqueue`"，
    /// 字节、断点、并发都由组件负责；应用仍然自己做内容校验（魔数/HTML 误页）与下载记录。
    @MainActor
    func testDownloadThroughTheStoreAndComponent() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")
        let cookie = storedCookie
        try XCTSkipIf(cookie.isEmpty, "应用里还没有 cookie")

        let proxy = await MainActor.run { SettingsStore.shared.settings.proxy }
        await TwitterAPI.shared.configure(cookie: cookie, proxy: proxy)

        // 落到临时目录，别碰用户自己的下载文件夹。
        //
        // **必须先存后改、改完还原**：这些设置是持久化的（`settings.v2`），
        // 直接改会把用户真实的下载目录与「跳过已下载」开关一起带歪——
        // 我第一次跑这条测试就干了这事（用户真实目录是 ~/Pictures/photo，
        // 被改成 /var/folders/…/xspider-live-<uuid>，而那目录随后被删了）。
        let originalSaveDir = SettingsStore.shared.settings.download.saveDirBase
        let originalSkip = SettingsStore.shared.settings.download.sameFileSkip
        let outDir = NSTemporaryDirectory() + "xspider-live-\(UUID().uuidString)"
        SettingsStore.shared.settings.download.saveDirBase = outDir
        SettingsStore.shared.settings.download.sameFileSkip = false
        defer {
            SettingsStore.shared.settings.download.saveDirBase = originalSaveDir
            SettingsStore.shared.settings.download.sameFileSkip = originalSkip
            try? FileManager.default.removeItem(atPath: outDir)
        }

        // 挑一个**小**媒体（省配额与时间）：优先图片
        let user = try await TwitterAPI.shared.getUser(screenName: "tesla")
        let page = try await TwitterAPI.shared.getUserMedias(userId: user.id, count: 10)
        let pairs = page.posts.compactMap { post -> (TwitterPost, TwitterMedia)? in
            guard let media = (post.medias ?? []).first else { return nil }
            return (post, media)
        }
        let (post, media) = try XCTUnwrap(pairs.min { lhs, rhs in
            (lhs.1.type == .photo ? 0 : 1, lhs.1.width ?? 0) < (rhs.1.type == .photo ? 0 : 1, rhs.1.width ?? 0)
        }, "需要至少一条带媒体的推文")

        let created = await DownloadStore.shared.createDownloadTask(post: post, media: media)
        let task = try XCTUnwrap(created, "建任务失败（可能是重复判定）")
        XCTAssertEqual(task.status, .waiting, "建完任务应当排队等组件")

        DownloadStore.shared.start(task)

        let deadline = Date().addingTimeInterval(120)
        var finalTask = task
        while Date() < deadline {
            if let current = DownloadStore.shared.tasks.first(where: { $0.gid == task.gid }),
               current.status == .complete || current.status == .error {
                finalTask = current
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        XCTAssertEqual(finalTask.status, .complete,
                       "下载没成功：\(finalTask.error ?? "无错误信息")")
        let path = (finalTask.dir as NSString).appendingPathComponent(finalTask.fileName)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
        XCTAssertNotNil(size, "文件没落盘：\(path)")
        XCTAssertEqual(size, finalTask.completeSize, "落盘字节数要与任务状态一致")
        XCTAssertGreaterThan(size ?? 0, 0, "0 字节不能算成功")
    }

    /// 新的创建任务爬取路径：`crawl.run` **分块**跑，候选要能回连到完整推文。
    ///
    /// 离线测不了这条循环（要真网络），而它整段是新写的，所以这里验两个**假设**：
    /// 1. 候选能凭 `post_id`/`media_id` 在 `posts` 里找到完整推文（否则命名与记账拿不到正文）；
    /// 2. `max_pages` 生效——本块跑满时 `done_reason == page_limit_reached` 且给了 `next_cursor`，
    ///    拿它续跑能拿到**不同的**内容（说明真在翻页，不是原地打转）。
    ///
    /// **不建下载任务**：那会往用户的下载目录写真实文件，live 测试不该有那种副作用。
    func testCrawlPagesJoinBackToFullPosts() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")
        let cookie = storedCookie
        try XCTSkipIf(cookie.isEmpty, "应用里还没有 cookie")
        let proxy = await MainActor.run { SettingsStore.shared.settings.proxy }
        await TwitterAPI.shared.configure(cookie: cookie, proxy: proxy)

        // 用 tesla（fixture 与 canary 都用它，媒体量稳定）
        let user = try await TwitterAPI.shared.getUser(screenName: "tesla")
        // 只跑一页一块：这条测的是"分块与回连"，不是爬多少内容
        let strategy: [String: JSONValue] = [
            "limits": .object(["page_size": .int(20), "page_throttle_ms": .int(200),
                               "max_pages": .int(1)]),
        ]

        let first = try await TwitterAPI.shared.crawlPage(
            source: .medias, userId: user.id, cursor: nil, strategy: strategy)
        let candidates = (first[array: "candidates"] ?? []).compactMap { $0.asObject }
        let posts = (first[array: "posts"] ?? []).compactMap { $0.asObject }
        XCTAssertFalse(candidates.isEmpty, "这一页应当有媒体候选")

        // ① 候选 → 完整推文 → 那个媒体：这正是 runCreationTask 里做的连接
        var postsById: [String: TwitterPost] = [:]
        var postsWithText = 0
        for json in posts {
            let post = try XCTUnwrap(XSpiderMapping.post(json), "posts 里的推文必须能解析")
            postsById[post.id] = post
            // `fullText` 是契约的必填字段：**键必须在**。
            // 但不能要求它非空——纯媒体、无文字的推文，`full_text` 本来就是 ""。
            XCTAssertNotNil(post.fullText, "正文这个键必须在（候选里完全没有）")
            if !(post.fullText ?? "").isEmpty { postsWithText += 1 }
        }
        XCTAssertGreaterThan(postsWithText, 0,
                             "这一页至少要有一条带文字的推文，否则说明 posts 根本没带出正文")
        for candidate in candidates {
            let postId = try XCTUnwrap(candidate[string: "post_id"])
            let mediaId = try XCTUnwrap(candidate[string: "media_id"])
            let post = try XCTUnwrap(postsById[postId], "候选的推文必须在 posts 里：\(postId)")
            let media = try XCTUnwrap(post.medias?.first { $0.id == mediaId },
                                      "候选的媒体必须在推文里：\(mediaId)")
            XCTAssertNotNil(downloadURL(for: media), "回连到的媒体要能算出下载地址")
        }

        // ② 分块：本块跑满 → 有 done_reason 与 next_cursor，续跑要拿到新内容
        XCTAssertEqual(first[string: "done_reason"], "page_limit_reached",
                       "max_pages=1 时应当报「本块跑满」")
        let cursor = try XCTUnwrap(first[string: "next_cursor"], "跑满了就必须给续爬游标")

        let second = try await TwitterAPI.shared.crawlPage(
            source: .medias, userId: user.id, cursor: cursor, strategy: strategy)
        let secondKeys = Set((second[array: "candidates"] ?? []).compactMap { $0.asObject }
            .compactMap { $0[string: "key"] })
        let firstKeys = Set(candidates.compactMap { $0[string: "key"] })
        XCTAssertFalse(secondKeys.isEmpty, "续爬也应当有候选")
        XCTAssertTrue(secondKeys.isDisjoint(with: firstKeys),
                      "续爬必须拿到**不同的**媒体，否则就是原地打转")
    }

    /// 取一页媒体时间线：这条同时验证**分页形状**与**媒体映射**
    /// （`medias[].url` / `ext` / `kind` 能不能落进 `TwitterMedia`）。
    func testFetchUserMediasThroughTheAppPath() async throws {
        try XCTSkipUnless(isLive, "live 测试：设 XSPIDER_LIVE=1 才跑")
        let cookie = storedCookie
        try XCTSkipIf(cookie.isEmpty, "应用里还没有 cookie，先在设置里导入一次")

        let proxy = await MainActor.run { SettingsStore.shared.settings.proxy }
        await TwitterAPI.shared.configure(cookie: cookie, proxy: proxy)

        let user = try await TwitterAPI.shared.getUser(screenName: "tesla")
        let page = try await TwitterAPI.shared.getUserMedias(userId: user.id, count: 10)

        XCTAssertFalse(page.posts.isEmpty, "应当取到推文")
        let withMedia = page.posts.filter { !($0.medias ?? []).isEmpty }
        XCTAssertFalse(withMedia.isEmpty, "媒体时间线里应当有带媒体的推文")
        let media = try XCTUnwrap(withMedia.first?.medias?.first)
        XCTAssertNotNil(media.url, "媒体的下载 URL 不能丢")
        XCTAssertFalse(media.url?.isEmpty ?? true)
        XCTAssertNotNil(media.createdTime, "媒体要带上推文时间（记录文件锚定用）")
        XCTAssertNotNil(withMedia.first?.user.screenName, "作者要映射出来")
    }
}
