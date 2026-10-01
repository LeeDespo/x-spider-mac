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

        // 落到临时目录，别碰用户自己的下载文件夹
        let outDir = NSTemporaryDirectory() + "xspider-live-\(UUID().uuidString)"
        SettingsStore.shared.settings.download.saveDirBase = outDir
        SettingsStore.shared.settings.download.sameFileSkip = false
        defer { try? FileManager.default.removeItem(atPath: outDir) }

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
