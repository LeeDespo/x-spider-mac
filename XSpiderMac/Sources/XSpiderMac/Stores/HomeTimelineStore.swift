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
