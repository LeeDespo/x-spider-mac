import Foundation

/// 上游 twitter/api.ts 的完整移植。
/// queryId 与 features 必须与上游逐字对齐，否则 X 服务端直接拒绝。
actor TwitterAPI {
    static let shared = TwitterAPI()

    /// 这个 actor 现在是**纯粹的映射层**：把契约的 JSON 变成应用模型，
    /// 把应用的动作变成契约调用。签名、限流、凭据、重试全在组件里——
    /// 外壳里没有任何一条自己发出的 X 请求了（ADR-040）。
    ///
    /// 旧的 HTTP 层（`NetworkClient` / `XClientTransaction` / `RequestGate`）
    /// 已随这次迁移删除。

    /// 非持久状态：由 AppStore 每次 cookie 变更时推送
    /// 非持久状态：由 AppStore 每次 cookie/代理变更时推送。
    ///
    /// 这里只做一件事：**把状态推给组件**。签名（x-client-transaction-id）、限流闸门、
    /// 429 熔断、代理都在组件里，本应用不再自己实现一份——那样才会出现
    /// "两套限流各说各话"（`docs/01-ARCHITECTURE.md` §1 的存在理由）。
    ///
    /// 凭据**只进不出**：组件不回显、不落盘、不打日志；这里也不打。
    func configure(cookie: String, proxy: ProxySettings) async {
        let settings = await MainActor.run { SettingsStore.shared.settings }
        do {
            _ = try await XSpiderComponent.shared.ensureStarted()
            if !cookie.isEmpty {
                _ = try await XSpiderComponent.shared.call("auth.set_cookie", ["cookie": .string(cookie)])
            }
            // 代理三态与组件一致：关闭 → null；跟随系统 → 用系统解析出的 URL；
            // 手填 → 原样。`null` 与"字段缺失"语义不同（契约 §4.3），所以这里显式给。
            _ = try await XSpiderComponent.shared.call("net.set_proxy", ["url": Self.componentProxyValue(proxy)])
            _ = try await XSpiderComponent.shared.call("net.set_limits", [
                "api_rps": .double(max(0.1, Double(settings.gateRequestsPerWindow) / Double(max(1, settings.gateWindowSeconds)))),
                "api_burst": .int(settings.gateRequestsPerWindow),
                "cdn_concurrency": .int(settings.cdnMaxConcurrent),
                "cooldown_s": .int(settings.cdnCooldownSeconds),
            ])
            AppLogger.info("组件已按设置更新", category: "CORE", [
                "proxy": Self.proxyLabel(proxy),
                "api_rps": String(format: "%.1f", Double(settings.gateRequestsPerWindow) / Double(max(1, settings.gateWindowSeconds))),
                "cdn_concurrency": String(settings.cdnMaxConcurrent),
            ])
        } catch {
            // 这里吞掉错误、留给后续调用报：configure 可能在任何时刻被设置改动触发，
            // 而"代理暂时不可达"不该在设置界面弹错误（真要用时会立刻失败并提示）。
            AppLogger.error("组件配置失败", category: "CORE", ["error": error.localizedDescription])
        }
    }

    /// 代理设置的契约取值：`.null` = **明确关闭**，字符串 = 具体代理。
    /// 两者语义不同（契约 §4.3）：字段必须存在，`null` 是"忽略环境变量"。
    static func componentProxyValue(_ proxy: ProxySettings) -> JSONValue {
        if proxy.enable, !proxy.useSystem, !proxy.url.isEmpty { return .string(proxy.url) }
        if proxy.useSystem {
            if let system = SystemProxy.current() { return .string(system) }
            return proxy.url.isEmpty ? .null : .string(proxy.url)
        }
        return .null
    }

    private static func proxyLabel(_ proxy: ProxySettings) -> String {
        if proxy.enable, !proxy.useSystem, !proxy.url.isEmpty { return "手动:\(proxy.url)" }
        if proxy.useSystem { return "系统" }
        return "关闭"
    }

    /// 组件调用 + 错误语义映射。
    ///
    /// 组件报的是**结构化错误码**（契约禁止按文案判断），而应用上层
    /// （`SyncStore.classify`）按 `TwitterAPIError` 的 case 决定给用户什么提示：
    /// "账号不存在" / "登录失效" / "网络问题" 三者的处理完全不同。
    /// 所以这里按**码**翻译，逐条对应。
    private func componentCall(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        do {
            return try await XSpiderComponent.shared.call(method, params)
        } catch {
            throw Self.translate(error)
        }
    }

    static func translate(_ error: Error) -> Error {
        guard let component = error as? XSpiderComponent.ComponentError else { return error }
        switch component.code {
        case "not_found": return TwitterAPIError.userNotFound
        // 带上组件给的原文：141（账号被限制写操作）与"cookie 失效"都是 unauthorized，
        // 但两者的可操作提示不同——按 code 分流，把原因如实带给用户。
        case "unauthorized": return TwitterAPIError.notAuthorized(component.errorDescription ?? "")
        case "parse": return TwitterAPIError.parseFailure
        case "upstream": return TwitterAPIError.responseError(status: component.status ?? 0)
        default: return error
        }
    }

    // MARK: - 单条推文（TweetDetail，用于推文链接搜索）

    /// 上游 op XMOz5h24KAZ86qKffKTLdQ/TweetDetail。返回 focal 推文（含媒体）。
    func getTweet(id: String) async throws -> TwitterPost {
        let result = try await componentCall("fetch.tweet_detail", ["id": .string(id)])
        guard let focalJSON = result[object: "focal"],
              let focal = XSpiderMapping.post(focalJSON) else {
            throw TwitterAPIError.parseFailure
        }
        return focal
    }
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

    /// 账户信息：**由组件回答**（`auth.whoami`）。
    ///
    /// 这一条以前是"每个外壳自己写一遍"的：抓 x.com 首页、正则掏 `screen_name`。
    /// 搬进组件还有个附带好处：**它和签名用的页面抓取走同一条路**，
    /// 不会再各自处理"未登录会 307 到 onboarding"这类细节。
    /// - 传了 `cookieStringOverride` 时**先把它推给组件**再问"我是谁"：顺序反了会拿到
    ///   **上一个账号**的信息（组件里的凭据还是旧的）。切账号的 bug 就出在这里。
    func getAccountInfo(cookieStringOverride: String? = nil, fast: Bool = false) async throws -> TwitterAccountInfo {
        if let override = cookieStringOverride, !override.isEmpty {
            _ = try await componentCall("auth.set_cookie", ["cookie": .string(override)])
        }
        _ = fast
        let result = try await componentCall("auth.whoami")
        guard let account = result[object: "account"],
              let screenName = account[string: "screen_name"], !screenName.isEmpty else {
            throw TwitterAPIError.missingScreenName
        }
        return TwitterAccountInfo(
            screenName: screenName,
            avatar: account[string: "avatar"] ?? "",
            id: account[string: "id"])
    }

    // MARK: - 用户查询

    func getUser(screenName: String, fast: Bool = false) async throws -> TwitterUser {
        let result = try await componentCall("fetch.get_user", ["screen_name": .string(screenName)])
        guard let userJSON = result[object: "user"],
              let user = XSpiderMapping.user(userJSON) else {
            throw TwitterAPIError.userNotFound
        }
        return user
    }


    // MARK: - 推文互动（点赞/转推/书签）

    /// 六条走同一个 method（`fetch.mutate` 的 `action`）：它们的差别只有
    /// "哪个 queryId + 哪几个 variables"，那是组件的实现细节，不该漏进外壳。
    private func mutate(_ action: String, tweetId: String) async throws {
        _ = try await componentCall("fetch.mutate", [
            "action": .string(action), "tweet_id": .string(tweetId),
        ])
    }

    func favoriteTweet(id: String) async throws { try await mutate("favorite", tweetId: id) }
    func unfavoriteTweet(id: String) async throws { try await mutate("unfavorite", tweetId: id) }
    func createRetweet(id: String) async throws { try await mutate("retweet", tweetId: id) }
    func deleteRetweet(id: String) async throws { try await mutate("unretweet", tweetId: id) }
    func createBookmark(id: String) async throws { try await mutate("bookmark", tweetId: id) }
    func deleteBookmark(id: String) async throws { try await mutate("unbookmark", tweetId: id) }

    // MARK: - 媒体 CDN 连通性探测

    /// 探测结果。**按结构区分**，不匹配文案。
    enum CDNProbe: Sendable {
        /// 连得通（服务端没说长度也算通——请求本身成功了）。
        case ok(bytes: Int)
        case rateLimited(retryAfter: Int?)
        case failed(String)
    }

    /// 探一次媒体 CDN（`net.probe_size`，最多产生一个字节的流量）。
    ///
    /// **必须走组件**：它用的是**下载时用的那个代理**。此前这里用 `URLSession.shared`
    /// 直连——那只认系统代理，于是应用里把代理关掉之后，探测器仍然（走系统代理）成功，
    /// 侧边栏的"媒体 CDN"就永远显示正常（用户实测报过这个）。
    /// 现在探测与下载走同一条出口，显示才与事实一致。
    func probeCDN() async -> CDNProbe {
        // 用一个**长期存在**的媒体 URL 作探针：以前用过 /media/xxx 那条实测已 404，
        // 会把正常网络误报成异常。
        let probe = "https://pbs.twimg.com/profile_images/1683325380441128960/yRsRRjGO.jpg"
        do {
            let result = try await XSpiderComponent.shared.call(
                "net.probe_size", ["url": .string(probe)])
            return .ok(bytes: result[int: "size"] ?? 0)
        } catch let error as XSpiderComponent.ComponentError {
            // 只看 code：`rate_limited` 是"CDN 现在不让我下"，与"连不上"是两回事
            if error.code == "rate_limited" { return .rateLimited(retryAfter: error.retryAfterS) }
            return .failed(error.errorDescription ?? "探测失败")
        } catch {
            return .failed(error.localizedDescription)
        }
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
    /// 推文详情树（组件 `fetch.tweet_detail`）：focal + 已算好深度的回复。
    ///
    /// 深度由 `XSpiderMapping` 按 `parent_id` 的父链算——契约给父子关系不给深度，
    /// 那是外壳按同一份数据推出来的（参考实现的树也是在这里构建的）。
    func getTweetDetailTree(id: String) async throws -> (focal: TwitterPost, replies: [ReplyNode]) {
        let result = try await componentCall("fetch.tweet_detail", ["id": .string(id)])
        let parsed = XSpiderMapping.replyNodes(result, focalId: id)
        guard let focal = parsed.focal else { throw TwitterAPIError.parseFailure }
        return (focal, parsed.replies)
    }

    /// 关注态缓存（300s）。组件那边也缓存了"我是谁"，但这条省掉的是**每次 show 请求**：
    /// 同一页里同名作者会重复出现，不缓存就是十几个 1.1 请求（限流的放大器）。
    private var followCache: [String: (value: Bool, at: Date)] = [:]
    private let followCacheTTL: TimeInterval = 300

    /// 关注列表（Following，组件 `fetch.following`）。
    func getFollowing(userId: String, cursor: String? = nil, count: Int = 100) async throws -> (users: [TwitterUser], cursor: String?) {
        var params: [String: JSONValue] = ["user_id": .string(userId), "count": .int(count)]
        if let cursor { params["cursor"] = .string(cursor) }   // 首页**不要**传 cursor（契约 §3.3）
        let result = try await componentCall("fetch.following", params)
        return XSpiderMapping.userPage(result)
    }

    /// 我有没有关注它（组件 `fetch.is_following`）。
    func isFollowing(screenName: String, useCache: Bool = true) async throws -> Bool {
        if useCache, let hit = followCache[screenName], Date().timeIntervalSince(hit.at) < followCacheTTL {
            return hit.value
        }
        let result = try await componentCall("fetch.is_following", ["screen_name": .string(screenName)])
        let following = result[bool: "following"] ?? false
        followCache[screenName] = (following, Date())
        return following
    }

    /// 关注 / 取关（组件 `fetch.mutate`；v1.1 REST 那条路的形状差异在组件里处理）。
    func followUser(screenName: String) async throws {
        _ = try await componentCall("fetch.mutate", [
            "action": .string("follow"), "screen_name": .string(screenName),
        ])
        invalidateFollowCache(screenName)
    }

    func unfollowUser(screenName: String) async throws {
        _ = try await componentCall("fetch.mutate", [
            "action": .string("unfollow"), "screen_name": .string(screenName),
        ])
        invalidateFollowCache(screenName)
    }

    /// 关注/取关后失效该用户的关系缓存（本方法与 isFollowing 同 actor 串行，无数据竞争）
    private func invalidateFollowCache(_ screenName: String) {
        followCache.removeValue(forKey: screenName)
    }

    /// 当前账户 restId（账户信息缺 id 时用 `fetch.get_user` 补查）。
    func currentUserId() async -> String? {
        if let id = await MainActor.run(body: { AppStore.shared.account?.id }), !id.isEmpty { return id }
        guard let sn = await MainActor.run(body: { AppStore.shared.account?.screenName }) else { return nil }
        return (try? await getUser(screenName: sn).id) ?? nil
    }

    /// 用户 result dict → TwitterUser（兼容 legacy 与新版 core 结构）。
    ///
    /// **取数已经不经它**（组件给的是已经归一化的 user）；留着是因为下面那组
    /// 老解析函数（`extractPostsFrom*` / `mapTwitterPost`）仍然被测试覆盖着，
    /// 而它们要它。等那批测试随解析函数一起退役，这里也能删。
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
        // queryId 失效的自愈（404 → 抓 /search 页面找新 queryId）现在在组件里，
        // 锚定 operationName 做匹配；应用侧不再自己维护那份正则。
        var params: [String: JSONValue] = [
            "screen_name": .string(screenName),
            "since": .string(Self.searchDateString(range.start)),
            "until": .string(Self.searchDateString(range.end)),
            // media 产品 = 服务端就按媒体筛（`filter:media`），比取回来再筛省请求也省配额
            "media_only": .bool(product == .media),
            "count": .int(count),
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        let result = try await componentCall("fetch.search_timeline", params)
        return XSpiderMapping.postPage(result)
    }
    // MARK: - 主页时间线

    /// 主页 For You(推荐)/Following(关注) 时间线
    func getHomeTimeline(mode: HomeTimelineMode, cursor: String? = nil) async throws -> (posts: [TwitterPost], cursor: String?) {
        // requireMedia:false / includeRetweets:true —— 返回全部推文，由展示层分段：
        // 「推文」显示全部（含纯文字），「媒体」从同一份数据里取有媒体的（见视图层）。
        // 组件这一侧不筛媒体，与旧行为一致。
        var params: [String: JSONValue] = ["mode": .string(mode == .forYou ? "for_you" : "following")]
        if let cursor { params["cursor"] = .string(cursor) }
        let result = try await componentCall("fetch.home_timeline", params)
        return XSpiderMapping.postPage(result)
    }

    // MARK: - 媒体时间线

    /// 上游 UserMedia（queryId cEjpJXA15Ok78yO4TUQPeQ）。
    /// 返回推文数组 + 下一页 cursor（Bottom cursor value），无更多页时 cursor 为 nil。
    func getUserMedias(userId: String, cursor: String? = nil, count: Int = 20, fast: Bool = false) async throws -> (posts: [TwitterPost], cursor: String?) {
        var params: [String: JSONValue] = ["user_id": .string(userId), "count": .int(count)]
        // 首页省略 cursor 键：显式 null 会被服务端当成非法分页态（踩过的坑，见 git 历史）
        if let cursor { params["cursor"] = .string(cursor) }
        let result = try await componentCall("fetch.user_medias", params)
        let page = XSpiderMapping.postPage(result)
        // 上游语义：解析出 0 条 = 到底信号（cursor 置 nil），防止对着空页空转
        if page.posts.isEmpty { return ([], nil) }
        return page
    }

    // MARK: - 推文时间线

    /// 上游 UserTweets（queryId 9zyyd1hebl7oNWIPdA8HRw）。
    /// 与 UserMedia 不同：entries 里 tweet-* 是单推文 entry，profile-conversation 是会话模块（其 items 里含多推文）。
    /// requireMedia=false 时不过滤无媒体推文（搜索页「推文时间线」要展示全部推文；爬虫保持 true 只要有媒体的）。
    /// - Parameter includeRetweets: 展示路径传 true（要显示「某某 转推」）；
    ///   爬虫路径保持默认 false（转推媒体与原创重复，避免重复下载）。
    func getUserTweets(userId: String, cursor: String? = nil, count: Int = 20,
                       requireMedia: Bool = true, includeRetweets: Bool = false) async throws -> (posts: [TwitterPost], cursor: String?) {
        var params: [String: JSONValue] = [
            "user_id": .string(userId),
            "count": .int(count),
            "require_media": .bool(requireMedia),
            "include_retweets": .bool(includeRetweets),
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        let result = try await componentCall("fetch.user_tweets", params)
        return XSpiderMapping.postPage(result)
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
    /// `unauthorized` 的通称：cookie 失效，或**账号被限制写操作**（上游 141）。
    /// 带原因是为了让界面说人话，而不是统一成一句「响应中找不到 screen_name」。
    case notAuthorized(String)
    case missingAvatar
    case userNotFound
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .responseError(let status): return "响应错误：status=\(status)"
        case .missingScreenName: return "Cookie 无效或未登录：响应中找不到 screen_name"
        case .notAuthorized(let reason):
            return reason.isEmpty ? "当前账号无权执行该操作，请重新登录或换一个账号" : reason
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
