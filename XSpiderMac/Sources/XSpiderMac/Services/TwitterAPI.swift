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

    // MARK: - 单条推文（TweetDetail，用于推文链接搜索）

    /// 上游 op XMOz5h24KAZ86qKffKTLdQ/TweetDetail。返回 focal 推文（含媒体）。
    func getTweet(id: String) async throws -> TwitterPost {
        let (json, _) = try await fetchTweetDetail(focalId: id)
        // TweetDetail 的响应结构（2026-09 实测）：
        //   只有 `data.threaded_conversation_with_injections_v2.instructions`，
        //   **没有** `data.tweetResult`（旧假设，曾导致 focal 推文取不到）。
        //   focal 推文是 entries 里 entryId 为 `tweet-<id>` 的那一条。
        //
        // 若直接用带 requireMedia 的解析（旧行为），**无媒体的 focal 会被过滤掉**，
        // 于是退化分支返回"第一条有媒体的推文"——那往往是评论区的广告或带图评论，
        // 表现为"详情弹出来的是别人的推文"。因此这里必须按 ID 直接取 focal。
        guard let focal = Self.extractFocalTweet(json: json, id: id) else {
            throw TwitterAPIError.parseFailure
        }
        return focal
    }

    /// 从 TweetDetail 响应里按 ID 取出 focal 推文。
    ///
    /// 不经过 `extractPostsFromTweetEntries`：那条路径会按 `requireMedia` 过滤，
    /// 无媒体的 focal 会被丢弃，进而退化到评论区的推文（真实 bug）。
    static func extractFocalTweet(json: [String: Any], id: String) -> TwitterPost? {
        // 路径一（当前线上）：threaded_conversation_with_injections_v2
        let instructions = (Self.path(json, ["data", "threaded_conversation_with_injections_v2", "instructions"]) as? [[String: Any]])
            // 路径二（部分版本）：data.tweetResult.result.timeline.instructions
            ?? (Self.path(json, ["data", "tweetResult", "result", "timeline", "instructions"]) as? [[String: Any]])
            ?? []
        guard let addEntries = instructions.first(where: { $0["type"] as? String == "TimelineAddEntries" }),
              let entries = addEntries["entries"] as? [[String: Any]] else { return nil }

        // 优先按 entryId `tweet-<id>` 精确命中
        if let entry = entries.first(where: { ($0["entryId"] as? String) == "tweet-\(id)" }),
           let result = Self.path(entry, ["content", "itemContent", "tweet_results", "result"]) as? [String: Any] {
            return Self.mapTwitterPost(Self.unwrapVisibility(result))
        }
        // 退路：任意 tweet- 开头条目中 rest_id 匹配者（顺序可能变化）
        for entry in entries where (entry["entryId"] as? String)?.hasPrefix("tweet") == true {
            if let result = Self.path(entry, ["content", "itemContent", "tweet_results", "result"]) as? [String: Any],
               (Self.unwrapVisibility(result)["rest_id"] as? String) == id {
                return Self.mapTwitterPost(Self.unwrapVisibility(result))
            }
        }
        return nil
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

    /// 一次 TweetDetail 请求同时拿到 focal 推文与回复树。
    ///
    /// **详情卡只用这一个入口**：TweetDetail 是重端点，分别取 focal 与回复会把
    /// 同一个请求（同样的 focalTweetId、同样的 features）打两遍，白白翻倍消耗
    /// X 配额——项目一直在对抗 429，这种重复请求是实打实的放大器。
    func getTweetDetailTree(id: String) async throws -> (focal: TwitterPost, replies: [ReplyNode]) {
        let (json, instructions) = try await fetchTweetDetail(focalId: id)
        guard let focal = Self.extractFocalTweet(json: json, id: id) else {
            throw TwitterAPIError.parseFailure
        }
        let replies = Self.extractReplyNodes(instructions, focalId: id)
        return (focal, replies)
    }

    /// TweetDetail 单次请求 → (原始 JSON, instructions)。
    /// 两处 TweetDetail 调用（getTweet / getTweetDetailTree）曾各自拼接 variables，
    /// 容易漂移；统一到这里，改动只需一处。
    private func fetchTweetDetail(focalId: String) async throws -> ([String: Any], [[String: Any]]) {
        try await ensureXClIdLoaded()
        let path = "/i/api/graphql/XMOz5h24KAZ86qKffKTLdQ/TweetDetail"
        let url = URL(string: "https://\(host)\(path)")!
        let variables = Self.encodeJSON([
            "focalTweetId": focalId,
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
        let instructions = (Self.path(json, ["data", "threaded_conversation_with_injections_v2", "instructions"]) as? [[String: Any]])
            ?? (Self.path(json, ["data", "tweetResult", "result", "timeline", "instructions"]) as? [[String: Any]])
            ?? []
        return (json, instructions)
    }

    // MARK: - 搜索时间线（SearchTimeline：服务端按时间范围过滤）

    /// 搜索端点对应的展示形态（对应网页的 `f=media` / `f=live`）。
    enum SearchProduct: String, Sendable {
        case media  = "Media"    // 网页 f=media
        case latest = "Latest"   // 网页 f=live
    }

    /// 把 UI 的时间范围 + 数据源翻译成 X 搜索语法。
    ///
    /// **`until:` 是排他的**（X 语义：`until:2026-09-01` 不含 9 月 1 日当天）。
    /// 用户界面的"至"是**含当日**的直觉，所以这里用 `inclusiveEnd`（当天 23:59:59）
    /// 再 +1 天，得到次日日期——否则用户会发现"至"那天永远没有内容。
    ///
    /// **必须按本地日历取日期**：`DatePicker` 给的 `end` 是**本地**当天零点，
    /// 若用 UTC 格式化，在东八区会得到一个"前一天"的日期字符串，
    /// 导致范围整体偏移一天（实测：本地 2025-08-31 → UTC 写成 2025-08-30）。
    ///
    /// `filter:media` 对应媒体数据源：让服务端只返回带媒体的推文，
    /// 比拉回来再本地筛更省配额。
    static func searchRawQuery(screenName: String, range: DownloadFilter.DateRange,
                               includeMediaOnly: Bool) -> String {
        let since = Self.searchDateString(range.start)
        // 「至」当天要包含 → until 取**次日**（X 的 until 排他）。
        // 注意不能用 inclusiveEnd(+1)：inclusiveEnd 已经是"当天 23:59:59"，
        // 再加一天会变成后天，把范围多算一天（实测踩过）。
        let until = Self.searchDateString(Self.nextDay(range.end))
        var q = "from:\(screenName) since:\(since) until:\(until)"
        if includeMediaOnly { q += " filter:media" }
        return q
    }

    /// 次日（按本地日历，处理跨月/跨年）
    static func nextDay(_ date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
    }

    /// 日期 → `yyyy-MM-dd`（**本地时区**，与 DatePicker 的日历一致）
    static func searchDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// SearchTimeline。**必须 POST + JSON body**——实测：
    ///
    /// | 请求方式 | 结果 |
    /// |---|---|
    /// | GET（带 query string） | **404** |
    /// | POST 表单编码 | **400** |
    /// | **POST + `application/json`** | **200** |
    ///
    /// 这是本次实现最容易踩的坑：**GET 会 404，且与 queryId 无关**——
    /// 实测 openapi 记录的旧 queryId 与当前 bundle 的新 queryId，
    /// 用 POST 都返回 200 与 42 条真实数据；只有随机乱写的才 404。
    /// 我最初用 GET 试，误判成"queryId 失效"并去做了自愈，纯属徒劳。
    /// 网页用的就是 POST。
    func searchTimeline(screenName: String,
                        range: DownloadFilter.DateRange,
                        product: SearchProduct,
                        count: Int = 20,
                        cursor: String? = nil) async throws -> (posts: [TwitterPost], cursor: String?) {
        try await ensureXClIdLoaded()
        var variables: [String: Any] = [
            "rawQuery": Self.searchRawQuery(screenName: screenName, range: range,
                                            includeMediaOnly: product == .media),
            "count": count,
            "querySource": "typed_query",
            "product": product.rawValue,
        ]
        if let cursor { variables["cursor"] = cursor }

        // 首次用默认 queryId；404（可能因 X 改版失效）→ 自愈后重试一次
        do {
            return try await performSearch(variables: variables)
        } catch TwitterAPIError.responseError(let status) where status == 404 {
            AppLogger.warn("SearchTimeline 404,尝试更新 queryId", category: "NET", ["status": "\(status)"])
            guard await SearchQueryIdProvider.shared.refresh(session: client) != nil else { throw TwitterAPIError.parseFailure }
            return try await performSearch(variables: variables)
        }
    }

    /// 实际发请求（POST + JSON）
    private func performSearch(variables: [String: Any]) async throws
        -> (posts: [TwitterPost], cursor: String?) {
        let queryId = await SearchQueryIdProvider.shared.current()
        let path = "/i/api/graphql/\(queryId)/SearchTimeline"
        let url = URL(string: "https://\(host)\(path)")!
        let body = try JSONSerialization.data(withJSONObject: [
            "variables": variables,
            "features": Self.searchTimelineFeatures,
        ])
        var headers = await commonHeaders(method: "POST", path: path)
        headers["Content-Type"] = "application/json"

        let resp = try await client.request(method: "POST", url: url, headers: headers, body: body)
        try ensureResponse(resp)
        guard let json = (try? resp.json()) as? [String: Any] else {
            throw TwitterAPIError.parseFailure
        }
        let instructions = Self.path(json, ["data", "search_by_raw_query",
                                           "search_timeline", "timeline", "instructions"]) as? [[String: Any]] ?? []
        // 搜索结果的条目结构与 UserMedia 一致（TimelineAddEntries + TimelineTimelineModule），
        // 因此直接复用同一套解析——不需要为搜索写第二份。
        let posts = Self.extractPostsFromModuleInstructions(instructions)
        if posts.isEmpty { return ([], nil) }
        return (posts, Self.extractBottomCursor(instructions))
    }

    /// SearchTimeline 的 features（从当前网页 bundle 的 featureSwitches 还原）
    static let searchTimelineFeatures = #"{"rweb_video_screen_enabled":true,"rweb_cashtags_enabled":true,"profile_label_improvements_pcf_label_in_post_enabled":true,"responsive_web_profile_redirect_enabled":false,"rweb_tipjar_consumption_enabled":false,"verified_phone_label_enabled":false,"responsive_web_graphql_timeline_navigation_enabled":true,"creator_subscriptions_tweet_preview_api_enabled":true,"responsive_web_graphql_exclude_directive_enabled":false,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"premium_content_api_read_enabled":false,"communities_web_enable_tweet_community_results_fetch":true,"c9s_tweet_anatomy_moderator_badge_enabled":true,"articles_preview_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":true,"tweet_awards_web_tipping_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":false,"responsive_web_enhance_cards_enabled":false}"#

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
        // includeRetweets: true —— 主页时间线是展示路径，要显示「某某 转推」标签
        let posts = Self.extractPostsFromTweetEntries(instructions, requireMedia: false, includeRetweets: true)
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
    /// - Parameter includeRetweets: 展示路径传 true（要显示「某某 转推」）；
    ///   爬虫路径保持默认 false（转推媒体与原创重复，避免重复下载）。
    func getUserTweets(userId: String, cursor: String? = nil, count: Int = 20,
                       requireMedia: Bool = true, includeRetweets: Bool = false) async throws -> (posts: [TwitterPost], cursor: String?) {
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
        let posts = Self.extractPostsFromTweetEntries(instructions, requireMedia: requireMedia, includeRetweets: includeRetweets)
        let cursor = Self.extractBottomCursor(instructions)
        return (posts, cursor)
    }

    // MARK: - JSON 解析（对应上游 ramda path 管线）

    /// UserMedia：上游取第一个 TimelineTimelineModule 的 items（或 TimelineAddToModule 的 moduleItems）。
    /// 此处为上游的超集：额外收集散装 tweet-* 单推文条目——X 偶发返回没有 module 的页
    /// （上游会解析为 0 条导致提前到底），超集保证不漏；同页重复推文按 rest_id 去重。
    ///
    /// 广告（`itemContent.promotedMetadata`）在此过滤：媒体网格里插广告会让"下载全部"
    /// 把无关媒体的链接也算进去，且卡片数量与媒体数对不上。
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
                    let itemContent = Self.path(item, ["item", "itemContent"]) as? [String: Any]
                    guard !Self.isPromotedItemContent(itemContent) else { continue }
                    if let result = Self.path(item, ["item", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                        append(Self.unwrapVisibility(result))
                    }
                }
            }
            for entry in entries {
                let entryId = entry["entryId"] as? String ?? ""
                guard entryId.hasPrefix("tweet") else { continue }
                guard !Self.isPromotedEntryId(entryId) else { continue }
                let itemContent = Self.path(entry, ["content", "itemContent"]) as? [String: Any]
                guard !Self.isPromotedItemContent(itemContent) else { continue }
                if let result = Self.path(entry, ["content", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                    append(Self.unwrapVisibility(result))
                }
            }
        }

        if results.isEmpty,
           let addToModule = instructions.first(where: { $0["type"] as? String == "TimelineAddToModule" }),
           let moduleItems = addToModule["moduleItems"] as? [[String: Any]] {
            for item in moduleItems {
                let itemContent = Self.path(item, ["item", "itemContent"]) as? [String: Any]
                guard !Self.isPromotedItemContent(itemContent) else { continue }
                if let result = Self.path(item, ["item", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                    append(Self.unwrapVisibility(result))
                }
            }
        }

        return results.compactMap { Self.mapTwitterPost($0) }
    }

    /// UserTweets 专用：entryId 以 tweet- 开头取单推文；profile-conversation- 开头取会话内全部推文。
    /// requireMedia=false 时不滤无媒体推文（评论面板要纯文字回复）。
    ///
    /// - Parameter includeRetweets: 是否保留转推条目。
    ///   **展示路径传 true**（推文时间线要显示「某某 转推」），
    ///   **爬虫/下载路径保持 false**（转推指向的媒体与原创重复，保留会重复下载）。
    ///   默认 false，既有调用方（爬虫）行为不变。
    static func extractPostsFromTweetEntries(_ instructions: [[String: Any]],
                                            requireMedia: Bool = true,
                                            includeRetweets: Bool = false) -> [TwitterPost] {
        var rawResults: [[String: Any]] = []

        guard let addEntries = instructions.first(where: { $0["type"] as? String == "TimelineAddEntries" }),
              let entries = addEntries["entries"] as? [[String: Any]] else { return [] }

        for entry in entries {
            let entryId = entry["entryId"] as? String ?? ""
            let content = entry["content"] as? [String: Any] ?? [:]
            // 推广内容（广告）：entryId 明示或 itemContent.promotedMetadata 非空
            guard !Self.isPromotedEntryId(entryId) else { continue }

            if entryId.hasPrefix("tweet") {
                guard !Self.isPromotedItemContent(Self.path(content, ["itemContent"]) as? [String: Any]) else { continue }
                if let result = Self.path(content, ["itemContent", "tweet_results", "result"]) as? [String: Any] {
                    rawResults.append(Self.unwrapVisibility(result))
                }
            } else if entryId.hasPrefix("profile-conversation") || entryId.hasPrefix("conversationthread") {
                // profile-conversation = UserTweets 会话模块;conversationthread = TweetDetail 回复模块
                if let items = content["items"] as? [[String: Any]] {
                    for item in items {
                        let itemContent = Self.path(item, ["item", "itemContent"]) as? [String: Any]
                        guard !Self.isPromotedItemContent(itemContent) else { continue }
                        if let result = Self.path(item, ["item", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                            rawResults.append(Self.unwrapVisibility(result))
                        }
                    }
                }
            }
        }

        // 转推：按参数保留或过滤。保留时**展平**成"被转发的原推文 + __retweeted_by（转发者）"，
        // 与 X 网页端一致：卡片主体是原作者的正文，顶部标注由谁转推。
        // 展平后正文明细/媒体/作者都来自原推文，后续 requireMedia 等判定自然适用。
        var flattened: [[String: Any]] = []
        for result in rawResults {
            // 注意 X 在不同端点上用了两种包裹键：`retweeted_status_result.result`
            // 与 `retweeted_status_result.tweet`（后者见于部分时间线响应，实测存在）。
            // 只认一种会把另一种当普通推文放行，导致转推混入、媒体重复下载。
            let retweeted = (Self.path(result, ["legacy", "retweeted_status_result", "result"]) as? [String: Any])
                ?? (Self.path(result, ["legacy", "retweeted_status_result", "tweet"]) as? [String: Any])
            if let retweeted {
                guard includeRetweets else { continue }   // 爬虫路径：丢弃转推
                let original = Self.unwrapVisibility(retweeted)
                var merged = original
                // 转发者 = 外层条目的作者；带过去供上层映射为 retweetedBy
                merged["__retweeted_by"] = Self.path(result, ["core", "user_results", "result"])
                flattened.append(merged)
            } else {
                flattened.append(result)
            }
        }

        var filtered = flattened
        if requireMedia {
            filtered = filtered.filter { Self.hasPath($0, ["legacy", "entities", "media"]) }
        }
        return filtered.compactMap { Self.mapTwitterPost($0) }
    }

    /// TweetDetail 会话时间线 → 带层级的回复树（扁平数组，depth 已算好，父先于子）。
    ///
    /// **为什么不能复用 `extractPostsFromTweetEntries`**：那条路径把
    /// `conversationthread-*` 的 items 压平成 `[TwitterPost]`，
    /// `legacy.in_reply_to_status_id_str` 这个**现成的父指针**就此丢失，
    /// 评论区只能平铺。此处保留父指针并算深度。
    ///
    /// 父指针来自响应的 `legacy.in_reply_to_status_id_str`，**不需要额外请求**。
    ///
    /// 孤儿处理（必须）：X 只返回部分会话，父推文可能不在本页。
    /// 这类回复挂到根下并标 `isPartialParent = true`，**绝不丢弃**。
    ///
    /// - Parameter focalId: 根推文 ID（focal）。它的直接回复 depth = 1。
    static func extractReplyNodes(_ instructions: [[String: Any]], focalId: String) -> [ReplyNode] {
        // 1) 收集 raw result + 父指针（ID 与作者名）
        var raw: [(result: [String: Any], parentId: String?, parentScreenName: String?)] = []
        guard let addEntries = instructions.first(where: { $0["type"] as? String == "TimelineAddEntries" }),
              let entries = addEntries["entries"] as? [[String: Any]] else { return [] }

        func collect(itemContent: [String: Any]?) {
            guard !Self.isPromotedItemContent(itemContent) else { return }
            guard let result = Self.path(itemContent ?? [:], ["tweet_results", "result"]) as? [String: Any] else { return }
            let unwrapped = Self.unwrapVisibility(result)
            let legacy = unwrapped["legacy"] as? [String: Any]
            raw.append((unwrapped,
                        legacy?["in_reply_to_status_id_str"] as? String,
                        legacy?["in_reply_to_screen_name"] as? String))
        }

        for entry in entries {
            let entryId = entry["entryId"] as? String ?? ""
            guard !Self.isPromotedEntryId(entryId) else { continue }
            let content = entry["content"] as? [String: Any] ?? [:]
            if entryId.hasPrefix("tweet") {
                collect(itemContent: Self.path(content, ["itemContent"]) as? [String: Any])
            } else if entryId.hasPrefix("conversationthread") || entryId.hasPrefix("profile-conversation") {
                for item in (content["items"] as? [[String: Any]]) ?? [] {
                    collect(itemContent: Self.path(item, ["item", "itemContent"]) as? [String: Any])
                }
            }
        }

        // 2) 按 rest_id 去重（同一会话模块可能重复出现）。
        // **排除 focal 本身**：返回的是"回复"，focal 是根——它没有父指针，
        // 若留在结果里会被算成 depth 1，与"直接回复"无法区分，渲染时也会重复显示主推文。
        var seenIds = Set<String>()
        var nodes: [(post: TwitterPost, parentId: String?, parentScreenName: String?, depth: Int, partial: Bool)] = []
        for entry in raw {
            guard let post = Self.mapTwitterPost(entry.result), !post.id.isEmpty else { continue }
            guard post.id != focalId else { continue }
            guard seenIds.insert(post.id).inserted else { continue }
            nodes.append((post, entry.parentId, entry.parentScreenName, 1, false))
        }

        // 3) 算深度：迭代解析父链，父不在集合里即视为孤儿（挂根下）
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.post.id, $0) })

        /// 返回 (深度, 是否孤儿, 父作者名)。
        /// 父作者名优先用响应里自带的 `in_reply_to_screen_name`（无需查父节点），
        /// 缺失时才从父节点的 post.user 取。
        func resolve(_ id: String, _ visiting: inout Set<String>) -> (depth: Int, partial: Bool, parentScreenName: String?)? {
            guard let node = byId[id] else { return nil }
            // 环保护：异常数据里自引用/互引用会死循环
            guard visiting.insert(id).inserted else { return (1, true, node.parentScreenName) }
            defer { visiting.remove(id) }
            guard let parentId = node.parentId, !parentId.isEmpty, parentId != focalId else {
                return (1, false, node.parentScreenName)   // 直接回复 focal（或顶层）
            }
            guard let parent = resolve(parentId, &visiting) else {
                return (1, true, node.parentScreenName)    // 父不在本页 → 孤儿
            }
            // 父在本页时，优先用父节点的作者名（响应里若没带 in_reply_to_screen_name）
            let parentAuthor = node.parentScreenName ?? byId[parentId]?.post.user.screenName
            return (parent.depth + 1, parent.partial, parentAuthor)
        }

        var result: [ReplyNode] = []
        for node in nodes {
            var visiting = Set<String>()
            let resolved = resolve(node.post.id, &visiting) ?? (1, false, node.parentScreenName)
            result.append(ReplyNode(post: node.post,
                                    parentId: node.parentId,
                                    parentScreenName: resolved.parentScreenName,
                                    depth: resolved.depth,
                                    isPartialParent: resolved.partial))
        }
        // 4) 父先于子输出，父在前保证缩进渲染顺序自然
        return result.sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            let lt = lhs.post.createdAt ?? .distantPast
            let rt = rhs.post.createdAt ?? .distantPast
            if lt != rt { return lt < rt }
            return lhs.post.id < rhs.post.id
        }
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

    // MARK: - 推广内容（广告）过滤

    /// 该条 `itemContent` 是否为推广内容（广告）。
    ///
    /// 判据来自 X 的 TimelineTweet schema：**`itemContent.promotedMetadata` 非空即为广告**
    /// （见 `.fetch/openapi.yaml` 的 `TimelineTweet.promotedMetadata`）。
    /// 实测广告条目必然带该键，普通推文不含。
    ///
    /// 为什么要过滤：TweetDetail 的会话时间线里会插广告（推广推文），
    /// 主页时间线/用户时间线同样会插。它们会混进评论区与推文卡列表，
    /// 表现为"评论区里出现一条与上下文无关的推文"。
    /// 之前靠 `requireMedia` 之类的媒体过滤偶然挡掉一部分，媒体形态不同就漏。
    ///
    /// 额外兼容：少数响应把 `promotedMetadata` 放在 `tweet_results.result` 内层，
    /// 或把 `entryId` 直接写成 `promoted-*`（见 `isPromotedEntryId`）。
    static func isPromotedItemContent(_ itemContent: [String: Any]?) -> Bool {
        guard let itemContent else { return false }
        if let meta = itemContent["promotedMetadata"] as? [String: Any], !meta.isEmpty { return true }
        if let result = Self.path(itemContent, ["tweet_results", "result"]) as? [String: Any],
           let meta = result["promotedMetadata"] as? [String: Any], !meta.isEmpty {
            return true
        }
        return false
    }

    /// 条目 ID 是否明示为推广（部分时间线用 `promoted-*` 作 entryId）
    static func isPromotedEntryId(_ entryId: String) -> Bool {
        entryId.hasPrefix("promoted")
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

    /// - Parameter includeQuoted: 是否解析被引用的推文。递归时**必须**传 false ——
    ///   X 不允许"引用里再引用"，真出现嵌套即为异常数据；不设防会无限递归。
    static func mapTwitterPost(_ item: [String: Any], includeQuoted: Bool = true) -> TwitterPost? {
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
            medias: Self.mapTwitterMedias(entities["media"] as? [[String: Any]], createdAt: TwitterDate.parse(legacy["created_at"] as? String)),
            quotedPost: includeQuoted ? Self.mapQuotedPost(item) : nil,
            // 转推的转发者：由 extractPostsFromTweetEntries 在展平时塞入（内部键，非 X 字段）
            retweetedBy: (item["__retweeted_by"] as? [String: Any]).flatMap(Self.mapTwitterUser)
        )
    }

    /// 解析被引用的推文。
    ///
    /// **路径已用真实响应核对**（TweetDetail，2026-09 实测）：
    /// 引用位于 `result.quoted_status_result.result` —— 是 `result` 的**直接**子键，
    /// **不是** `result.legacy.quoted_status_result`。
    /// 后者是常见误写，会导致引用永远解析不到（表现为引用卡空白）。
    /// `legacy.is_quote_status` 为 true 时该键必然存在，可作校验。
    ///
    /// 递归一层即止：内层显式传 `includeQuoted: false`。
    static func mapQuotedPost(_ item: [String: Any]) -> QuotedPostBox? {
        let raw = (item["quoted_status_result"] as? [String: Any])
            ?? (Self.path(item, ["legacy", "quoted_status_result"]) as? [String: Any])
        guard let raw else { return nil }
        // 兼容两种包裹：{result: {...}} 与直接就是 tweet 对象
        let inner = (raw["result"] as? [String: Any]) ?? (raw["tweet"] as? [String: Any]) ?? raw
        // TweetWithVisibilityResults 包裹时取内层 tweet；内层禁止再取引用（防无限递归）
        return Self.mapTwitterPost(Self.unwrapVisibility(inner), includeQuoted: false).map(QuotedPostBox.init)
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
