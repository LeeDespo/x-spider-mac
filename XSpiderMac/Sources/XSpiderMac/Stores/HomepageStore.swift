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

    // MARK: - 用户加载（上游 loadUser：abort 旧请求 → getUser → 成功后加载媒体）

    func loadUser(screenName: String) async {
        let sn = screenName.trimmingCharacters(in: .whitespaces)
        guard !sn.isEmpty else { return }

        keyword = sn
        userInfoLoading = true
        userInfo = nil
        clearPostList()

        loadUserTask?.cancel()

        do {
            let user = try await TwitterAPI.shared.getUser(screenName: sn)
            userInfoLoading = false
            userInfo = user
            AppStore.shared.addSearchHistory(sn)
            await loadPostList()
        } catch {
            userInfoLoading = false
            if error is CancellationError { return }
            NSLog("loadUser error: \(error.localizedDescription)")
            throwError(error)
        }
    }

    // MARK: - 媒体列表（上游 loadPostList / loadMorePostList：cursor 翻页）

    func loadPostList() async {
        postListLoading = true
        defer { postListLoading = false }

        let userId = userInfo?.id ?? ""
        guard !userId.isEmpty else { return }

        do {
            let (posts, cursor) = try await TwitterAPI.shared.getUserMedias(userId: userId)
            postList = posts
            postListCursor = cursor
        } catch {
            NSLog("loadPostList error: \(error.localizedDescription)")
        }
    }

    func loadMorePostList() async {
        guard let cursor = postListCursor, !postListLoading else { return }
        postListLoading = true
        defer { postListLoading = false }

        let userId = userInfo?.id ?? ""
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
            postList.append(contentsOf: posts)
            postListCursor = nextCursor
        } catch {
            NSLog("loadMorePostList error: \(error.localizedDescription)")
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
