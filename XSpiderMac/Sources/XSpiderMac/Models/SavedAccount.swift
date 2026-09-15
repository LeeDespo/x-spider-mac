import Foundation

/// 已登录过的账户（cookie 保留,支持快速切换）
struct SavedAccount: Codable, Sendable, Identifiable {
    let screenName: String
    let avatar: String
    let cookie: String

    var id: String { screenName }
}
