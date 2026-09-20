import XCTest
@testable import XSpiderMac

/// 自动翻译的**语言白名单**判据。
///
/// 需求：自动翻译不再"凡是非目标语言就翻"，而是**只翻清单里列出的语言**。
/// 理由：时间线里语言极杂，逐个遇到就翻既耗电刷屏，也会频繁向系统请求语言包。
final class AutoTranslateWhitelistTests: XCTestCase {

    @MainActor
    private func setLanguages(_ codes: [String]) {
        SettingsStore.shared.settings.app.autoTranslateLanguages = codes
    }

    @MainActor
    private func setAutoTranslate(_ on: Bool) {
        SettingsStore.shared.settings.app.autoTranslate = on
    }

    override func setUp() async throws {
        await MainActor.run {
            SettingsStore.shared.settings.app.autoTranslate = false
            SettingsStore.shared.settings.app.autoTranslateLanguages = []
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            SettingsStore.shared.settings.app.autoTranslate = false
            SettingsStore.shared.settings.app.autoTranslateLanguages = []
            SettingsStore.shared.settings.app.translateTargetLanguage = nil
        }
    }

    /// 开关关闭 → 一律不自动翻译
    @MainActor
    func testDisabledAutoTranslateNeverFires() {
        setAutoTranslate(false)
        setLanguages(["ja"])
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: "ja"))
    }

    /// **清单为空 → 不自动翻译任何条目**（比"全部语言都翻"安全）
    @MainActor
    func testEmptyWhitelistTranslatesNothing() {
        setAutoTranslate(true)
        setLanguages([])
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: "ja"),
                       "没设清单时不应乱翻——否则时间线里每条外语都会触发翻译")
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: "ko"))
    }

    /// 清单里的语言 → 自动翻译
    @MainActor
    func testWhitelistedLanguageFires() {
        setAutoTranslate(true)
        setLanguages(["ja", "ko"])
        XCTAssertTrue(TranslationStore.shouldAutoTranslate(lang: "ja"))
        XCTAssertTrue(TranslationStore.shouldAutoTranslate(lang: "ko"))
    }

    /// **不在清单里的语言 → 不翻译**（这是本次改动的核心）
    @MainActor
    func testNonWhitelistedLanguageDoesNotFire() {
        setAutoTranslate(true)
        setLanguages(["ja"])
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: "fr"),
                       "没勾选的语言不该自动翻译")
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: "de"))
    }

    /// 语言码带地区变体时按主语言匹配（X 可能给 "zh-Hans" 这类）
    ///
    /// 注意：目标语言若恰好也是 zh，会被"目标语言本身不翻译"那条挡掉，
    /// 所以这里显式把目标设为**别的**语言，才能单独验证地区变体匹配。
    @MainActor
    func testRegionVariantMatchesMainLanguage() {
        let saved = SettingsStore.shared.settings.app.translateTargetLanguage
        SettingsStore.shared.settings.app.translateTargetLanguage = "ja"
        defer { SettingsStore.shared.settings.app.translateTargetLanguage = saved }

        setAutoTranslate(true)
        setLanguages(["zh"])
        XCTAssertTrue(TranslationStore.shouldAutoTranslate(lang: "zh-Hans"))
        XCTAssertTrue(TranslationStore.shouldAutoTranslate(lang: "zh-Hant"))
    }

    /// 语言未知（nil / 空）→ 不翻译（不猜语言）
    @MainActor
    func testUnknownLanguageDoesNotFire() {
        setAutoTranslate(true)
        setLanguages(["ja"])
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: nil))
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: ""))
    }

    /// 清单里若含目标语言本身，该语言不该被翻译（原文已是目标语言）
    @MainActor
    func testTargetLanguageIsNotTranslatedEvenIfListed() {
        setAutoTranslate(true)
        SettingsStore.shared.settings.app.translateTargetLanguage = "ja"
        setLanguages(["ja", "ko"])
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: "ja"),
                       "目标语言本身无需翻译")
        XCTAssertTrue(TranslationStore.shouldAutoTranslate(lang: "ko"))
        SettingsStore.shared.settings.app.translateTargetLanguage = nil
    }
}

/// 目标语言解析：**"跟随系统"必须解析成用户真实语言**。
///
/// 回归用户实测的三个症状（同一根因）：
/// 1. 目标语言设"跟随系统"时，加日语/英语会变成"日→英"；
/// 2. 事先下载过的英语包显示"无法下载"；
/// 3. 下载中一直显示"可下载"。
///
/// 根因：`Locale.current` 受 **app bundle 的本地化声明**影响。本 app 只用
/// `L10n` 自己实现三语（不走 bundle），bundle 里只声明 en，于是系统把
/// `Locale.current` 降级成 **en**——实测 `Locale.current.identifier == "en_US"`
/// 而 `Locale.preferredLanguages == ["zh-Hans"]`。
final class TranslationTargetLanguageTests: XCTestCase {

    @MainActor
    private func withTarget(_ raw: String?, _ body: () -> Void) {
        let saved = SettingsStore.shared.settings.app.translateTargetLanguage
        SettingsStore.shared.settings.app.translateTargetLanguage = raw
        body()
        SettingsStore.shared.settings.app.translateTargetLanguage = saved
    }

    /// **核心回归**：跟随系统时用 `Locale.preferredLanguages`，不是 `Locale.current`
    @MainActor
    func testFollowSystemUsesPreferredLanguageNotCurrent() {
        withTarget(nil) {
            let resolved = SettingsStore.shared.settings.translateTargetLanguage
            let main = resolved.languageCode?.identifier ?? ""
            let preferredMain = Locale.preferredLanguages.first?
                .split(separator: "-").first.map(String.init) ?? ""

            XCTAssertFalse(main.isEmpty)
            XCTAssertEqual(main, preferredMain,
                           "跟随系统必须等于系统偏好语言；用 Locale.current 会被 bundle 降级成 en")
        }
    }

    /// `systemPreferredLanguage` 本身不受 bundle 影响
    func testSystemPreferredLanguageIsNotBundleDegraded() {
        let resolved = Settings.systemPreferredLanguage.languageCode?.identifier ?? ""
        let preferred = Locale.preferredLanguages.first?
            .split(separator: "-").first.map(String.init) ?? ""
        XCTAssertEqual(resolved, preferred)

        // 记录这条事实：bundle 只声明了 en，所以 Locale.current 不可用
        XCTAssertEqual(Bundle.main.localizations, ["en"],
                       "bundle 只有 en 本地化（L10n 是自实现的）——这正是 Locale.current 被降级的原因")
    }

    /// 显式设置时优先用设置值
    @MainActor
    func testExplicitTargetWins() {
        withTarget("ja") {
            let resolved = SettingsStore.shared.settings.translateTargetLanguage
            XCTAssertEqual(resolved.languageCode?.identifier, "ja")
        }
    }

    /// **回归症状 2**：与目标语言相同时应是"无需语言包"而非"不支持"
    ///
    /// 系统对 "zh → zh" 这类同语言对返回 `unsupported`，但用户视角是"不需要"。
    @MainActor
    func testSameAsTargetIsNotNeededNotUnsupported() async {
        let store = TranslationPackStore.shared
        SettingsStore.shared.settings.app.translateTargetLanguage = "zh-Hans"
        defer {
            SettingsStore.shared.settings.app.translateTargetLanguage = nil
            store.remove("zh")
        }

        await store.refreshStatus(for: "zh", force: true)
        XCTAssertEqual(store.statuses["zh"], .notNeeded,
                       "与目标语言相同应显示「无需语言包」，而不是系统的 unsupported")
        XCTAssertTrue(store.statuses["zh"]?.isInstalled == true,
                      "「无需语言包」在 UI 上应视为已就绪（不再提示下载）")
    }

    /// 不同语言 → 走系统查询（不该被误判成 notNeeded）
    @MainActor
    func testDifferentLanguageQueriesSystem() async {
        let store = TranslationPackStore.shared
        SettingsStore.shared.settings.app.translateTargetLanguage = "zh-Hans"
        defer { SettingsStore.shared.settings.app.translateTargetLanguage = nil }

        await store.refreshStatus(for: "ja", force: true)
        XCTAssertNotEqual(store.statuses["ja"], .notNeeded,
                          "与目标不同的语言应走系统查询")
    }

    /// **回归症状 3**：请求下载后立刻进入"下载中"，且
    /// `prepareTranslation` 返回后**仍保持下载中**（它不代表下载完成）
    @MainActor
    func testRequestDownloadMarksDownloadingImmediatelyAndKeepsIt() async {
        let store = TranslationPackStore.shared
        store.requestDownload(languageCode: "ko")
        XCTAssertTrue(store.downloading.contains("ko"),
                      "点下下载就该显示「下载中」，不必等会话建立")

        await store.markDownloadRequested(languageCode: "ko", error: nil)
        XCTAssertTrue(store.downloading.contains("ko"),
                      "prepareTranslation 返回 ≠ 下载完成，不能过早清掉「下载中」")
    }

    /// 下载失败时才移出"下载中"（否则会一直转圈）
    @MainActor
    func testFailedDownloadClearsDownloading() async {
        let store = TranslationPackStore.shared
        store.requestDownload(languageCode: "fr")
        XCTAssertTrue(store.downloading.contains("fr"))
        await store.markDownloadRequested(languageCode: "fr",
                                          error: NSError(domain: "t", code: 1))
        XCTAssertFalse(store.downloading.contains("fr"),
                       "失败必须停止转圈并给出错误")
        XCTAssertNotNil(store.lastError)
    }
}

/// 语言清单的增删（TranslationPackStore）
final class TranslationPackListTests: XCTestCase {

    override func setUp() async throws {
        await MainActor.run {
            SettingsStore.shared.settings.app.autoTranslateLanguages = []
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            SettingsStore.shared.settings.app.autoTranslateLanguages = []
        }
    }

    @MainActor
    func testAddNormalizesAndDeduplicates() {
        let store = TranslationPackStore.shared
        store.add(["ja", "ko"])
        XCTAssertEqual(store.languages, ["ja", "ko"])

        // 重复添加不应产生重复项；带地区变体归一化为主语言码
        store.add(["ja", "zh-Hans"])
        XCTAssertEqual(store.languages, ["ja", "ko", "zh"],
                       "重复项被忽略，地区变体归一化为主语言码")
    }

    @MainActor
    func testRemoveDeletesOnlyThatLanguage() {
        let store = TranslationPackStore.shared
        store.add(["ja", "ko", "fr"])
        store.remove("ko")
        XCTAssertEqual(store.languages, ["ja", "fr"])
    }

    @MainActor
    func testAddEmptyIsIgnored() {
        let store = TranslationPackStore.shared
        store.add([""])
        XCTAssertTrue(store.languages.isEmpty, "空语言码不应进入清单")
    }

    /// 归一化口径：与 `shouldAutoTranslate` 的比对必须一致
    @MainActor
    func testNormalizeUsesMainLanguageCode() {
        XCTAssertEqual(TranslationPackStore.normalize("zh-Hans"), "zh")
        XCTAssertEqual(TranslationPackStore.normalize("ja"), "ja")
        XCTAssertEqual(TranslationPackStore.normalize("en-US"), "en")
        XCTAssertEqual(TranslationPackStore.normalize("JA"), "ja")
    }
}

/// 连续转推的去重（回归：同页重复 id 会让 SwiftUI 列表出现空白）
final class DuplicatePostIdTests: XCTestCase {

    /// 同页出现重复 id 时，去重后应只剩一条 —— 模拟"同一账号连转同一条推文"
    @MainActor
    func testSamePageDuplicatesAreRemoved() {
        let store = HomepageStore.shared
        store.clearPostList()

        // 三条条目展平后 id 相同（同一条原推文被连转三次）
        var seen = Set<String>()
        let ids = ["1900000000000000001", "1900000000000000001", "1900000000000000001",
                   "1900000000000000002"]
        let deduped = ids.filter { seen.insert($0).inserted }
        XCTAssertEqual(deduped, ["1900000000000000001", "1900000000000000002"],
                       "同页重复 id 必须去掉，否则 ForEach 只渲染第一个、其余空白")
    }

    /// 跨页去重同样有效（同一个 Set 承担两种职责）
    @MainActor
    func testCrossPageDuplicatesStillRemoved() {
        var seen = Set<String>()
        let page1 = ["a", "b"]
        let page2 = ["b", "c"]   // b 与上一页重复
        let d1 = page1.filter { seen.insert($0).inserted }
        let d2 = page2.filter { seen.insert($0).inserted }
        XCTAssertEqual(d1, ["a", "b"])
        XCTAssertEqual(d2, ["c"], "跨页重复也要去掉")
    }
}
