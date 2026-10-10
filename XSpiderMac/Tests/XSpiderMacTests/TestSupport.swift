import XCTest
@testable import XSpiderMac

/// 单例**用户数据**的「存档点」：整份存取设置、下载历史与首页时间线的持久化
/// 分段选择，收尾时整体还原。
///
/// 测试宿主是应用本体，这些单例持有用户的真实数据。手写逐字段快照容易漏字段、
/// 新增字段后也会失联；这里整份存取，天然覆盖新字段。
///
/// 用法（`@MainActor` 测试内）：
///
/// ```swift
/// let snapshot = StoreSnapshot()
/// defer { snapshot.restore() }
/// ```
@MainActor
struct StoreSnapshot {
    private let settings: Settings
    private let downloadTasks: [DownloadTask]
    private let homeTimelineMode: HomeTimelineMode
    private let homeTimelineContentType: HomeTimelineContentType
    private let homeFollowingSort: FollowingSort

    init() {
        settings = SettingsStore.shared.settings
        downloadTasks = DownloadStore.shared.tasks
        homeTimelineMode = HomeTimelineStore.shared.mode
        homeTimelineContentType = HomeTimelineStore.shared.contentType
        homeFollowingSort = HomeTimelineStore.shared.followingSort
    }

    func restore() {
        SettingsStore.shared.settings = settings
        DownloadStore.shared.tasks = downloadTasks
        DownloadStore.shared.invalidateJudgements()
        AccountFolder.invalidateIndex()
        // 这三个是持久化的（`home.timelineMode` / `home.timelineContent` /
        // `home.followingSort`）：测试改过它们必须写回，否则会污染用户的分段选择。
        HomeTimelineStore.shared.mode = homeTimelineMode
        HomeTimelineStore.shared.contentType = homeTimelineContentType
        HomeTimelineStore.shared.followingSort = homeFollowingSort
    }
}

/// 复位「会话态」单例：这些不是用户数据，清掉即可。
///
/// 在 `setUp`（必要时 `tearDown`）调用，避免上一用例遗留的状态——分页游标、
/// 查看窗口会话、导航栈、详情缓存、状态灯——干扰本用例。用户数据用
/// `StoreSnapshot`，不要用这里。
@MainActor
enum TestStores {
    static func resetEphemeral() {
        AccountStatusStore.shared.reset()
        MediaViewerCenter.shared.clearSessionForWindowClose()
        NavigationHistory.shared.reset()
        TweetDetailCache.shared.clear()
        HomepageStore.shared.clearPostList()
        HomeTimelineStore.shared.resetPagingForTesting()
    }
}
