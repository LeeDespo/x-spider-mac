import Foundation
import SwiftUI

/// 主页时间线状态：推荐 / 关注（热门·最新），分页加载与去重
@MainActor
@Observable
final class HomeTimelineStore {
    static let shared = HomeTimelineStore()

    /// 分段选择持久化:重启后回到上次的 推荐/关注 与 热门/最新。
    ///
    /// 必须是**存储属性**（而非 UserDefaults 计算属性）：`@Observable` 只追踪存储属性，
    /// 计算属性读写 UserDefaults 不会触发视图失效 —— 曾导致分段切换要等下一次翻页
    /// 数据到达才顺带刷新（表现为"切换要等很久"）。持久化改在 didSet 里做。
    var mode: HomeTimelineMode = HomeTimelineMode(
        rawValue: UserDefaults.standard.string(forKey: "home.timelineMode") ?? ""
    ) ?? .forYou {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "home.timelineMode")
            // 换数据源：冻结顺序必须作废（reload 会用新首屏重建），
            // 否则短暂窗口内会拿旧顺序渲染新数据
            if oldValue != mode { hotOrder = [] }
        }
    }
    /// 展示形态：推文卡片 / 纯媒体瀑布流（同上：存储属性保证切换即时生效）
    var contentType: HomeTimelineContentType = HomeTimelineContentType(
        rawValue: UserDefaults.standard.string(forKey: "home.timelineContent") ?? ""
    ) ?? .tweets {
        didSet { UserDefaults.standard.set(contentType.rawValue, forKey: "home.timelineContent") }
    }
    var followingSort: FollowingSort = FollowingSort(
        rawValue: UserDefaults.standard.string(forKey: "home.followingSort") ?? ""
    ) ?? .hot {
        didSet {
            UserDefaults.standard.set(followingSort.rawValue, forKey: "home.followingSort")
            // 用户主动切排序 → **整体重排**（明确的用户意图，跳位是预期）
            if oldValue != followingSort { reorderForCurrentSort() }
        }
    }
    /// 帖子列表（时间线原始顺序 = 按页累积，不排序）。
    /// 它是所有派生展示顺序的唯一真源；排序在 `displayPosts` 里做。
    var posts: [TwitterPost] = [] {
        didSet { rebuildDerived() }
    }
    /// 加载失败原因（非 nil 时视图显示"加载失败 + 重试"）。
    /// 此前失败只写日志、不设状态 → 用户看到的是无限转圈（"加载到永远"）。
    private(set) var loadError: String?
    var loading = false
    var loadingMore = false
    /// 展平后的媒体列表（媒体瀑布流用）。getHomeTimeline 只返回有媒体的推文，
    /// 因此无需额外请求即可切换形态 —— 不额外消耗 X 配额。
    var flatMedia: [(post: TwitterPost, media: TwitterMedia, index: Int)] = []

    /// 是否有更多可加载（媒体瀑布流与推文形态共用同一分页状态）
    var hasMore: Bool { cursor != nil }
    private var cursor: String?

    /// 测试辅助：把分页状态复位（Store 是单例，测试间必须隔离）。
    /// 与 `HomepageStore.clearErrorForTesting` 同类的隔离入口——
    /// 之前缺这个，导致 `testHasMoreIsDerivedFromCursor` 会被其他测试的
    /// 遗留 cursor 污染而偶发失败。
    func resetPagingForTesting() {
        cursor = nil
        posts = []
        loadError = nil
        loading = false
        loadingMore = false
    }
    private var seenIds = Set<String>()
    private var generation = 0

    /// 热门排序**冻结**的展示顺序。
    ///
    /// 为什么需要冻结：热门 = 按赞数降序，而赞数是**新页到达时才补进来的**——
    /// 若每次访问都重排全量，新页里的高赞推文会插到前面，已加载的媒体瞬间跳位
    /// （用户反馈"加载下一页会闪一下、媒体变顺序"）。
    ///
    /// 因此策略是**按页排序、只追加**：
    /// - 首屏/重新加载：对当页排序后作为初始顺序；
    /// - 翻页：新页**只在页内排序**，整页追加到已有顺序之后（已放置的条目不移动）；
    /// - 用户主动切排序：整体重排（那是明确的用户意图，跳位是预期行为）。
    ///
    /// `didSet` 重建派生数据：否则改了顺序但 flatMedia 仍是旧的（瀑布流不更新）。
    private var hotOrder: [TwitterPost] = [] {
        didSet { rebuildDerived() }
    }

    /// 视图与 flatMedia 共同读取的展示顺序
    var displayPosts: [TwitterPost] {
        guard mode == .following, followingSort == .hot else { return posts }
        // 热门：冻结顺序；若尚未构建（例如外部直接赋值 posts）则按当前数据补齐，
        // 保证 displayPosts 永远不返回空
        return hotOrder.isEmpty && !posts.isEmpty ? sortedByLikesIfHot(posts) : hotOrder
    }

    /// 兼容旧调用名：视图此前用 visiblePosts
    var visiblePosts: [TwitterPost] { displayPosts }

    func setMode(_ m: HomeTimelineMode) {
        guard m != mode else { return }
        mode = m
        // 换数据源（推荐↔关注）内容完全不同，旧浏览进度无意义
        clearAllScrollAnchors()
        Task { await reload() }
    }

    /// 切换热门/最新。
    ///
    /// 语义边界：两者都是同一条"关注"时间线（`HomeLatestTimeline`）的数据，差别只在展示顺序
    /// （热门 = 按赞数排序，最新 = 时间线原序），因此**不需要重新请求**。
    /// 重建 `flatMedia` 由 `followingSort` 的 didSet 负责（见其注释），此处只改值。
    func setFollowingSort(_ s: FollowingSort) {
        followingSort = s
    }

    func initialLoad() async {
        guard posts.isEmpty else { return }
        await reload()
        // 首载偶发空/失败(X 端抖动):间隔 1.5s 自动重试一次
        if posts.isEmpty {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard posts.isEmpty else { return }
            await reload()
        }
    }

    func reload() async {
        generation += 1
        let gen = generation
        loading = true
        loadError = nil          // 新一次加载开始 → 清掉上次的错误提示
        defer { loading = false }
        do {
            let (newPosts, next) = try await TwitterAPI.shared.getHomeTimeline(mode: mode)
            guard gen == generation else { return }
            posts = newPosts
            // 首屏：热门顺序以"当页内排序"为初始值
            hotOrder = sortedByLikesIfHot(newPosts)
            seenIds = Set(newPosts.map(\.id))
            cursor = next
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation else { return }
            // 记录可见的失败状态：否则用户只看到无限转圈，不知道可以重试
            loadError = error.localizedDescription
            AppLogger.warn("主页时间线加载失败", category: "HOME", ["error": error.localizedDescription])
        }
    }

    func loadMore() async {
        guard let cursor, !loadingMore, !loading else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let (newPosts, next) = try await TwitterAPI.shared.getHomeTimeline(mode: mode, cursor: cursor)
            let fresh = newPosts.filter { seenIds.insert($0.id).inserted }
            // 重复/空页:不再续翻(X 偶发返回重复 cursor)
            if fresh.isEmpty || next == nil || next == cursor {
                self.cursor = nil
                return
            }
            posts.append(contentsOf: fresh)
            // 关键：翻页时**只对新页排序并整页追加**，已放置的条目不移动。
            // 若在这里对全量重排，新页的高赞推文会插到前面 → 已加载的媒体跳位（闪烁）。
            appendPageToDisplayOrder(fresh)
            self.cursor = next
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            // 翻页失败也给出可见状态（原先只写日志 → 用户以为"卡住了"）
            loadError = error.localizedDescription
            AppLogger.warn("主页时间线翻页失败", category: "HOME", ["error": error.localizedDescription])
        }
    }

    /// 用户点「重试」：清掉错误并重新加载
    func retry() async {
        loadError = nil
        if posts.isEmpty { await reload() } else { await loadMore() }
    }

    /// 用户点「刷新」：**显式**重新加载（与切页回来时的"自动刷新"相对）。
    ///
    /// 语义：重置到首屏。推荐流每次请求内容都不同，所以刷新后已加载内容会被替换 ——
    /// 这是用户主动要求的，属预期；而切页回来**不应**发生这件事（见 scrollAnchor）。
    func refreshExplicitly() async {
        loadError = nil
        // 内容整体替换 → 旧锚点在数据里已不存在
        clearAllScrollAnchors()
        await reload()
    }

    // MARK: - 浏览进度记忆（下拉位置）

    /// 两种形态各自的滚动锚点：记录"顶部可见的那条"的 ID。
    ///
    /// 为什么存锚点而不是像素偏移：非 lazy 的瀑布流在滚动中会不断加载新内容，
    /// 内容高度持续变化，存绝对 offset 会在恢复时落到错误位置。
    /// 锚点（media/post ID）在数据追加时保持稳定，是唯一可靠的参照。
    ///
    /// 生命周期：**仅进程内**（不落盘）——按需求"重启应用后消失"。
    /// 切换分段会清掉对应锚点（换数据源后旧锚点无意义）。
    ///
    /// `@ObservationIgnored` 是必须的：锚点由视图的 `onAppear` 写入，
    /// 若参与观察则会**触发重渲染 → 探针重建 → onAppear 再写 → 无限循环**
    /// （实测表现为应用启动即挂死、测试 runner 连不上）。
    /// 锚点是记账数据，不驱动任何 UI，本就不该进观察图。
    @ObservationIgnored private var tweetAnchor: String?
    @ObservationIgnored private var mediaAnchor: String?

    /// 媒体瀑布流已渲染条数。
    ///
    /// 必须放在 store 而不是视图 `@State`：`ContentView` 用 `.id(selection)` 驱动切页动画，
    /// 会销毁并重建整个视图 → `@State` 归零。若只恢复滚动锚点而条数回到 40，
    /// 用户原本浏览到第 200 条时锚点尚未渲染，恢复必然失败。
    var mediaRenderedCount = 40

    /// 视图上报当前顶部锚点（滚动停止时调用，节流由视图负责）
    func reportScrollAnchor(_ id: String?, for type: HomeTimelineContentType) {
        switch type {
        case .tweets: tweetAnchor = id
        case .media: mediaAnchor = id
        }
    }

    /// 视图读取待恢复的锚点（取用后不清除：同一次会话内反复切页都应回到同一位置）
    func scrollAnchor(for type: HomeTimelineContentType) -> String? {
        switch type {
        case .tweets: return tweetAnchor
        case .media: return mediaAnchor
        }
    }

    /// 清空某个形态的浏览进度（换数据源时调用——旧锚点在新数据里不存在，
    /// 留着会让恢复逻辑做无意义的查找）
    func clearScrollAnchor(for type: HomeTimelineContentType) {
        switch type {
        case .tweets: tweetAnchor = nil
        case .media: mediaAnchor = nil
        }
    }

    /// 清空全部浏览进度（显式刷新时调用：内容整体替换，旧锚点失效）
    func clearAllScrollAnchors() {
        tweetAnchor = nil
        mediaAnchor = nil
        mediaRenderedCount = 40   // 回到首批，避免刷新后仍展开大量已失效内容
    }

    /// 测试辅助：清空错误态（Store 是单例，测试间需隔离）
    func clearErrorForTesting() {
        loadError = nil
    }

    /// 重建派生数据（flatMedia）。
    /// 数据源：`displayPosts`（热门走冻结顺序、最新走时间线原序）。
    private func rebuildDerived() {
        flatMedia = displayPosts.flatMap { post in
            (post.medias ?? []).enumerated().map { (index, media) in
                (post, media, index + 1)
            }
        }
    }

    /// 热门模式下按赞数排序；非热门模式保持原样
    private func sortedByLikesIfHot(_ list: [TwitterPost]) -> [TwitterPost] {
        guard mode == .following, followingSort == .hot else { return list }
        return list.sorted { ($0.favoriteCount ?? 0) > ($1.favoriteCount ?? 0) }
    }

    /// 用户**主动切换排序**时的整体重排。
    /// 这是明确的用户意图，跳位是预期行为（与"翻页不重排"相对）。
    func reorderForCurrentSort() {
        hotOrder = sortedByLikesIfHot(posts)
        rebuildDerived()
    }

    /// 翻页追加：新页**只在页内排序**，整页追加到已有顺序之后。
    /// 这是"按页冻结"的执行点——翻页路径必须走它，而不是对全量重排。
    /// （供下载/翻页路径与测试调用；内部仍是同一个不变量）
    func appendPageToDisplayOrder(_ page: [TwitterPost]) {
        hotOrder.append(contentsOf: sortedByLikesIfHot(page))
    }
}

/// 主页展示形态
enum HomeTimelineContentType: String, CaseIterable, Sendable {
    case tweets   // 推文卡片（现有样式）
    case media    // 纯媒体瀑布流
}

enum FollowingSort: String, CaseIterable, Sendable {
    case hot
    case latest
}
