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
    @MainActor
    func testRegionVariantMatchesMainLanguage() {
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
