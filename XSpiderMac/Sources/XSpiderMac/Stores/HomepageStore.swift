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
            postList.append(contentsOf: posts)
            postListCursor = nextCursor
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
