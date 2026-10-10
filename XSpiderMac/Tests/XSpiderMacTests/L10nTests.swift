import XCTest
@testable import XSpiderMac

/// 本地化表解析：以简体中文为 key，切换语言后应命中对应译文；
/// 表里没有的 key 原样回落（保持简体兜底）。
final class L10nTests: XCTestCase {

    override func tearDown() {
        L10n.language = .zhHans
    }

    /// 简中即 key（表为空、原样返回），英 / 繁必须给出**不同**的译文——
    /// 若某条 key 漏进译文表，这里就会红（曾出现调用方用错 key、
    /// 英文界面回落到中文的情况）。
    func testKnownKeysResolvePerLanguage() {
        L10n.language = .zhHans
        XCTAssertEqual(L("主页"), "主页", "简中以 key 兜底")

        L10n.language = .en
        let en = L("主页")
        XCTAssertNotEqual(en, "主页", "英文必须命中译文，实际：\(en)")
        XCTAssertFalse(en.isEmpty)

        L10n.language = .zhHant
        let hant = L("主页")
        XCTAssertNotEqual(hant, "主页", "繁体必须命中译文，实际：\(hant)")
    }

    /// 表里没有的 key 原样返回，不崩、不返回空。
    func testUnknownKeyFallsBackToItself() {
        for lang in Settings.Language.allCases {
            L10n.language = lang
            XCTAssertEqual(L("这条 key 不存在"), "这条 key 不存在")
        }
    }

    /// 切换全部语言并取一批 key，不应崩溃。
    func testLanguageSwitchDoesNotCrash() {
        for lang in Settings.Language.allCases {
            L10n.language = lang
            XCTAssertFalse(L("主页").isEmpty)
            XCTAssertFalse(L("搜索").isEmpty)
        }
    }
}
