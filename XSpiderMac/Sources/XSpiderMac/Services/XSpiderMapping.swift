import Foundation

/// 组件返回的 JSON → 应用模型的**唯一映射层**。
///
/// # 为什么要单独一层
///
/// 应用里到处是 `TwitterPost` / `TwitterUser` / `TwitterMedia`，视图与商店都依赖它们；
/// 组件给的是契约里的 JSON。两者**字段基本一一对应**（组件就是照参考实现抽的），
/// 所以映射只做"改名字、补默认值、解日期"三件事，不做业务判断。
///
/// 这一层同时是**契约的消费点**：组件少给一个字段，这里就是第一个发现的地方
/// （`favorited` / `bookmarked` / `retweeted` 三面旗就是这么发现的）。
enum XSpiderMapping {

    // MARK: - 日期

    /// 契约给的是 RFC3339 UTC（`2026-09-25T01:33:31Z`）。
    ///
    /// `ISO8601DateFormatter` 不是 `Sendable`（Swift 6 会报"共享可变状态"），
    /// 但配置完之后它的 `date(from:)` 是只读的、线程安全的——所以这里显式
    /// `nonisolated(unsafe)` 并**只配置一次**，不在使用时改它的 `formatOptions`。
    /// 每次调用都新建一个才是真的坑（解析一条推文建一个格式化器）。
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.asString, !text.isEmpty else { return nil }
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }

    // MARK: - 用户

    static func user(_ json: [String: JSONValue]) -> TwitterUser? {
        guard let id = json[string: "id"], !id.isEmpty else { return nil }
        let screenName = json[string: "screen_name"] ?? ""
        guard !screenName.isEmpty else { return nil }
        return TwitterUser(
            screenName: screenName,
            // 组件已归一化（`https:` + `_bigger`），这里不再做替换
            avatar: json[string: "avatar"] ?? "",
            name: json[string: "name"] ?? screenName,
            id: id,
            mediaCount: json[int: "media_count"],
            registerTime: date(json["register_time"]))
    }

    /// 推文里的作者（契约是紧凑形状，字段名与 `user` 一致）。
    private static func author(_ json: [String: JSONValue]) -> TwitterUser? {
        user(json)
    }

    // MARK: - 媒体

    static func media(_ json: [String: JSONValue], createdTime: Date?) -> TwitterMedia? {
        guard let kindText = json[string: "kind"],
              let kind = MediaType(rawValue: kindText),
              let url = json[string: "url"], !url.isEmpty else { return nil }

        let width = json[int: "width"]
        let height = json[int: "height"]
        let duration = json["duration_ms"]?.asDouble
        let aspect = json[array: "aspect_ratio"]?.compactMap { $0.asInt }

        var videoInfo: VideoInfo?
        switch kind {
        case .photo:
            videoInfo = nil
        case .gif:
            // 动图在契约里就是"可直接下载的 mp4"，参考实现把它放在 videoInfo.url
            videoInfo = VideoInfo(url: url, duration: nil, variants: nil, aspectRatio: aspect)
        case .video:
            let variants = json[array: "variants"]?.compactMap { raw -> VideoVariant? in
                guard let fields = raw.asObject, let variantURL = fields[string: "url"] else { return nil }
                return VideoVariant(
                    bitrate: fields[int: "bitrate"],
                    contentType: fields[string: "content_type"],
                    url: variantURL)
            }
            videoInfo = VideoInfo(url: nil, duration: duration, variants: variants, aspectRatio: aspect)
        }

        // **封面**取契约的 `poster_url`（= X 的 `media_url_https`）：视频/动图给的是静帧，
        // 图片则是它本身。应用的 `TwitterMedia.url` 一直是这个语义
        // （网格与详情页把它当图片解码、照片下载时再补 `?name=orig`），
        // 所以**不能**填可下载地址——那样视频格子会去解码 mp4，整片空白。
        // 图片缺 poster 时回落 `url`（两者本来就相同）。
        let poster = json[string: "poster_url"] ?? (kind == .photo ? url : nil)

        return TwitterMedia(
            id: json[string: "id"],
            url: poster,
            width: width,
            height: height,
            type: kind,
            videoInfo: videoInfo,
            createdTime: createdTime)
    }

    // MARK: - 推文

    static func post(_ json: [String: JSONValue], includeQuoted: Bool = true) -> TwitterPost? {
        guard let id = json[string: "id"], !id.isEmpty else { return nil }
        guard let authorJSON = json[object: "author"],
              let postAuthor = Self.author(authorJSON) else { return nil }

        let createdAt = date(json["created_at"])
        let medias = json[array: "medias"]?.compactMap { item -> TwitterMedia? in
            guard let fields = item.asObject else { return nil }
            return media(fields, createdTime: createdAt)
        }

        let retweetedBy = json[object: "retweeted_by"].flatMap { Self.author($0) }

        // 被引用的推文：契约只给 id（`quoted_id`），没有内嵌对象——
        // 参考实现的内嵌引用来自 X 的 `quoted_status_result`。
        // 视图要显示引用内容时会用 id 单独取（`fetch.tweet_detail`），
        // 所以这里不塞半成品对象，避免"看起来有其实空"的卡片。
        _ = includeQuoted

        return TwitterPost(
            id: id,
            user: postAuthor,
            createdAt: createdAt,
            fullText: json[string: "full_text"],
            tags: json[array: "tags"]?.compactMap { $0.asString },
            views: json[int: "views"],
            lang: json[string: "lang"],
            retweeted: json[bool: "retweeted"],
            retweetCount: json[int: "retweet_count"],
            replyCount: json[int: "reply_count"],
            possiblySensitive: json[bool: "possibly_sensitive"],
            favorited: json[bool: "favorited"],
            favoriteCount: json[int: "favorite_count"],
            bookmarkCount: json[int: "bookmark_count"],
            bookmarked: json[bool: "bookmarked"],
            medias: medias,
            quotedPost: nil,
            retweetedBy: retweetedBy)
    }

    // MARK: - 分页

    /// `page<post>` → `(posts, cursor)`。注意契约里 **cursor 键不出现就是到头了**。
    static func postPage(_ result: [String: JSONValue]) -> (posts: [TwitterPost], cursor: String?) {
        let items = (result[array: "items"] ?? []).compactMap { $0.asObject }
        return (items.compactMap { post($0) }, result[string: "cursor"])
    }

    static func userPage(_ result: [String: JSONValue]) -> (users: [TwitterUser], cursor: String?) {
        let items = (result[array: "items"] ?? []).compactMap { $0.asObject }
        return (items.compactMap { user($0) }, result[string: "cursor"])
    }

    // MARK: - 评论树

    /// `fetch.tweet_detail` 的回复 → `[ReplyNode]`（含深度）。
    ///
    /// 契约给 `parent_id`（父推文 id）与 `is_partial_parent`（父不在本页），
    /// 但**不给深度**——深度是外壳按同一份数据算出来的：从根往下走父链。
    /// 参考实现的树也是在这里构建的，所以这一步留在应用侧是对的。
    static func replyNodes(_ result: [String: JSONValue], focalId: String) -> (focal: TwitterPost?, replies: [ReplyNode]) {
        let focal = result[object: "focal"].flatMap { post($0) }
        let rawReplies = (result[array: "replies"] ?? []).compactMap { $0.asObject }

        var byId: [String: ReplyNode] = [:]
        var order: [String] = []
        for raw in rawReplies {
            guard let parsed = post(raw) else { continue }
            let node = ReplyNode(
                post: parsed,
                parentId: raw[string: "parent_id"],
                parentScreenName: raw[string: "in_reply_to_screen_name"],
                depth: 1,
                isPartialParent: raw[bool: "is_partial_parent"] ?? false)
            byId[node.id] = node
            order.append(node.id)
        }

        // 算深度：父不在本页（孤儿）或父是 focal → 1；否则父深度 + 1。
        // **不丢任何一条**：X 只返回部分会话，丢掉孤儿会让评论区凭空少内容。
        func depth(of id: String, seen: Set<String> = []) -> Int {
            guard let node = byId[id], let parentId = node.parentId else { return 1 }
            if parentId == focalId { return 1 }
            if seen.contains(id) { return 1 }              // 数据成环也不能死循环
            guard byId[parentId] != nil else { return 1 }  // 父不在本页
            return depth(of: parentId, seen: seen.union([id])) + 1
        }
        for id in order {
            byId[id]?.depth = depth(of: id)
        }
        return (focal, order.compactMap { byId[$0] })
    }
}
