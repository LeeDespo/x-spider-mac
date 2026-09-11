import Foundation
import SwiftUI

/// 上游 stores/app-state.ts（zustand persist → UserDefaults）
@Observable
@MainActor
final class AppStore {
    static let shared = AppStore()

    var cookieString: String = "" {
        didSet {
            UserDefaults.standard.set(cookieString, forKey: "app.cookieString")
            Task { await TwitterAPI.shared.configure(cookie: cookieString, proxy: SettingsStore.shared.settings.proxy) }
        }
    }

    var searchHistory: [String] = [] {
        didSet { UserDefaults.standard.set(searchHistory, forKey: "app.searchHistory") }
    }

    /// 当前登录账户（由 getAccountInfo 验证后填充）
    var account: TwitterAccountInfo? {
        didSet {
            if let data = try? JSONEncoder().encode(account) {
                UserDefaults.standard.set(data, forKey: "app.account")
            }
        }
    }

    var systemProxyUrl: String = "" {
        didSet { UserDefaults.standard.set(systemProxyUrl, forKey: "app.systemProxyUrl") }
    }

    init() {
        cookieString = UserDefaults.standard.string(forKey: "app.cookieString") ?? ""
        searchHistory = UserDefaults.standard.stringArray(forKey: "app.searchHistory") ?? []
        if let data = UserDefaults.standard.data(forKey: "app.account"),
           let decoded = try? JSONDecoder().decode(TwitterAccountInfo.self, from: data) {
            account = decoded
        }
        systemProxyUrl = UserDefaults.standard.string(forKey: "app.systemProxyUrl") ?? ""
    }

    // MARK: - 搜索历史（上游 addSearchHistory：小写化、去重、最新在前）

    func addSearchHistory(_ keyword: String) {
        let lowered = keyword.lowercased()
        var history = searchHistory
        history.removeAll { $0 == lowered }
        history.insert(lowered, at: 0)
        searchHistory = history
    }

    func clearSearchHistory() { searchHistory = [] }

    // MARK: - Cookie 登录（上游 Account.tsx handleSubmit：验证 + 更新账户卡）

    /// 用完整 cookie 字符串登录：调 getAccountInfo 验证，成功则保存并返回账户信息。
    func login(cookieString: String) async throws -> TwitterAccountInfo {
        let info = try await TwitterAPI.shared.getAccountInfo(cookieStringOverride: cookieString)
        self.cookieString = cookieString
        self.account = info
        return info
    }

    /// 登出（上游 handleLogout：清 cookie + 账户信息）
    func logout() {
        cookieString = ""
        account = nil
    }

    /// 启动时恢复：如果已有 cookie，静默重新验证（上游 App.tsx useMount 行为）
    func restoreSession() async {
        guard !cookieString.isEmpty else { return }
        do {
            _ = try await login(cookieString: cookieString)
        } catch {
            NSLog("Session restore failed: \(error.localizedDescription)")
            // 保留 cookie 让用户手动重试，不清空（与上游一致）
        }
    }
}
