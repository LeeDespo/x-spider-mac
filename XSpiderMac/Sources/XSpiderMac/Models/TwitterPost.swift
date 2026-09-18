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

// MARK: - 评论树

/// 评论区的一条回复，带层级信息。
///
/// **为什么需要单独的结构**：`TwitterPost` 里没有父子指针——X 把会话以
/// `conversationthread-*` entry 返回，其 `content.items[]` 内每条推文都带
/// `legacy.in_reply_to_status_id_str`，但扁平化成 `[TwitterPost]` 后这个关系就丢了，
/// 评论只能平铺显示。这里把父指针与算好的深度一并保留。
///
/// `parentId` 直接来自响应（`in_reply_to_status_id_str`），**不需要额外请求**。
struct ReplyNode: Identifiable, Sendable {
    var post: TwitterPost
    /// 父推文 ID（`legacy.in_reply_to_status_id_str`）
    var parentId: String?
    /// 被回复者的 screen_name。优先取响应里的 `in_reply_to_screen_name`；
    /// 缺失时由构建树时从父节点解析；父不在本页（孤儿）则为 nil。
    /// 展示层用它加「回复 @xxx」前缀——**必须是父的作者**，
    /// 用回复自己的作者会写成"我回复我自己"，是错的。
    var parentScreenName: String?
    /// 相对根（focal 推文）的深度。根的直接回复为 1。
    var depth: Int
    /// 父推文不在本页结果里（X 只返回部分会话）。
    /// 这类评论**不能丢**，挂到根下并标记，展示时加「回复 @xxx」前缀。
    var isPartialParent: Bool

    var id: String { post.id }

    init(post: TwitterPost, parentId: String? = nil, parentScreenName: String? = nil,
         depth: Int = 1, isPartialParent: Bool = false) {
        self.post = post
        self.parentId = parentId
        self.parentScreenName = parentScreenName
        self.depth = depth
        self.isPartialParent = isPartialParent
    }
}

/// 评论排序方式。
///
/// `relevance` 用**服务端返回顺序**（X 的默认排序即"相关"），不做本地重排——
/// 服务端顺序携带了它自己的相关性信号，本地重排只会更差。
/// 另外两种是服务端未提供时的本地兜底（TweetDetail 没有排序变量）。
enum ReplySort: String, CaseIterable, Sendable {
    /// 相关：保持服务端顺序
    case relevance
    /// 喜欢：按点赞数降序
    case likes
    /// 最近：按发布时间降序
    case recent

    /// 本地排序。`relevance` 原样返回。
    ///
    /// 排序是**稳定**的：同键值保持原有相对顺序，避免每次刷新评论顺序乱跳。
    func sorted(_ nodes: [ReplyNode]) -> [ReplyNode] {
        switch self {
        case .relevance:
            return nodes
        case .likes:
            return nodes.enumerated().sorted { lhs, rhs in
                let l = lhs.element.post.favoriteCount ?? 0
                let r = rhs.element.post.favoriteCount ?? 0
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            }.map(\.element)
        case .recent:
            return nodes.enumerated().sorted { lhs, rhs in
                let l = lhs.element.post.createdAt ?? .distantPast
                let r = rhs.element.post.createdAt ?? .distantPast
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }
}
