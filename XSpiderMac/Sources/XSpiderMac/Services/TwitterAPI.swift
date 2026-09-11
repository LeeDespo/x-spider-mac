import Foundation

/// 上游 twitter/api.ts 的完整移植。
/// queryId 与 features 必须与上游逐字对齐，否则 X 服务端直接拒绝。
actor TwitterAPI {
    static let shared = TwitterAPI()

    private let host = "x.com"
    private let bearer = "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZzSnriE"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

    private var client = NetworkClient()
    private var cookieString: String = ""

    /// 非持久状态：由 AppStore 每次 cookie 变更时推送
    func configure(cookie: String, proxy: ProxySettings) {
        self.cookieString = cookie
        self.client = NetworkClient(proxy: proxy)
    }

    // MARK: - Headers

    private func commonHeaders(withCredentials: Bool = true) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Referer": "https://\(host)",
        ]
        if withCredentials {
            headers["Authorization"] = bearer
            headers["Cookie"] = cookieString
            headers["X-Csrf-Token"] = Cookie.parse(cookieString)["ct0"] ?? ""
        }
        return headers
    }

    // MARK: - 账户信息（登录验证）

    /// 抓取 x.com 首页 HTML，正则提取 screen_name 与头像。
    /// 与上游一致：cookie 无效时页面不含这些字段 → 抛 missingScreenName。
    func getAccountInfo(cookieStringOverride: String? = nil) async throws -> TwitterAccountInfo {
        let url = URL(string: "https://\(host)")!
        var headers = commonHeaders(withCredentials: false)
        if let cookie = cookieStringOverride { headers["Cookie"] = cookie }
        let resp = try await client.request(url: url, headers: headers)
        let html = resp.text()
        guard let screenName = extract(pattern: #""screen_name":"(.*?)""#, from: html) else {
            throw TwitterAPIError.missingScreenName
        }
        guard let avatar = extract(pattern: #""profile_image_url_https":"(.*?)""#, from: html) else {
            throw TwitterAPIError.missingAvatar
        }
        return TwitterAccountInfo(screenName: screenName, avatar: avatar)
    }

    // MARK: - 用户查询

    func getUser(screenName: String) async throws -> TwitterUser {
        let url = URL(string: "https://\(host)/i/api/graphql/NimuplG1OB7Fd2btCLdBOw/UserByScreenName")!
        let variables = """
        {"screen_name":"\(screenName)","withSafetyModeUserFields":true}
        """
        let resp = try await client.request(
            url: url,
            query: [
                "features": Self.userByScreenNameFeatures,
                "fieldToggles": #"{"withAuxiliaryUserLabels":false}"#,
                "variables": variables,
            ],
            headers: commonHeaders()
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any],
              let user = (json["data"] as? [String: Any])?["user"] as? [String: Any],
              let result = user["result"] as? [String: Any],
              let legacy = result["legacy"] as? [String: Any] else {
            throw TwitterAPIError.userNotFound
        }
        let restId = result["rest_id"] as? String ?? ""
        return TwitterUser(
            screenName: legacy["screen_name"] as? String ?? screenName,
            avatar: legacy["profile_image_url_https"] as? String ?? "",
            name: legacy["name"] as? String ?? "",
            id: restId,
            mediaCount: legacy["media_count"] as? Int,
            registerTime: TwitterDate.parse(legacy["created_at"] as? String)
        )
    }

    // MARK: - 媒体时间线

    /// 上游 UserMedia（queryId cEjpJXA15Ok78yO4TUQPeQ）。
    /// 返回推文数组 + 下一页 cursor（Bottom cursor value），无更多页时 cursor 为 nil。
    func getUserMedias(userId: String, cursor: String? = nil, count: Int = 20) async throws -> (posts: [TwitterPost], cursor: String?) {
        let url = URL(string: "https://\(host)/i/api/graphql/cEjpJXA15Ok78yO4TUQPeQ/UserMedia")!
        let variables = Self.encodeJSON([
            "userId": userId,
            "count": count,
            "cursor": NSNull(),
            "includePromotedContent": false,
            "withClientEventToken": false,
            "withBirdwatchNotes": false,
            "withVoice": true,
            "withV2Timeline": true,
        ] as [String: Any]) ?? "{}"

        let resp = try await client.request(
            url: url,
            query: [
                "features": Self.userMediaFeatures,
                "variables": variables,
            ],
            headers: commonHeaders()
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else {
            throw TwitterAPIError.parseFailure
        }
        let instructions = Self.path(json, ["data", "user", "result", "timeline_v2", "timeline", "instructions"]) as? [[String: Any]] ?? []
        let posts = Self.extractPostsFromModuleInstructions(instructions)
        let cursor = Self.extractBottomCursor(instructions)
        return (posts, cursor)
    }

    // MARK: - 推文时间线

    /// 上游 UserTweets（queryId 9zyyd1hebl7oNWIPdA8HRw）。
    /// 与 UserMedia 不同：entries 里 tweet-* 是单推文 entry，profile-conversation 是会话模块（其 items 里含多推文）。
    func getUserTweets(userId: String, cursor: String? = nil, count: Int = 20) async throws -> (posts: [TwitterPost], cursor: String?) {
        let url = URL(string: "https://\(host)/i/api/graphql/9zyyd1hebl7oNWIPdA8HRw/UserTweets")!
        var variablesDict: [String: Any] = [
            "userId": userId,
            "count": count,
            "includePromotedContent": true,
            "withQuickPromoteEligibilityTweetFields": true,
            "withVoice": true,
            "withV2Timeline": true,
        ]
        if let cursor { variablesDict["cursor"] = cursor } else { variablesDict["cursor"] = NSNull() }

        let resp = try await client.request(
            url: url,
            query: [
                "features": Self.userTweetsFeatures,
                "variables": Self.encodeJSON(variablesDict) ?? "{}",
            ],
            headers: commonHeaders()
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else {
            throw TwitterAPIError.parseFailure
        }
        let instructions = Self.path(json, ["data", "user", "result", "timeline_v2", "timeline", "instructions"]) as? [[String: Any]] ?? []
        let posts = Self.extractPostsFromTweetEntries(instructions)
        let cursor = Self.extractBottomCursor(instructions)
        return (posts, cursor)
    }

    // MARK: - JSON 解析（对应上游 ramda path 管线）

    /// UserMedia 专用：TimelineAddEntries 里找 TimelineTimelineModule（多图推文），
    /// 或 TimelineAddToModule 的 moduleItems。每个 item 取 tweet_results.result，
    /// __typename 为 TweetWithVisibilityResults 时取 .tweet。
    static func extractPostsFromModuleInstructions(_ instructions: [[String: Any]]) -> [TwitterPost] {
        var results: [[String: Any]] = []

        if let addEntries = instructions.first(where: { $0["type"] as? String == "TimelineAddEntries" }),
           let entries = addEntries["entries"] as? [[String: Any]] {
            if let module = entries.first(where: { (($0["content"] as? [String: Any])?["entryType"] as? String) == "TimelineTimelineModule" }),
               let items = (module["content"] as? [String: Any])?["items"] as? [[String: Any]] {
                for item in items {
                    if let result = Self.path(item, ["item", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                        results.append(Self.unwrapVisibility(result))
                    }
                }
            }
        }

        if results.isEmpty,
           let addToModule = instructions.first(where: { $0["type"] as? String == "TimelineAddToModule" }),
           let moduleItems = addToModule["moduleItems"] as? [[String: Any]] {
            for item in moduleItems {
                if let result = Self.path(item, ["item", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                    results.append(Self.unwrapVisibility(result))
                }
            }
        }

        return results.compactMap(Self.mapTwitterPost)
    }

    /// UserTweets 专用：entryId 以 tweet- 开头取单推文；profile-conversation- 开头取会话内全部推文。
    /// 过滤转推（retweeted_status_result 存在）与无媒体推文（与上游一致）。
    static func extractPostsFromTweetEntries(_ instructions: [[String: Any]]) -> [TwitterPost] {
        var rawResults: [[String: Any]] = []

        guard let addEntries = instructions.first(where: { $0["type"] as? String == "TimelineAddEntries" }),
              let entries = addEntries["entries"] as? [[String: Any]] else { return [] }

        for entry in entries {
            let entryId = entry["entryId"] as? String ?? ""
            let content = entry["content"] as? [String: Any] ?? [:]

            if entryId.hasPrefix("tweet") {
                if let result = Self.path(content, ["itemContent", "tweet_results", "result"]) as? [String: Any] {
                    rawResults.append(Self.unwrapVisibility(result))
                }
            } else if entryId.hasPrefix("profile-conversation") {
                if let items = content["items"] as? [[String: Any]] {
                    for item in items {
                        if let result = Self.path(item, ["item", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                            rawResults.append(Self.unwrapVisibility(result))
                        }
                    }
                }
            }
        }

        return rawResults
            .filter { !Self.hasPath($0, ["legacy", "retweeted_status_result"]) }
            .filter { Self.hasPath($0, ["legacy", "entities", "media"]) }
            .compactMap(Self.mapTwitterPost)
    }

    static func extractBottomCursor(_ instructions: [[String: Any]]) -> String? {
        guard let addEntries = instructions.first(where: { $0["type"] as? String == "TimelineAddEntries" }),
              let entries = addEntries["entries"] as? [[String: Any]] else { return nil }
        for entry in entries {
            if let content = entry["content"] as? [String: Any],
               content["cursorType"] as? String == "Bottom" {
                return content["value"] as? String
            }
        }
        return nil
    }

    /// TweetWithVisibilityResults → 实际推文
    static func unwrapVisibility(_ result: [String: Any]) -> [String: Any] {
        if result["__typename"] as? String == "TweetWithVisibilityResults",
           let tweet = result["tweet"] as? [String: Any] {
            return tweet
        }
        return result
    }

    // MARK: - 推文字段映射（对应上游 mapTwitterPosts）

    static func mapTwitterPost(_ item: [String: Any]) -> TwitterPost? {
        let legacy = item["legacy"] as? [String: Any] ?? [:]
        let coreUser = Self.path(item, ["core", "user_results", "result"]) as? [String: Any]
        let userLegacy = coreUser?["legacy"] as? [String: Any] ?? [:]
        let entities = legacy["entities"] as? [String: Any] ?? [:]

        return TwitterPost(
            id: item["rest_id"] as? String ?? "",
            user: TwitterUser(
                screenName: userLegacy["screen_name"] as? String ?? "",
                avatar: userLegacy["profile_image_url_https"] as? String ?? "",
                name: userLegacy["name"] as? String ?? "",
                id: coreUser?["rest_id"] as? String ?? "",
                mediaCount: userLegacy["media_count"] as? Int,
                registerTime: TwitterDate.parse(userLegacy["created_at"] as? String)
            ),
            createdAt: TwitterDate.parse(legacy["created_at"] as? String),
            fullText: legacy["full_text"] as? String,
            tags: (entities["hashtags"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? [],
            views: ((item["views"] as? [String: Any])?["count"] as? String).flatMap(Int.init),
            lang: legacy["lang"] as? String,
            retweeted: legacy["retweeted"] as? Bool,
            retweetCount: legacy["retweet_count"] as? Int,
            replyCount: legacy["reply_count"] as? Int,
            possiblySensitive: legacy["possibly_sensitive"] as? Bool,
            favorited: legacy["favorited"] as? Bool,
            favoriteCount: legacy["favorite_count"] as? Int,
            bookmarkCount: legacy["bookmark_count"] as? Int,
            bookmarked: legacy["bookmarked"] as? Bool,
            medias: Self.mapTwitterMedias(entities["media"] as? [[String: Any]])
        )
    }

    static func mapTwitterMedias(_ medias: [[String: Any]]?) -> [TwitterMedia]? {
        guard let medias, !medias.isEmpty else { return nil }
        var result: [TwitterMedia] = []
        for m in medias {
            let type = m["type"] as? String ?? ""
            let originalInfo = m["original_info"] as? [String: Any] ?? [:]
            let base = (
                id: m["id_str"] as? String,
                url: m["media_url_https"] as? String,
                width: originalInfo["width"] as? Int,
                height: originalInfo["height"] as? Int
            )

            switch type {
            case "photo":
                result.append(TwitterMedia(
                    id: base.id, url: base.url, width: base.width, height: base.height,
                    type: .photo, videoInfo: nil
                ))
            case "video":
                let videoInfo = m["video_info"] as? [String: Any] ?? [:]
                let variants = (videoInfo["variants"] as? [[String: Any]])?.map {
                    VideoVariant(
                        bitrate: $0["bitrate"] as? Int,
                        contentType: $0["content_type"] as? String,
                        url: $0["url"] as? String
                    )
                }
                result.append(TwitterMedia(
                    id: base.id, url: base.url, width: base.width, height: base.height,
                    type: .video,
                    videoInfo: VideoInfo(
                        url: nil,
                        duration: videoInfo["duration_millis"] as? Double,
                        variants: variants,
                        aspectRatio: videoInfo["aspect_ratio"] as? [Int]
                    )
                ))
            case "animated_gif":
                let videoInfo = m["video_info"] as? [String: Any] ?? [:]
                let firstUrl = (videoInfo["variants"] as? [[String: Any]])?.first?["url"] as? String
                result.append(TwitterMedia(
                    id: base.id, url: base.url, width: base.width, height: base.height,
                    type: .gif,
                    videoInfo: VideoInfo(
                        url: firstUrl,
                        duration: nil,
                        variants: nil,
                        aspectRatio: videoInfo["aspect_ratio"] as? [Int]
                    )
                ))
            default:
                continue
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - 工具

    private func ensureResponse(_ resp: NetworkResponse) throws {
        if resp.status >= 400 {
            throw TwitterAPIError.responseError(status: resp.status)
        }
    }

    static func path(_ dict: [String: Any], _ keys: [String]) -> Any? {
        var current: Any? = dict
        for key in keys {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    static func hasPath(_ dict: [String: Any], _ keys: [String]) -> Bool {
        Self.path(dict, keys) != nil
    }

    static func encodeJSON(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func extract(pattern: String, from: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: from, options: [], range: NSRange(from.startIndex..., in: from)) else { return nil }
        let range = Range(match.range(at: 1), in: from)
        return range.map { String(from[$0]) }
    }
}

// MARK: - features 常量（必须与上游逐字对齐）

extension TwitterAPI {
    static let userByScreenNameFeatures = #"{"hidden_profile_likes_enabled":true,"hidden_profile_subscriptions_enabled":true,"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"subscriptions_verification_info_is_identity_verified_enabled":true,"subscriptions_verification_info_verified_since_enabled":true,"highlights_tweets_tab_ui_enabled":true,"responsive_web_twitter_article_notes_tab_enabled":false,"creator_subscriptions_tweet_preview_api_enabled":true,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"responsive_web_graphql_timeline_navigation_enabled":true}"#

    static let userMediaFeatures = #"{"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"creator_subscriptions_tweet_preview_api_enabled":true,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"c9s_tweet_anatomy_moderator_badge_enabled":true,"tweetypie_unmention_optimization_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":true,"tweet_awards_web_tipping_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"rweb_video_timestamps_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,"responsive_web_media_download_video_enabled":false,"responsive_web_enhance_cards_enabled":false}"#

    static let userTweetsFeatures = #"{"rweb_tipjar_consumption_enabled":true,"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"creator_subscriptions_tweet_preview_api_enabled":true,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"communities_web_enable_tweet_community_results_fetch":true,"c9s_tweet_anatomy_moderator_badge_enabled":true,"articles_preview_enabled":false,"tweetypie_unmention_optimization_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":true,"tweet_awards_web_tipping_enabled":false,"creator_subscriptions_quote_tweet_preview_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"tweet_with_visibility_results_prefer_gql_media_interstitial_enabled":false,"rweb_video_timestamps_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,"responsive_web_enhance_cards_enabled":false}"#
}

// MARK: - Cookie 工具（上游 utils/cookie.ts）

enum Cookie {
    static func parse(_ cookieString: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in cookieString.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                result[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1])
            }
        }
        return result
    }

    static func stringify(_ cookie: [String: String]) -> String {
        cookie.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}

// MARK: - X 日期解析（"Wed Oct 10 20:19:24 +0000 2018"）

enum TwitterDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss ZZZ yyyy"
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return formatter.date(from: string)
    }
}

// MARK: - 错误

enum TwitterAPIError: LocalizedError {
    case responseError(status: Int)
    case missingScreenName
    case missingAvatar
    case userNotFound
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .responseError(let status): return "响应错误：status=\(status)"
        case .missingScreenName: return "Cookie 无效或未登录：响应中找不到 screen_name"
        case .missingAvatar: return "响应中找不到头像"
        case .userNotFound: return "找不到该用户"
        case .parseFailure: return "响应解析失败"
        }
    }
}
