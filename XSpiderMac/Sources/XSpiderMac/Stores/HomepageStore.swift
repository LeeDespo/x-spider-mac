import Foundation

/// 上游 stores/homepage.ts 的移植：搜索关键词、用户信息、媒体列表（无限滚动）、筛选器。
/// 全部状态放 store 而非 @State —— 修复"切换页面丢输入"的问题。
@Observable
@MainActor
final class HomepageStore {
    static let shared = HomepageStore()

    var keyword: String = ""
    var filter: DownloadFilter = DownloadFilter(
        mediaTypes: [.photo, .video, .gif],
        source: .medias
    )

    var userInfo: TwitterUser?
    var userInfoLoading = false

    var postList: [TwitterPost] = []
    var postListLoading = false
    /// 上游 postList.list 的 undefined 语义:首载完成前置 false(guard 未初始化列表)
    private(set) var hasLoadedList = false
    var postListCursor: String? = nil

    private var loadUserTask: Task<Void, Never>?
    private var loadPostListTask: Task<Void, Never>?
    /// 请求代际：每次 loadUser/loadPostList 自增，晚到的旧响应（ Generation < 当前）直接丢弃。
    /// 修复：快速从用户 A 切到 B 时，A 的 UserMedia 响应晚到覆盖 B 的列表。
    private var userGeneration = 0
    /// 当前列表归属的 screen_name（视图判断网格属于哪个用户）
    private(set) var listOwnerScreenName: String?

    // MARK: - 用户加载（上游 loadUser：abort 旧请求 → getUser → 成功后加载媒体）

    func loadUser(screenName: String) async {
        let sn = screenName.trimmingCharacters(in: .whitespaces)
        guard !sn.isEmpty else { return }

        keyword = sn
        userGeneration += 1
        let generation = userGeneration
        userInfoLoading = true
        userInfo = nil
        clearPostList()
        listOwnerScreenName = nil
        tweetSearchMode = false

        loadUserTask?.cancel()

        do {
            let user = try await TwitterAPI.shared.getUser(screenName: sn)
            guard generation == userGeneration else { return } // 旧请求晚到，丢弃
            userInfoLoading = false
            userInfo = user
            AppStore.shared.addSearchHistory(sn, displayName: user.name, avatarURL: user.avatar)
            // 「自动加载媒体」关闭时只显示用户卡 + 下载配置，省流量
            if SettingsStore.shared.settings.autoLoadMediaEnabled {
                await loadPostList(generation: generation)
            }
        } catch {
            guard generation == userGeneration else { return }
            userInfoLoading = false
            if error is CancellationError { return }
            AppLogger.warn("用户加载失败", category: "HOME", [
                "screenName": sn, "error": error.localizedDescription,
            ])
            throwError(error)
        }
    }

    /// 手动加载/重新加载媒体时间线（开关开启或用户点「加载媒体」）
    func loadMediaNow() async {
        guard userInfo != nil else { return }
        await loadPostList()
    }

    // MARK: - 推文搜索（x.com/<user>/status/<id> 链接或纯数字 ID）

    /// 当前展示模式：false = 用户时间线；true = 推文搜索结果（UI 不套用用户搜索布局）
    var tweetSearchMode = false

    /// 从输入中提取推文 ID：完整链接（含 ?query 后缀）、纯数字 ID
    static func extractTweetID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }), trimmed.count >= 10 {
            return trimmed
        }
        if let range = trimmed.range(of: "status(?:es)?/([0-9]{10,})", options: .regularExpression) {
            let seg = trimmed[range]
            if let id = seg.split(separator: "/").last {
                return String(id)
            }
        }
        return nil
    }

    /// 只获取推文(不入页面状态)——搜索推文直接弹详情卡用
    func fetchTweet(tweetID: String) async -> TwitterPost? {
        do {
            return try await TwitterAPI.shared.getTweet(id: tweetID)
        } catch {
            lastError = L("推文加载失败")
            return nil
        }
    }

    /// 搜索指定推文的媒体
    func loadTweet(tweetID: String) async {
        userGeneration += 1
        let generation = userGeneration
        tweetSearchMode = true
        userInfo = nil
        userInfoLoading = false
        clearPostList()
        listOwnerScreenName = nil

        postListLoading = true
        defer { postListLoading = false }

        do {
            let post = try await TwitterAPI.shared.getTweet(id: tweetID)
            guard generation == userGeneration else { return }
            if post.medias?.isEmpty ?? true {
                lastError = L("该推文没有媒体内容")
                postList = []
            } else {
                postList = [post]
            }
            AppLogger.info("推文媒体加载完成", category: "HOME", [
                "tweetId": tweetID, "medias": "\(post.medias?.count ?? 0)",
            ])
            // 记录推文搜索历史：作者 + 媒体缩略图（最多 4 张用于堆叠）
            let thumbs = (post.medias ?? []).compactMap { m -> String? in
                guard var s = m.url else { return nil }
                if s.contains("/media/"), var comps = URLComponents(string: s) {
                    var items = comps.queryItems?.filter { $0.name != "name" } ?? []
                    items.append(URLQueryItem(name: "name", value: "small"))
                    comps.queryItems = items
                    if let u = comps.url { s = u.absoluteString }
                }
                return s
            }
            AppStore.shared.addTweetSearchHistory(
                tweetID: tweetID,
                authorName: post.user.name,
                authorScreenName: post.user.screenName,
                thumbnailURLs: Array(thumbs.prefix(4))
            )
        } catch {
            if error is CancellationError { return }
            guard generation == userGeneration else { return }
            lastError = L("推文加载失败") + ": " + error.localizedDescription
            AppLogger.warn("推文媒体加载失败", category: "HOME", [
                "tweetId": tweetID, "error": error.localizedDescription,
            ])
        }
    }

    // MARK: - 媒体列表（上游 loadPostList / loadMorePostList：cursor 翻页）

    func loadPostList() async {
        await loadPostList(generation: userGeneration)
    }

    private func loadPostList(generation: Int) async {
        postListLoading = true
        defer { postListLoading = false }

        let userId = userInfo?.id ?? ""
        guard !userId.isEmpty else { return }

        do {
            let (posts, cursor) = try await TwitterAPI.shared.getUserMedias(userId: userId)
            guard generation == userGeneration else {
                AppLogger.debug("丢弃过期的媒体响应", category: "HOME", ["userId": userId])
                return
            }
            postList = posts
            postListCursor = cursor
            hasLoadedList = true
            listOwnerScreenName = userInfo?.screenName
            AppLogger.info("媒体时间线已加载", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?",
                "posts": "\(posts.count)",
                "medias": "\(posts.reduce(0) { $0 + ($1.medias?.count ?? 0) })",
                "hasMore": cursor != nil ? "1" : "0",
            ])
        } catch {
            guard generation == userGeneration else { return }
            // 上游 catch:set list: [] + loading:false(已初始化,内容为空)
            hasLoadedList = true
            AppLogger.warn("媒体时间线加载失败", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?", "error": error.localizedDescription,
            ])
        }
    }

    /// 上游 InfiniteScroll(requestFn):单飞行锁;一次触发循环补拉到 cursor 耗尽或失败为止。
    private var isFillingViewport = false
    func fillViewport() async {
        guard !isFillingViewport else { return }
        isFillingViewport = true
        defer { isFillingViewport = false }
        // 上游 InfiniteScroll 的 while:只要服务端还有 cursor 就继续;
        // loadMorePostList 内部的 loading guard 保证单飞行。
        while postListCursor != nil {
            let ok = await loadMorePostList()
            // 请求失败(网络/限流):停止本轮,等下次触发
            if !ok { break }
            // 页间节流,防 429 风暴(上游靠浏览器渲染节奏,此处显式等价)
            if postListCursor != nil {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    /// 上游 loadMorePostList:guard 未初始化/加载中/无 cursor;成功后 concat + cursor 更新。
    /// 返回 Bool 表示本轮是否成功(失败时 fillViewport 停止)。
    @discardableResult
    func loadMorePostList() async -> Bool {
        // 上游三连 guard:未初始化列表 / 已正在加载 / 没有更多数据
        guard hasLoadedList, postListLoading == false, postListCursor != nil else { return false }
        postListLoading = true
        defer { postListLoading = false }

        let userId = userInfo?.id ?? ""
        guard !userId.isEmpty else { return false }

        do {
            let r = try await TwitterAPI.shared.getUserMedias(userId: userId, cursor: postListCursor)
            // 上游: (postList.list || []).concat(twitterPosts) + cursor 原样更新
            postList += r.posts
            postListCursor = r.cursor
            AppLogger.info("媒体时间线翻页", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?",
                "posts": "\(r.posts.count)",
                "nextHasMore": r.cursor != nil ? "1" : "0",
            ])
            return true
        } catch {
            AppLogger.warn("媒体时间线翻页失败", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?", "error": error.localizedDescription,
            ])
            return false
        }
    }

    /// 清空搜索状态回到主页时间线
    func clearSearch() {
        userGeneration += 1
        userInfo = nil
        userInfoLoading = false
        tweetSearchMode = false
        clearPostList()
        listOwnerScreenName = nil
    }

    func clearPostList() {
        hasLoadedList = false
        postList = []
        postListCursor = nil
    }

    // MARK: - 筛选（上游 DownloadController：日期/类型/来源）

    func setFilter(_ filter: DownloadFilter) {
        let sourceChanged = filter.source != self.filter.source
        self.filter = filter
        // 数据源切换后重载列表(媒体时间线/推文时间线内容不同)
        if sourceChanged, userInfo != nil {
            Task { await loadPostList() }
        }
    }

    // MARK: - 展示用的媒体平面列表（上游 PostListGridView mediaList 计算）

    /// [(post, media, index)]：媒体索引为该推文内第几张（MEDIA_INDEX 模板变量用）
    var flatMediaList: [(post: TwitterPost, media: TwitterMedia, index: Int)] {
        postList.flatMap { post in
            (post.medias ?? []).enumerated().map { (index, media) in
                (post, media, index + 1)
            }
        }
    }

    private func throwError(_ error: Error) {
        lastError = error.localizedDescription
    }

    var lastError: String?
}
