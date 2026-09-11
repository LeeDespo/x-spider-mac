import Foundation

struct TwitterPost: Sendable {
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
}
