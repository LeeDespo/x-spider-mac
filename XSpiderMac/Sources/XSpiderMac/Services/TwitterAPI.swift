import Foundation

/// 组件 facade：应用动作 → 契约调用（`xspider_call`）、契约 JSON → 应用模型。
/// 签名、限流、凭据、重试都在组件 `x-spider-core` 里，外壳不发任何 X 请求。
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

    // MARK: - 爬取（crawl.run）

    /// 跑**一小段**爬取，返回这一段的候选与完整推文。
    ///
    /// 外壳把"跑多长"切成一块块，由调用方用返回的 `next_cursor` 续跑：
    /// `crawl.run` 本身是"跑到停为止再返回"，而外壳要边跑边报进度、
    /// 要能在限流时挂起、还要能被取消——切成小块才有这些机会。
    /// 终止判据（到底 / 时间轴推进 / 连续空页 / 游标未推进）都在组件里，
    /// 调用方只看 `done_reason`。
    func crawlPage(source: DownloadFilter.Source, userId: String, cursor: String?,
                   strategy: [String: JSONValue]) async throws -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "source": .string(source.rawValue),
            "user_id": .string(userId),
            "strategy": .object(strategy),
        ]
        if let cursor, !cursor.isEmpty { params["cursor"] = .string(cursor) }
        return try await componentCall("crawl.run", params)
    }

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
            "since": .string(range.start.searchDateString),
            "until": .string(range.end.searchDateString),
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
