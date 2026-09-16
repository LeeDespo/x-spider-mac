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
    /// 跨页去重:X 会话模块可能在相邻页重复出现同一推文
    private var seenPostIds = Set<String>()

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
        cancelFill()
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
            seenPostIds = Set(postList.map(\.id))
            rebuildFlatMediaList()
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

    /// 翻页失败原因（非 nil 时网格底部显示重试入口；成功翻页后清空）
    private(set) var postListError: String?
    /// 视口高度（HomeView 注入）
    private var viewportHeight: CGFloat = 0
    /// 内容底部哨兵在滚动坐标系中的 maxY（HomeView 注入）。
    /// 恒等于上游 InfiniteScroll 的 `scrollHeight - scrollTop`（视口顶到内容底的距离）。
    private var bottomSentinelY: CGFloat = .greatestFiniteMagnitude

    /// 上游 InfiniteScroll 的 shouldContinueRequest：
    /// `scrollHeight - scrollTop <= clientHeight + threshold`；上游 threshold<0 时取 clientHeight，
    /// 故为 `contentBottomY <= viewportHeight * 2`。滚动到底时内容底距视口顶约一个视口高，条件成立。
    ///
    /// - contentBottomY: 内容底部在视口坐标系的 maxY（等价 `scrollHeight - scrollTop`）
    nonisolated static func shouldContinueFilling(contentBottomY: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard viewportHeight > 0, contentBottomY.isFinite else { return false }
        return contentBottomY <= viewportHeight * 2
    }

    private var needsMoreContent: Bool {
        Self.shouldContinueFilling(contentBottomY: bottomSentinelY, viewportHeight: viewportHeight)
    }

    /// 视图上报视口高度（布局变化时调用）；视口就绪后即可评估是否需要补拉
    /// （对应上游 InfiniteScroll 挂载时的 useEffect(onScroll) 首次调用）
    func reportViewport(height: CGFloat) {
        guard height > 0 else { return }
        viewportHeight = height
        triggerFill()
    }

    /// 视图上报内容底部哨兵位置（滚动/内容变化时调用）。到达阈值即触发填充。
    func reportBottomSentinel(y: CGFloat) {
        bottomSentinelY = y
        triggerFill()
    }

    /// 失败后用户点「重试」：清错误态并重新开始填充
    func retryFill() {
        guard fillTask == nil else { return }
        postListError = nil
        triggerFill()
    }

    func loadPostList() async {
        await loadPostList(generation: userGeneration)
    }

    private func loadPostList(generation: Int) async {
        postListLoading = true
        defer { postListLoading = false }

        let userId = userInfo?.id ?? ""
        guard !userId.isEmpty else { return }

        do {
            let (posts, cursor) = try await fetchPage(userId: userId, cursor: nil)
            guard generation == userGeneration else {
                AppLogger.debug("丢弃过期的媒体响应", category: "HOME", ["userId": userId])
                return
            }
            postList = posts
            seenPostIds = Set(posts.map(\.id))
            rebuildFlatMediaList()
            postListCursor = cursor
            postListError = nil
            hasLoadedList = true
            listOwnerScreenName = userInfo?.screenName
            AppLogger.info("媒体时间线已加载", category: "HOME", [
                "source": filter.source.rawValue,
                "screenName": userInfo?.screenName ?? "?",
                "posts": "\(posts.count)",
                "medias": "\(posts.reduce(0) { $0 + ($1.medias?.count ?? 0) })",
                "hasMore": cursor != nil ? "1" : "0",
            ])
            // 首载完成后立即评估是否需补满视口（上游挂载即 onScroll）
            triggerFill()
        } catch is CancellationError {
            // 切用户/退出搜索导致的取消：不是错误，不显示错误态（上游 abort 后静默 return）
            return
        } catch {
            guard generation == userGeneration else { return }
            // 上游 catch:set list: [] + loading:false(已初始化,内容为空)
            hasLoadedList = true
            postListError = error.localizedDescription
            AppLogger.warn("媒体时间线加载失败", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?", "error": error.localizedDescription,
            ])
        }
    }

    /// 按数据源取一页:上游网格只用 UserMedia(source 仅影响下载任务),但 mac 版 UI 承诺了
    /// 「推文时间线」切换语义,这里按 filter.source 路由(对应上游 runCreationTask 的 getListFn)
    private func fetchPage(userId: String, cursor: String?) async throws -> (posts: [TwitterPost], cursor: String?) {
        if filter.source == .tweets {
            // 展示用不过滤无媒体推文(requireMedia:false);下载过滤在创建任务里做
            return try await TwitterAPI.shared.getUserTweets(userId: userId, cursor: cursor, requireMedia: false)
        }
        return try await TwitterAPI.shared.getUserMedias(userId: userId, cursor: cursor)
    }

    /// 上游 InfiniteScroll 的 while 循环。**由 store 持有任务**，不绑定视图生命周期。
    ///
    /// 关键教训：此前视图侧用 `.task(id: postList.count)`（后改 `fillGeneration`）触发，
    /// 而该 id 在每次成功翻页后必然变化 → SwiftUI 取消并重启任务 → 循环每推进一页就被
    /// 自杀，列表停在约 20 帖/~27 媒体；被取消的请求还会走 URLError.cancelled 重试自旋
    /// （实测单毫秒 5400 行重试日志），既卡上限又刷爆限额。
    /// 视图现在只调用 triggerFill() 表达"用户到达底部"，填充循环本身不受重渲染影响。
    private var fillTask: Task<Void, Never>?

    /// 视图在滚动到底部/布局变化时调用（幂等：填充中或已拉满则空转）。
    /// 对应上游 InfiniteScroll 的 onScroll + 挂载即调用一次 useEffect(onScroll)。
    func triggerFill() {
        guard fillTask == nil, hasLoadedList, postListCursor != nil, !postListLoading else { return }
        fillTask = Task { [weak self] in
            guard let self else { return }
            await self.runFillLoop()
            self.fillTask = nil
        }
    }

    /// 停止填充（切换用户/清空搜索时调用）
    func cancelFill() {
        fillTask?.cancel()
        fillTask = nil
    }

    /// 上游 InfiniteScroll：内容底部离视口下沿不足一屏时连续补拉，直到拉满/到底/失败即停。
    /// 绝不无上限爬到服务端尽头（429 风暴根源）。
    private func runFillLoop() async {
        while postListCursor != nil, !Task.isCancelled {
            // 上游 shouldContinueRequest：内容已足够则停，等用户滚动再次触底
            if !needsMoreContent { return }
            let ok = await loadMorePostList()
            // 请求失败(网络/限流/取消)：停止本轮，底部按状态显示重试或错误
            if !ok { return }
            // 页间节流，防 429 风暴（上游靠浏览器渲染节奏，此处显式等价）
            if postListCursor != nil {
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                } catch {
                    return
                }
            }
        }
    }

    /// 上游 loadMorePostList:guard 未初始化/加载中/无 cursor;成功后 concat + cursor 原样更新。
    /// 返回 Bool 表示本轮是否成功(失败时 runFillLoop 停止本轮)。
    @discardableResult
    func loadMorePostList() async -> Bool {
        // 上游三连 guard:未初始化列表 / 已正在加载 / 没有更多数据
        guard hasLoadedList, postListLoading == false, postListCursor != nil else { return false }
        postListLoading = true
        defer { postListLoading = false }

        let userId = userInfo?.id ?? ""
        guard !userId.isEmpty else { return false }

        do {
            let r = try await fetchPage(userId: userId, cursor: postListCursor)
            // 上游: (postList.list || []).concat(twitterPosts) + cursor 原样更新;
            // 附加跨页去重(上游无,但 X 会话模块可能在相邻页重复出现同一推文)
            let fresh = r.posts.filter { seenPostIds.insert($0.id).inserted }
            postList += fresh
            rebuildFlatMediaList()
            postListCursor = r.cursor
            postListError = nil
            AppLogger.info("媒体时间线翻页", category: "HOME", [
                "source": filter.source.rawValue,
                "screenName": userInfo?.screenName ?? "?",
                "posts": "\(fresh.count)",
                "nextHasMore": r.cursor != nil ? "1" : "0",
            ])
            return true
        } catch is CancellationError {
            // 取消（切用户/清空）不是错误：静默停止本轮，不写错误态
            AppLogger.debug("媒体时间线翻页已取消", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?",
            ])
            return false
        } catch {
            postListError = error.localizedDescription
            AppLogger.warn("媒体时间线翻页失败", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?", "error": error.localizedDescription,
            ])
            return false
        }
    }

    /// 清空搜索状态回到主页时间线
    func clearSearch() {
        userGeneration += 1
        cancelFill()
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
        postListError = nil
        seenPostIds = []
        flatMediaList = []
    }

    // MARK: - 筛选（上游 DownloadController：日期/类型/来源）

    func setFilter(_ filter: DownloadFilter) {
        let sourceChanged = filter.source != self.filter.source
        self.filter = filter
        // 数据源切换后重载列表(媒体时间线/推文时间线内容不同)
        if sourceChanged, userInfo != nil {
            cancelFill()
            clearPostList()
            Task { await loadPostList() }
        }
    }

    // MARK: - 展示用的媒体平面列表（上游 PostListGridView mediaList 计算）

    /// [(post, media, index)]：媒体索引为该推文内第几张（MEDIA_INDEX 模板变量用）。
    /// 存储属性:ForEach 每帧多次访问,计算属性会在每次 body 求值时重复 flatMap。
    private(set) var flatMediaList: [(post: TwitterPost, media: TwitterMedia, index: Int)] = []

    private func rebuildFlatMediaList() {
        flatMediaList = postList.flatMap { post in
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
