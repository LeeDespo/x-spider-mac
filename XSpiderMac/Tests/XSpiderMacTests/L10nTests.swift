import XCTest
@testable import XSpiderMac

final class L10nTests: XCTestCase {
    func testLanguageSwitchDoesNotCrash() {
        for lang in Settings.Language.allCases {
            L10n.language = lang
            _ = L("主页")
            _ = L("搜索")
        }
        L10n.language = .zhHans
    }
}
