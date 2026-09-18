import Foundation

struct TwitterPost: Codable, Sendable {
    let id: String
    let user: TwitterUser
    let createdAt: Date?
    let fullText: String?
    let tags: [String]?
    let views: Int?
    let lang: String?
    let retweeted: Bool?
    let retweetCount: Int?
    let replyCount: Int?
    let possiblySensitive: Bool?
    let favorited: Bool?
    let favoriteCount: Int?
    let bookmarkCount: Int?
    let bookmarked: Bool?
    let medias: [TwitterMedia]?

    /// 被引用的推文（引用推文时非 nil）。
    ///
    /// **为什么是 `QuotedPostBox` 而不是 `TwitterPost?`**：`TwitterPost` 是 struct，
    /// 而 Swift **禁止值类型递归包含自身**（`Optional<T>` 仍是存储属性，编译期即报
    /// "cannot have a stored property that recursively contains it"）。
    /// 泛型 struct 包装也无效——泛型实例仍是值类型。
    /// 必须用**引用类型**打断：`QuotedPostBox` 是 `final class`，
    /// `TwitterPost` 存的是它的引用，递归在类型层面被断开。
    ///
    /// 只递归**一层**：X 不允许"引用里再引用"，解析时内层显式禁止再向下取
    /// （`TwitterAPI.mapTwitterPost(_:includeQuoted:)`），防异常数据无限递归。
    var quotedPost: QuotedPostBox?

    /// 转发者：转推时非 nil。此时 `user` 是**原作者**（被转发的推文），
    /// 本字段记录"由谁转推"，用于卡片顶部的「某某 转推」标签。
    var retweetedBy: TwitterUser?

    /// 显式成员初始化器：`quotedPost` / `retweetedBy` 带默认值，
    /// 既有调用方（解析、测试）无需改动。
    init(id: String, user: TwitterUser, createdAt: Date?, fullText: String?,
         tags: [String]?, views: Int?, lang: String?, retweeted: Bool?,
         retweetCount: Int?, replyCount: Int?, possiblySensitive: Bool?,
         favorited: Bool?, favoriteCount: Int?, bookmarkCount: Int?,
         bookmarked: Bool?, medias: [TwitterMedia]?,
         quotedPost: QuotedPostBox? = nil, retweetedBy: TwitterUser? = nil) {
        self.id = id
        self.user = user
        self.createdAt = createdAt
        self.fullText = fullText
        self.tags = tags
        self.views = views
        self.lang = lang
        self.retweeted = retweeted
        self.retweetCount = retweetCount
        self.replyCount = replyCount
        self.possiblySensitive = possiblySensitive
        self.favorited = favorited
        self.favoriteCount = favoriteCount
        self.bookmarkCount = bookmarkCount
        self.bookmarked = bookmarked
        self.medias = medias
        self.quotedPost = quotedPost
        self.retweetedBy = retweetedBy
    }
}

/// 引用推文的包装盒：用**引用类型**打断值类型的递归包含。
///
/// `TwitterPost` 是 struct，不能直接持有 `TwitterPost?`（编译期报错，见字段注释）；
/// 泛型 struct 包装同样无效。`final class` 是引用类型，`TwitterPost` 存其引用，
/// 递归在类型层面被断开。
///
/// `Codable` **透明转发**：编码时直接输出内部值，解码时直接读入，
/// 因此 JSON 形态仍是普通嵌套对象（`"quotedPost": { … }`），
/// 不引入额外包装层，也不影响既有历史记录的解码。
/// `@unchecked Sendable`：内部仅在构造时写入，之后只读，无并发写入。
final class QuotedPostBox: Codable, @unchecked Sendable {
    let value: TwitterPost
    init(_ value: TwitterPost) { self.value = value }

    init(from decoder: Decoder) throws {
        value = try TwitterPost(from: decoder)
    }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

extension QuotedPostBox: Equatable {
    static func == (lhs: QuotedPostBox, rhs: QuotedPostBox) -> Bool {
        lhs === rhs
    }
}
