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
            XCTAssertEqual(error.code, "upstream", "实际：\(error)")
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
