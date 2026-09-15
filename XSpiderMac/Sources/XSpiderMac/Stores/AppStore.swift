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

    var searchHistory: [SearchHistoryItem] = [] {
        didSet { persistSearchHistory() }
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
        searchHistory = Self.loadSearchHistory()
        if let data = UserDefaults.standard.data(forKey: "app.account"),
           let decoded = try? JSONDecoder().decode(TwitterAccountInfo.self, from: data) {
            account = decoded
        }
        systemProxyUrl = UserDefaults.standard.string(forKey: "app.systemProxyUrl") ?? ""
    }

    // MARK: - 搜索历史（用户 / 推文两类；最新在前，去重）

    func addSearchHistory(_ keyword: String, displayName: String? = nil, avatarURL: String? = nil) {
        // 隐私开关：自动清空搜索记录后，本次搜索只保留当前项
        if SettingsStore.shared.settings.autoClearSearchHistoryEnabled && !searchHistory.isEmpty {
            searchHistory = []
        }
        let lowered = keyword.lowercased()
        var history = searchHistory
        history.removeAll { $0.keyword == lowered }
        history.insert(SearchHistoryItem(
            keyword: lowered, kind: .user,
            displayName: displayName, imageURL: avatarURL
        ), at: 0)
        searchHistory = history
    }

    /// 推文搜索历史：带推文 id、作者名、缩略图（多图堆叠用 thumbnailURLs）
    func addTweetSearchHistory(tweetID: String, authorName: String, authorScreenName: String, thumbnailURLs: [String]) {
        let kw = tweetID
        var history = searchHistory
        history.removeAll { $0.keyword == kw }
        history.insert(SearchHistoryItem(
            keyword: kw, kind: .tweet,
            displayName: authorScreenName.isEmpty ? nil : "\(authorName) @\(authorScreenName)",
            imageURL: thumbnailURLs.first, extraImageURLs: Array(thumbnailURLs.dropFirst().prefix(3))
        ), at: 0)
        searchHistory = history
    }

    func removeSearchHistory(keyword: String) {
        searchHistory.removeAll { $0.keyword == keyword }
    }

    func clearSearchHistory() { searchHistory = [] }

    /// 隐私开关：离开主页时清空搜索记录
    func clearSearchHistoryIfEnabled() {
        guard SettingsStore.shared.settings.autoClearSearchHistoryEnabled, !searchHistory.isEmpty else { return }
        searchHistory = []
        AppLogger.info("自动清空搜索记录", category: "APP")
    }

    private func persistSearchHistory() {
        if let data = try? JSONEncoder().encode(searchHistory) {
            UserDefaults.standard.set(data, forKey: "app.searchHistory.v2")
        }
    }

    private static func loadSearchHistory() -> [SearchHistoryItem] {
        if let data = UserDefaults.standard.data(forKey: "app.searchHistory.v2"),
           let items = try? JSONDecoder().decode([SearchHistoryItem].self, from: data) {
            return items
        }
        // 旧版纯字符串迁移
        let legacy = UserDefaults.standard.stringArray(forKey: "app.searchHistory") ?? []
        return legacy.map { SearchHistoryItem(keyword: $0, kind: .user, displayName: nil, imageURL: nil) }
    }

    // MARK: - Cookie 登录（上游 Account.tsx handleSubmit：验证 + 更新账户卡）

    /// 用完整 cookie 字符串登录：调 getAccountInfo 验证，成功则保存并返回账户信息。
    func login(cookieString: String) async throws -> TwitterAccountInfo {
        let info = try await TwitterAPI.shared.getAccountInfo(cookieStringOverride: cookieString)
        self.cookieString = cookieString
        self.account = info
        rememberCurrentAccount()
        return info
    }

    /// 登出（上游 handleLogout：清 cookie + 账户信息）
    func logout() {
        // 登出 = 销毁当前账户的 cookie(含已存列表中的该账户)
        if let sn = account?.screenName {
            savedAccounts.removeAll { $0.screenName == sn }
        }
        cookieString = ""
        account = nil
    }

    // MARK: - 多账户管理

    /// 已登录过的账户（cookie 保留,可随时切换;当前账户也在其中）
    var savedAccounts: [SavedAccount] {
        get {
            if let data = UserDefaults.standard.data(forKey: "app.savedAccounts"),
               let list = try? JSONDecoder().decode([SavedAccount].self, from: data) {
                return list
            }
            return []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "app.savedAccounts")
            }
        }
    }

    /// 登录成功后把当前账户加入已存列表（cookie 保存在当前 cookieString;多账户需各自保存 cookie）
    func rememberCurrentAccount() {
        guard let acc = account, !cookieString.isEmpty else { return }
        var list = savedAccounts.filter { $0.screenName != acc.screenName }
        list.insert(SavedAccount(screenName: acc.screenName, avatar: acc.avatar, cookie: cookieString), at: 0)
        savedAccounts = list
    }

    /// 切换到已存账户：恢复其 cookie 并验证
    func switchToAccount(_ target: SavedAccount) async throws {
        _ = try await login(cookieString: target.cookie)
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
