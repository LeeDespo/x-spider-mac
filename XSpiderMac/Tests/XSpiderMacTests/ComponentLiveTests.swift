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
