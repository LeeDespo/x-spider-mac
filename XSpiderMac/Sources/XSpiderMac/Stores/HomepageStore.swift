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
            AppStore.shared.addSearchHistory(sn)
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
            listOwnerScreenName = userInfo?.screenName
            AppLogger.info("媒体时间线已加载", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?",
                "posts": "\(posts.count)",
                "medias": "\(posts.reduce(0) { $0 + ($1.medias?.count ?? 0) })",
                "hasMore": cursor != nil ? "1" : "0",
            ])
        } catch {
            guard generation == userGeneration else { return }
            AppLogger.warn("媒体时间线加载失败", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?", "error": error.localizedDescription,
            ])
        }
    }

    func loadMorePostList() async {
        guard let cursor = postListCursor, !postListLoading else { return }
        postListLoading = true
        defer { postListLoading = false }

        let userId = userInfo?.id ?? ""
        let generation = userGeneration
        guard !userId.isEmpty else { return }

        do {
            let (posts, nextCursor): ([TwitterPost], String?)
            if filter.source == .medias {
                let r = try await TwitterAPI.shared.getUserMedias(userId: userId, cursor: cursor)
                posts = r.posts
                nextCursor = r.cursor
            } else {
                let r = try await TwitterAPI.shared.getUserTweets(userId: userId, cursor: cursor)
                posts = r.posts
                nextCursor = r.cursor
            }
            guard generation == userGeneration else {
                AppLogger.debug("丢弃过期的翻页响应", category: "HOME", ["userId": userId])
                return
            }
            // 按推文 ID 去重：Twitter 偶发返回重复页；重复内容会导致无限加载
            let existing = Set(postList.map(\.id))
            let fresh = posts.filter { !existing.contains($0.id) }
            if posts.isEmpty || (fresh.isEmpty && nextCursor == cursor) {
                // 服务端没给新内容也不给新 cursor → 到底了，停止翻页
                postListCursor = nil
                AppLogger.info("媒体时间线已到底", category: "HOME", ["screenName": userInfo?.screenName ?? "?"])
                return
            }
            postList.append(contentsOf: fresh)
            postListCursor = nextCursor != cursor ? nextCursor : nil
            AppLogger.debug("媒体时间线追加翻页", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?",
                "posts": "\(posts.count)",
                "total": "\(postList.count)",
            ])
        } catch {
            guard generation == userGeneration else { return }
            AppLogger.warn("媒体时间线翻页失败", category: "HOME", [
                "screenName": userInfo?.screenName ?? "?", "error": error.localizedDescription,
            ])
        }
    }

    func clearPostList() {
        postList = []
        postListCursor = nil
    }

    // MARK: - 筛选（上游 DownloadController：日期/类型/来源）

    func setFilter(_ filter: DownloadFilter) {
        self.filter = filter
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
