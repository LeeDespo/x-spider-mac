import Foundation

/// 搜索历史条目：用户搜索 / 推文搜索
struct SearchHistoryItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user
        case tweet
    }

    /// 用户搜索 = screen_name；推文搜索 = 推文 id
    var keyword: String
    var kind: Kind
    /// 推文搜索的显示名（"昵称 @user"）；用户搜索为 nil（直接显示 keyword）
    var displayName: String?
    /// 用户搜索 = 头像 URL；推文搜索 = 第一张媒体缩略图
    var imageURL: String?
    /// 推文多图的其余缩略图（最多 3 张，堆叠显示）
    var extraImageURLs: [String]?

    var id: String { "\(kind.rawValue)-\(keyword)" }
}
