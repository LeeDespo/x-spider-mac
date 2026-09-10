import Foundation
import SwiftUI

@Observable
@MainActor
final class AppStore {
    static let shared = AppStore()

    var cookieString: String = "" {
        didSet { save() }
    }
    var searchHistory: [String] = []
    var systemProxyUrl: String = ""

    private let storage = UserDefaults.standard

    init() {
        cookieString = storage.string(forKey: "app.cookieString") ?? ""
    }

    private func save() {
        storage.set(cookieString, forKey: "app.cookieString")
    }
}
