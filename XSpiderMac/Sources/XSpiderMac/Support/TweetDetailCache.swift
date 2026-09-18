import Foundation

/// 推文详情（focal + 评论树）的短期缓存。
///
/// ## 为什么需要
///
/// 详情浮层会按推文 ID **重建视图身份**（`.id(post.id)`）——这是必须的：
/// 不加的话，浮层内从 A 跳到 B 时 SwiftUI 会复用同一个视图实例，
/// `@State`（detail/replies/liked/mediaIndex）全保留 A 的值，`.task` 也不重跑，
/// 表现为"跳到引用推文后，内容还是上一条的"。
///
/// 但重建会重跑 `.task` → 再次请求 TweetDetail。于是两种常见操作各多打一次请求：
/// - 点引用推文打开 B，再点返回回到 A → A 的详情被重新请求；
/// - 在 A / B 之间反复切换。
///
/// TweetDetail 是重端点，项目一直在对抗 429，这种"回看已经看过的推文"的重复请求
/// 是实打实的配额浪费。此处按 ID 缓存，回看**零请求**。
///
/// ## 取舍
///
/// - **短 TTL（5 分钟）**：评论是会变的（新回复、点赞数），缓存太久会显得数据陈旧；
///   用户重新打开应用或等 TTL 过期即刷新。
/// - **容量上限**：只保留最近若干条，避免长时间浏览后常驻内存。
/// - **进程内**：与浏览进度记忆一致，重启后从干净状态开始。
@MainActor
final class TweetDetailCache {
    static let shared = TweetDetailCache()

    struct Entry {
        let focal: TwitterPost
        let replies: [ReplyNode]
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []       // 插入顺序，用于淘汰最旧
    private let ttl: TimeInterval = 300
    private let limit = 12

    private init() {}

    /// 取缓存。过期即丢弃并返回 nil（调用方回落到网络请求）。
    func get(_ id: String) -> Entry? {
        guard let entry = entries[id] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < ttl else {
            remove(id)
            return nil
        }
        return entry
    }

    func put(_ id: String, focal: TwitterPost, replies: [ReplyNode]) {
        entries[id] = Entry(focal: focal, replies: replies, storedAt: Date())
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// 用户主动操作（点赞/书签等）后，缓存的计数已过时：丢弃该条，
    /// 下次打开会取到新数据。
    func invalidate(_ id: String) { remove(id) }

    func clear() {
        entries.removeAll()
        order.removeAll()
    }

    private func remove(_ id: String) {
        entries.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }
}
