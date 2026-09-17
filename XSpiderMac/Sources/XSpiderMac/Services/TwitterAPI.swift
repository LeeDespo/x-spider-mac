import Foundation

/// 上游 twitter/api.ts 的完整移植。
/// queryId 与 features 必须与上游逐字对齐，否则 X 服务端直接拒绝。
actor TwitterAPI {
    static let shared = TwitterAPI()

    private let host = "x.com"
    /// twscrape/account.py TOKEN：X 轮换后的有效 Bearer（上游 2024 硬编码版已 401）
    private let bearer = XClientTransaction.bearer
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

    private var client = NetworkClient()
    private var cookieString: String = ""
    /// XClId 密钥是否就绪（首次 GraphQL 请求前需要 loadKeys）
    private var xclidReady = false

    /// 非持久状态：由 AppStore 每次 cookie 变更时推送
    func configure(cookie: String, proxy: ProxySettings) async {
        self.cookieString = cookie
        // 先释放旧会话：仅替换引用不会关闭其连接池，旧连接可能仍指向失效的代理路径，
        // 在超时前一直挂着 —— 表现为"代理恢复了但应用还卡着"
        await client.invalidate()
        self.client = NetworkClient(proxy: proxy)
        await XClientTransaction.shared.updateClient(client)
        xclidReady = false
    }

    // MARK: - Headers

    /// twscrape/account.py make_client 的头集合 + X 2025 交易 ID
    private func commonHeaders(withCredentials: Bool = true, method: String = "GET", path: String? = nil) async -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": Self.userAgent,
            "Referer": "https://\(host)",
        ]
        if withCredentials {
            headers["Authorization"] = bearer
            headers["Cookie"] = cookieString
            headers["X-Csrf-Token"] = Cookie.parse(cookieString)["ct0"] ?? ""
            // twscrape 头集合（2025 校验必需）
            headers["x-twitter-active-user"] = "yes"
            headers["x-twitter-client-language"] = "en"
            // X 新防护：每个 /i/api/ 请求都要交易 ID
            let apiPath = path ?? ""
            if let txid = await XClientTransaction.shared.transactionId(method: method, path: apiPath) {
                headers["x-client-transaction-id"] = txid
            }
        }
        return headers
    }

    /// 确保 XClId 密钥已加载（cookie 有效后调用一次）
    private func ensureXClIdLoaded() async throws {
        guard !xclidReady else { return }
        try await XClientTransaction.shared.loadKeys(cookieString: cookieString)
        xclidReady = true
    }

    /// TweetDetail：返回 focal 推文 + conversation 时间线里的回复（媒体详情弹窗评论区用）
    func getTweetWithReplies(id: String) async throws -> (focal: TwitterPost, replies: [TwitterPost]) {
        try await ensureXClIdLoaded()
        let path = "/i/api/graphql/XMOz5h24KAZ86qKffKTLdQ/TweetDetail"
        let url = URL(string: "https://\(host)\(path)")!
        let variables = Self.encodeJSON([
            "focalTweetId": id,
            "with_rux_injections": true,
            "includePromotedContent": true,
            "withCommunity": true,
            "withQuickPromoteEligibilityTweetFields": true,
            "withBirdwatchNotes": true,
            "withVoice": true,
            "withV2Timeline": true,
        ] as [String: Any]) ?? "{}"

        let resp = try await client.request(
            url: url,
            query: [
                "variables": variables,
                "features": Self.tweetDetailFeatures,
            ],
            headers: await commonHeaders(method: "GET", path: path)
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else {
            throw TwitterAPIError.parseFailure
        }
        let instructions = Self.path(json, ["data", "tweetResult", "result", "timeline", "instructions"]) as? [[String: Any]]
            ?? (Self.path(json, ["data", "threaded_conversation_with_injections_v2", "instructions"]) as? [[String: Any]] ?? [])
        let posts = Self.extractPostsFromTweetEntries(instructions)
        guard let focal = posts.first(where: { $0.id == id }) ?? posts.first else {
            throw TwitterAPIError.parseFailure
        }
        return (focal, posts.filter { $0.id != focal.id })
    }

    // MARK: - 单条推文（TweetDetail，用于推文链接搜索）

    /// 上游 op XMOz5h24KAZ86qKffKTLdQ/TweetDetail。返回 focal 推文（含媒体）。
    func getTweet(id: String) async throws -> TwitterPost {
        try await ensureXClIdLoaded()
        let path = "/i/api/graphql/XMOz5h24KAZ86qKffKTLdQ/TweetDetail"
        let url = URL(string: "https://\(host)\(path)")!
        let variables = Self.encodeJSON([
            "focalTweetId": id,
            "with_rux_injections": true,
            "includePromotedContent": true,
            "withCommunity": true,
            "withQuickPromoteEligibilityTweetFields": true,
            "withBirdwatchNotes": true,
            "withVoice": true,
            "withV2Timeline": true,
        ] as [String: Any]) ?? "{}"

        let resp = try await client.request(
            url: url,
            query: [
                "variables": variables,
                "features": Self.tweetDetailFeatures,
            ],
            headers: await commonHeaders(method: "GET", path: path)
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else {
            throw TwitterAPIError.parseFailure
        }
        let instructions = Self.path(json, ["data", "tweetResult", "result", "timeline", "instructions"]) as? [[String: Any]]
            ?? (Self.path(json, ["data", "threaded_conversation_with_injections_v2", "instructions"]) as? [[String: Any]] ?? [])
        let posts = Self.extractPostsFromTweetEntries(instructions)
        // focal 推文 = id 匹配的第一条；TweetDetail 也可能只返回 conversation 模块
        if let focal = posts.first(where: { $0.id == id }) {
            return focal
        }
        // 退化：返回第一条有媒体的
        guard let first = posts.first else {
            throw TwitterAPIError.parseFailure
        }
        return first
    }

    static let tweetDetailFeatures = #"{"articles_preview_enabled":false,"c9s_tweet_anatomy_moderator_badge_enabled":true,"communities_web_enable_tweet_community_results_fetch":true,"creator_subscriptions_quote_tweet_preview_enabled":false,"creator_subscriptions_tweet_preview_api_enabled":true,"freedom_of_speech_not_reach_fetch_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"longform_notetweets_consumption_enabled":true,"longform_notetweets_inline_media_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"responsive_web_enhance_cards_enabled":false,"responsive_web_graphql_exclude_directive_enabled":true,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"responsive_web_grok_community_note_auto_translation_is_enabled":false,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_grok_imagine_annotation_enabled":false,"responsive_web_media_download_video_enabled":false,"responsive_web_profile_redirect_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":true,"rweb_tipjar_consumption_enabled":true,"rweb_video_timestamps_enabled":true,"standardized_nudges_misinfo":true,"tweet_awards_web_tipping_enabled":false,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"tweet_with_visibility_results_prefer_gql_media_interstitial_enabled":false,"tweetypie_unmention_optimization_enabled":true,"verified_phone_label_enabled":false,"view_counts_everywhere_api_enabled":true,"responsive_web_grok_analyze_button_fetch_trends_enabled":false,"premium_content_api_read_enabled":false,"profile_label_improvements_pcf_label_in_post_enabled":false,"responsive_web_grok_share_attachment_enabled":false,"responsive_web_grok_analyze_post_followups_enabled":false,"responsive_web_grok_image_annotation_enabled":false,"responsive_web_grok_analysis_button_from_backend":false,"responsive_web_jetfuel_frame":false,"rweb_video_screen_enabled":true,"responsive_web_grok_show_grok_translated_post":true}"#

    // MARK: - 连接探测（仅由用户点「重试」触发，不做轮询）

    /// 探测与 X 的连通性：抓一次首页 HTML 并解析账号信息。
    /// 选它的原因：这是**已有的登录验证请求**（`getAccountInfo`），不额外引入端点，
    /// 一次请求即可同时覆盖"能否连通"与"Cookie 是否仍有效"。
    /// 快速失败（2 次尝试 / 15s 超时），避免按钮长时间转圈。
    func probeConnection() async throws -> TwitterAccountInfo {
        try await getAccountInfo(fast: true)
    }

    // MARK: - 账户信息（登录验证）

    /// 抓取 x.com 首页 HTML，正则提取 screen_name 与头像。
    /// 与上游一致：cookie 无效时页面不含这些字段 → 抛 missingScreenName。
    /// - Parameter fast: true 时单次 15s 超时、最多 2 次（手动探测用，快速给出结论）
    func getAccountInfo(cookieStringOverride: String? = nil, fast: Bool = false) async throws -> TwitterAccountInfo {
        let url = URL(string: "https://\(host)")!
        var headers = await commonHeaders(withCredentials: false)
        if let cookie = cookieStringOverride { headers["Cookie"] = cookie }
        let resp = try await (fast
            ? client.requestFast(url: url, headers: headers, bypassGate: true)
            : client.request(url: url, headers: headers))
        let html = resp.text()
        guard let screenName = extract(pattern: #""screen_name":"(.*?)""#, from: html) else {
            throw TwitterAPIError.missingScreenName
        }
        guard let avatar = extract(pattern: #""profile_image_url_https":"(.*?)""#, from: html) else {
            throw TwitterAPIError.missingAvatar
        }
        let restId = extract(pattern: #""rest_id":"(\d+)""#, from: html)
        return TwitterAccountInfo(screenName: screenName, avatar: avatar, id: restId)
    }

    // MARK: - 用户查询

    func getUser(screenName: String, fast: Bool = false) async throws -> TwitterUser {
        try await ensureXClIdLoaded()
        let path = "/i/api/graphql/NimuplG1OB7Fd2btCLdBOw/UserByScreenName"
        let url = URL(string: "https://\(host)\(path)")!
        let variables = """
        {"screen_name":"\(screenName)","withSafetyModeUserFields":true}
        """
        let resp = try await (fast
            ? client.requestFast(url: url, query: [
                "features": Self.userByScreenNameFeatures,
                "fieldToggles": #"{"withAuxiliaryUserLabels":false}"#,
                "variables": variables,
            ], headers: await commonHeaders(method: "GET", path: path))
            : client.request(url: url, query: [
                "features": Self.userByScreenNameFeatures,
                "fieldToggles": #"{"withAuxiliaryUserLabels":false}"#,
                "variables": variables,
            ], headers: await commonHeaders(method: "GET", path: path)))
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

    // MARK: - 推文互动（点赞/转推/书签）

    /// POST GraphQL 突变操作的公共封装
    private func mutate(path: String, variables: String, features: String? = nil) async throws {
        try await ensureXClIdLoaded()
        let url = URL(string: "https://\(host)\(path)")!
        var query: [String: String] = ["variables": variables]
        if let features { query["features"] = features }
        let resp = try await client.request(
            method: "POST",
            url: url,
            query: query,
            headers: await commonHeaders(method: "POST", path: path)
        )
        try ensureResponse(resp)
    }

    /// 关注 / 取关（v1.1 friendships REST;走 api.twitter.com,X web 同款端点）
    func followUser(screenName: String) async throws {
        try await formPost(baseHost: "api.twitter.com", path: "/1.1/friendships/create.json",
                           fields: ["screen_name": screenName, "skip_status": "true"])
        invalidateFollowCache(screenName)
    }

    func unfollowUser(screenName: String) async throws {
        try await formPost(baseHost: "api.twitter.com", path: "/1.1/friendships/destroy.json",
                           fields: ["screen_name": screenName, "skip_status": "true"])
        invalidateFollowCache(screenName)
    }

    /// 当前账户 restId(账户信息缺 id 时用 UserByScreenName 补查)
    func currentUserId() async -> String? {
        if let id = await MainActor.run(body: { AppStore.shared.account?.id }), !id.isEmpty { return id }
        guard let sn = await MainActor.run(body: { AppStore.shared.account?.screenName }) else { return nil }
        return (try? await getUser(screenName: sn).id) ?? nil
    }

    /// 用户 result dict → TwitterUser(兼容 legacy 与新版 core 结构)
    static func mapTwitterUser(_ result: [String: Any]) -> TwitterUser? {
        let legacy = result["legacy"] as? [String: Any] ?? [:]
        let core = result["core"] as? [String: Any] ?? [:]
        let screenName = (legacy["screen_name"] as? String)
            ?? (core["screen_name"] as? String)
        guard let sn = screenName, !sn.isEmpty else { return nil }
        let name = (legacy["name"] as? String) ?? (core["name"] as? String) ?? sn
        var avatar = (legacy["profile_image_url_https"] as? String)
            ?? ((core["avatar"] as? [String: Any])?["url"] as? String)
            ?? ((result["avatar"] as? [String: Any])?["image_url"] as? String)
            ?? ((result["profile_image_url_https"] as? String))
            ?? ""
        // 协议相对 URL 补 https;_normal(48px) 提升为 _bigger(73px)清晰些
        if avatar.hasPrefix("//") { avatar = "https:" + avatar }
        if avatar.contains("_normal") { avatar = avatar.replacingOccurrences(of: "_normal", with: "_bigger") }
        return TwitterUser(
            screenName: sn,
            avatar: avatar,
            name: name,
            id: result["rest_id"] as? String ?? "",
            mediaCount: legacy["media_count"] as? Int,
            registerTime: TwitterDate.parse(legacy["created_at"] as? String)
        )
    }

    /// 关注列表(Following GraphQL;返回用户数组+cursor)
    func getFollowing(userId: String, cursor: String? = nil, count: Int = 100) async throws -> (users: [TwitterUser], cursor: String?) {
        try await ensureXClIdLoaded()
        let path = "/i/api/graphql/F42cDX8PDFxkbjjq6JrM2w/Following"
        let url = URL(string: "https://\(host)\(path)")!
        var vars: [String: Any] = ["userId": userId, "count": count, "includePromotedContent": false]
        if let cursor { vars["cursor"] = cursor }
        let resp = try await client.request(
            url: url,
            query: [
                "variables": Self.encodeJSON(vars) ?? "{}",
                "features": Self.userMediaFeatures,
            ],
            headers: await commonHeaders(method: "GET", path: path)
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else { throw TwitterAPIError.parseFailure }
        let instructions = Self.path(json, ["data", "user", "result", "timeline", "timeline", "instructions"]) as? [[String: Any]]
            ?? Self.path(json, ["data", "user", "result", "timeline", "instructions"]) as? [[String: Any]]
            ?? []
        var users: [TwitterUser] = []
        if let addEntries = instructions.first(where: { $0["type"] as? String == "TimelineAddEntries" }),
           let entries = addEntries["entries"] as? [[String: Any]] {
            for entry in entries {
                let entryId = entry["entryId"] as? String ?? ""
                guard entryId.hasPrefix("user-") else { continue }
                let content = entry["content"] as? [String: Any] ?? [:]
                if let result = Self.path(content, ["itemContent", "user_results", "result"]) as? [String: Any] {
                    if let u = Self.mapTwitterUser(result) { users.append(u) }
                }
            }
        }
        let bottom = Self.extractBottomCursor(instructions)
        return (users, bottom)
    }

    /// 是否已关注（v1.1 friendships/show）
    /// 关系结果做过期缓存：每张推文卡的关注按钮都会查一次，时间线上同名作者重复出现时
    /// 会造成大量重复请求（实测一次首页加载并发多个 friendships/show），是限流的放大器。
    private var followCache: [String: (value: Bool, at: Date)] = [:]
    private let followCacheTTL: TimeInterval = 300

    func isFollowing(screenName: String, useCache: Bool = true) async throws -> Bool {
        if useCache, let hit = followCache[screenName], Date().timeIntervalSince(hit.at) < followCacheTTL {
            return hit.value
        }
        try await ensureXClIdLoaded()
        // v1.1 friendships 系列须走 api.twitter.com(x.com 域名对该端点 401)
        let url = URL(string: "https://api.twitter.com/1.1/friendships/show.json")!
        let me = await MainActor.run { AppStore.shared.account?.screenName ?? "" }
        let resp = try await client.request(
            url: url,
            query: ["source_screen_name": me, "target_screen_name": screenName],
            headers: await commonHeaders(method: "GET", path: "/1.1/friendships/show.json")
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any],
              let rel = json["relationship"] as? [String: Any],
              let source = rel["source"] as? [String: Any] else { return false }
        // source.following = 我是否关注 target
        let following = source["following"] as? Bool ?? false
        followCache[screenName] = (following, Date())
        return following
    }

    /// 关注/取关后失效该用户的关系缓存（本方法与 isFollowing 同 actor 串行，无数据竞争）
    private func invalidateFollowCache(_ screenName: String) {
        followCache.removeValue(forKey: screenName)
    }

    /// v1.1 form-urlencoded POST(baseHost 默认 x.com;v1.1 friendships 系列须走 api.twitter.com)
    private func formPost(baseHost: String? = nil, path: String, fields: [String: String]) async throws {
        try await ensureXClIdLoaded()
        let url = URL(string: "https://\(baseHost ?? host)\(path)")!
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        var headers = await commonHeaders(method: "POST", path: path)
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        let resp = try await client.request(
            method: "POST",
            url: url,
            headers: headers,
            body: Data(body.utf8)
        )
        try ensureResponse(resp)
    }

    /// 点赞 / 取消点赞
    func favoriteTweet(id: String) async throws {
        try await mutate(
            path: "/i/api/graphql/lI07N6Otwv1PhnEgXILM7A/FavoriteTweet",
            variables: """
            {"tweet_id":"\(id)"}
            """
        )
    }

    /// 取消点赞（UnfavoriteTweet）
    func unfavoriteTweet(id: String) async throws {
        try await mutate(
            path: "/i/api/graphql/ZYKSe-w7KEslx3JhSIk5LA/UnfavoriteTweet",
            variables: """
            {"tweet_id":"\(id)","dark_request":false}
            """
        )
    }

    /// 转推 / 撤销转推
    func createRetweet(id: String) async throws {
        try await mutate(
            path: "/i/api/graphql/mbRO74GrOvSfRcJnlMapnQ/CreateRetweet",
            variables: """
            {"tweet_id":"\(id)","dark_request":false}
            """
        )
    }

    func deleteRetweet(id: String) async throws {
        try await mutate(
            path: "/i/api/graphql/ZyZigVsNiFO6v1dEks1eWg/DeleteRetweet",
            variables: """
            {"source_tweet_id":"\(id)","dark_request":false}
            """
        )
    }

    /// 书签 / 移除书签
    func createBookmark(id: String) async throws {
        try await mutate(
            path: "/i/api/graphql/aoDbu3RHznuiSkQ9aNM67Q/CreateBookmark",
            variables: """
            {"tweet_id":"\(id)"}
            """
        )
    }

    func deleteBookmark(id: String) async throws {
        try await mutate(
            path: "/i/api/graphql/Wlmlj2-xzyS1GN3a6cj-mQ/DeleteBookmark",
            variables: """
            {"tweet_id":"\(id)"}
            """
        )
    }

    /// TweetDetail 会话时间线的全部推文（focal + 回复）。评论面板用。
    func getTweetReplies(id: String) async throws -> [TwitterPost] {
        try await ensureXClIdLoaded()
        let path = "/i/api/graphql/XMOz5h24KAZ86qKffKTLdQ/TweetDetail"
        let url = URL(string: "https://\(host)\(path)")!
        let variables = Self.encodeJSON([
            "focalTweetId": id,
            "with_rux_injections": true,
            "includePromotedContent": true,
            "withCommunity": true,
            "withQuickPromoteEligibilityTweetFields": true,
            "withBirdwatchNotes": true,
            "withVoice": true,
            "withV2Timeline": true,
        ] as [String: Any]) ?? "{}"
        let resp = try await client.request(
            url: url,
            query: ["variables": variables, "features": Self.tweetDetailFeatures],
            headers: await commonHeaders(method: "GET", path: path)
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else {
            throw TwitterAPIError.parseFailure
        }
        let instructions = Self.path(json, ["data", "threaded_conversation_with_injections_v2", "instructions"]) as? [[String: Any]] ?? []
        // 评论 = 纯文字回复也要 → requireMedia: false
        return Self.extractPostsFromTweetEntries(instructions, requireMedia: false)
    }

    // MARK: - 主页时间线

    /// 主页 For You(推荐)/Following(关注) 时间线
    func getHomeTimeline(mode: HomeTimelineMode, cursor: String? = nil) async throws -> (posts: [TwitterPost], cursor: String?) {
        try await ensureXClIdLoaded()
        let queryId = mode == .forYou ? "7zlnp2TxC044W4C1ZUJMHw" : "0dateTVgvXjpkf7kyBZy0g"
        let opName = mode == .forYou ? "HomeTimeline" : "HomeLatestTimeline"
        let path = "/i/api/graphql/\(queryId)/\(opName)"
        let url = URL(string: "https://\(host)\(path)")!
        var vars: [String: Any] = [
            "count": 20,
            "includePromotedContent": true,
            "latestControlAvailable": true,
            "requestContext": "launch",
        ]
        if let cursor { vars["cursor"] = cursor }
        let variables = Self.encodeJSON(vars) ?? "{}"
        let resp = try await client.request(
            url: url,
            query: [
                "variables": variables,
                "features": Self.tweetDetailFeatures,
            ],
            headers: await commonHeaders(method: "GET", path: path)
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else { throw TwitterAPIError.parseFailure }
        let instructions = Self.path(json, ["data", "home", "home_timeline_urt", "instructions"]) as? [[String: Any]] ?? []
        // requireMedia:false —— 返回全部推文，由展示层区分：
        // 「推文」分段显示全部（含纯文字），「媒体」分段从同一份数据里取有媒体的瀑布流。
        // 若在此过滤，「推文」分段就只剩带媒体的推文，两个分段内容会完全一样。
        let posts = Self.extractPostsFromTweetEntries(instructions, requireMedia: false)
        let bottom = Self.extractBottomCursor(instructions)
        return (posts, bottom)
    }

    // MARK: - 媒体时间线

    /// 上游 UserMedia（queryId cEjpJXA15Ok78yO4TUQPeQ）。
    /// 返回推文数组 + 下一页 cursor（Bottom cursor value），无更多页时 cursor 为 nil。
    func getUserMedias(userId: String, cursor: String? = nil, count: Int = 20, fast: Bool = false) async throws -> (posts: [TwitterPost], cursor: String?) {
        try await ensureXClIdLoaded()
        let path = "/i/api/graphql/cEjpJXA15Ok78yO4TUQPeQ/UserMedia"
        let url = URL(string: "https://\(host)\(path)")!
        // 上游 getUserMedias:variables.cursor = 传入的 cursor(首页为 undefined → 序列化时省略;
        // 翻页时为真实 cursor 字符串)。此前这里硬编码 NSNull() 导致每页都请求第一页,
        // 服务端永远返回相同内容+有效 cursor = 无限加载/无限检索的总根源。
        var variablesDict: [String: Any] = [
            "userId": userId,
            "count": count,
            "includePromotedContent": false,
            "withClientEventToken": false,
            "withBirdwatchNotes": false,
            "withVoice": true,
            "withV2Timeline": true,
        ]
        if let cursor { variablesDict["cursor"] = cursor }
        let variables = Self.encodeJSON(variablesDict) ?? "{}"

        let resp = try await (fast
            ? client.requestFast(url: url, query: [
                "features": Self.userMediaFeatures,
                "variables": variables,
            ], headers: await commonHeaders(method: "GET", path: path))
            : client.request(url: url, query: [
                "features": Self.userMediaFeatures,
                "variables": variables,
            ], headers: await commonHeaders(method: "GET", path: path), maxAttempts: 3))
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else {
            throw TwitterAPIError.parseFailure
        }
        let instructions = Self.path(json, ["data", "user", "result", "timeline_v2", "timeline", "instructions"]) as? [[String: Any]] ?? []
        let posts = Self.extractPostsFromModuleInstructions(instructions)
        // 上游语义:解析出 0 条 → 到底信号(cursor 置 null),防止翻页对着空页空转
        if posts.isEmpty { return ([], nil) }
        let cursor = Self.extractBottomCursor(instructions)
        return (posts, cursor)
    }

    // MARK: - 推文时间线

    /// 上游 UserTweets（queryId 9zyyd1hebl7oNWIPdA8HRw）。
    /// 与 UserMedia 不同：entries 里 tweet-* 是单推文 entry，profile-conversation 是会话模块（其 items 里含多推文）。
    /// requireMedia=false 时不过滤无媒体推文（搜索页「推文时间线」要展示全部推文；爬虫保持 true 只要有媒体的）。
    func getUserTweets(userId: String, cursor: String? = nil, count: Int = 20, requireMedia: Bool = true) async throws -> (posts: [TwitterPost], cursor: String?) {
        try await ensureXClIdLoaded()
        let path = "/i/api/graphql/9zyyd1hebl7oNWIPdA8HRw/UserTweets"
        let url = URL(string: "https://\(host)\(path)")!
        var variablesDict: [String: Any] = [
            "userId": userId,
            "count": count,
            "includePromotedContent": true,
            "withQuickPromoteEligibilityTweetFields": true,
            "withVoice": true,
            "withV2Timeline": true,
        ]
        // 首页省略 cursor 键(上游 JSON.stringify 丢弃 undefined);显式 null 可能被服务端当非法分页态
        if let cursor { variablesDict["cursor"] = cursor }

        let resp = try await client.request(
            url: url,
            query: [
                "features": Self.userTweetsFeatures,
                "variables": Self.encodeJSON(variablesDict) ?? "{}",
            ],
            headers: await commonHeaders(method: "GET", path: path),
            maxAttempts: 3
        )
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else {
            throw TwitterAPIError.parseFailure
        }
        let instructions = Self.path(json, ["data", "user", "result", "timeline_v2", "timeline", "instructions"]) as? [[String: Any]] ?? []
        let posts = Self.extractPostsFromTweetEntries(instructions, requireMedia: requireMedia)
        let cursor = Self.extractBottomCursor(instructions)
        return (posts, cursor)
    }

    // MARK: - JSON 解析（对应上游 ramda path 管线）

    /// UserMedia：上游取第一个 TimelineTimelineModule 的 items（或 TimelineAddToModule 的 moduleItems）。
    /// 此处为上游的超集：额外收集散装 tweet-* 单推文条目——X 偶发返回没有 module 的页
    /// （上游会解析为 0 条导致提前到底），超集保证不漏；同页重复推文按 rest_id 去重。
    static func extractPostsFromModuleInstructions(_ instructions: [[String: Any]]) -> [TwitterPost] {
        var results: [[String: Any]] = []
        var seen = Set<String>()

        func append(_ result: [String: Any]) {
            guard let id = result["rest_id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return }
            results.append(result)
        }

        if let addEntries = instructions.first(where: { $0["type"] as? String == "TimelineAddEntries" }),
           let entries = addEntries["entries"] as? [[String: Any]] {
            if let module = entries.first(where: { (($0["content"] as? [String: Any])?["entryType"] as? String) == "TimelineTimelineModule" }),
               let items = (module["content"] as? [String: Any])?["items"] as? [[String: Any]] {
                for item in items {
                    if let result = Self.path(item, ["item", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                        append(Self.unwrapVisibility(result))
                    }
                }
            }
            for entry in entries {
                guard (entry["entryId"] as? String ?? "").hasPrefix("tweet") else { continue }
                if let result = Self.path(entry, ["content", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                    append(Self.unwrapVisibility(result))
                }
            }
        }

        if results.isEmpty,
           let addToModule = instructions.first(where: { $0["type"] as? String == "TimelineAddToModule" }),
           let moduleItems = addToModule["moduleItems"] as? [[String: Any]] {
            for item in moduleItems {
                if let result = Self.path(item, ["item", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                    append(Self.unwrapVisibility(result))
                }
            }
        }

        return results.compactMap(Self.mapTwitterPost)
    }

    /// UserTweets 专用：entryId 以 tweet- 开头取单推文；profile-conversation- 开头取会话内全部推文。
    /// 过滤转推（retweeted_status_result 存在）；requireMedia=false 时不滤无媒体推文（评论面板要纯文字回复）。
    static func extractPostsFromTweetEntries(_ instructions: [[String: Any]], requireMedia: Bool = true) -> [TwitterPost] {
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
            } else if entryId.hasPrefix("profile-conversation") || entryId.hasPrefix("conversationthread") {
                // profile-conversation = UserTweets 会话模块;conversationthread = TweetDetail 回复模块
                if let items = content["items"] as? [[String: Any]] {
                    for item in items {
                        if let result = Self.path(item, ["item", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                            rawResults.append(Self.unwrapVisibility(result))
                        }
                    }
                }
            }
        }

        var filtered = rawResults
            .filter { !Self.hasPath($0, ["legacy", "retweeted_status_result"]) }
        if requireMedia {
            filtered = filtered.filter { Self.hasPath($0, ["legacy", "entities", "media"]) }
        }
        return filtered.compactMap(Self.mapTwitterPost)
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
        // 用户字段:legacy 与新版 core 双结构逐字段回退(新版 legacy 里 name/screen_name 缺失,在 core.core)
        let userLegacy = coreUser?["legacy"] as? [String: Any]
        let newUserCore = coreUser?["core"] as? [String: Any]
        let avatarField = (coreUser?["avatar"] as? [String: Any])?["image_url"] as? String
            ?? ((coreUser?["profile_image_url_https"] as? String))
        let legacyAvatar = userLegacy?["profile_image_url_https"] as? String
            ?? ((newUserCore?["avatar"] as? [String: Any])?["url"] as? String)
        let entities = legacy["entities"] as? [String: Any] ?? [:]

        // 长推文全文在 note_tweet.note_text;full_text 尾部 t.co 短链剥离
        var fullText = (item["note_tweet"] as? [String: Any])?["note_text"] as? String
            ?? legacy["full_text"] as? String
            ?? ""
        if !fullText.isEmpty {
            // 剥离末尾媒体/链接 t.co 短链(X 对媒体链接必然附加在文末)
            if let mediaEntities = entities["media"] as? [[String: Any]] {
                for m in mediaEntities {
                    if let url = m["url"] as? String { fullText = fullText.replacingOccurrences(of: url, with: "") }
                }
            }
            if let urls = ((entities["urls"] as? [String: Any])?["urls"] as? [[String: Any]]) {
                for u in urls {
                    if let url = u["url"] as? String, let expanded = u["expanded_url"] as? String {
                        // 普通 t.co 链接替换为原文链接;媒体链接直接剥
                        fullText = fullText.replacingOccurrences(of: url, with: expanded)
                    }
                }
            }
            fullText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return TwitterPost(
            id: item["rest_id"] as? String ?? "",
            user: TwitterUser(
                screenName: userLegacy?["screen_name"] as? String
                    ?? newUserCore?["screen_name"] as? String ?? "",
                avatar: legacyAvatar ?? avatarField ?? "",
                name: userLegacy?["name"] as? String ?? newUserCore?["name"] as? String ?? "",
                id: coreUser?["rest_id"] as? String ?? "",
                mediaCount: userLegacy?["media_count"] as? Int
                    ?? (coreUser?["tweet_counts"] as? [String: Any])?["media_tweets"] as? Int,
                registerTime: TwitterDate.parse(userLegacy?["created_at"] as? String
                    ?? newUserCore?["created_at"] as? String)
            ),
            createdAt: TwitterDate.parse(legacy["created_at"] as? String),
            fullText: fullText.isEmpty ? nil : fullText,
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
            medias: Self.mapTwitterMedias(entities["media"] as? [[String: Any]], createdAt: TwitterDate.parse(legacy["created_at"] as? String))
        )
    }

    static func mapTwitterMedias(_ medias: [[String: Any]]?, createdAt: Date? = nil) -> [TwitterMedia]? {
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
                    type: .photo, videoInfo: nil, createdTime: createdAt
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
                    ),
                    createdTime: createdAt
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
                    ),
                    createdTime: createdAt
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

// MARK: - 推文时间显示

extension Date {
    /// 推文/媒体卡片统一时间样式：含年份（yyyy年M月d日 / Sep 16, 2026）。
    /// 跟随 `L10n.language`（应用内三语切换），而非系统语言——项目 UI 语言由设置驱动，
    /// 两者可能不一致，此处显式对齐避免中英混排。
    var postDisplayText: String {
        let locale: Locale = {
            switch L10n.language {
            case .en: return Locale(identifier: "en_US")
            case .zhHant: return Locale(identifier: "zh_Hant")
            default: return Locale(identifier: "zh_Hans")
            }
        }()
        return formatted(.dateTime.year().month().day().locale(locale))
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


/// 主页时间线模式
enum HomeTimelineMode: String, CaseIterable, Sendable {
    case forYou      // 推荐(HomeTimeline)
    case following   // 关注(HomeLatestTimeline)
}
