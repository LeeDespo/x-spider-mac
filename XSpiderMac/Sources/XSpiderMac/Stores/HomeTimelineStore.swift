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
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "home.timelineMode") }
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
            // 媒体瀑布流跟随排序重建（放 didSet 而非仅在 setter 里，
            // 这样任何改写路径都生效，不会因为"值没变"而漏掉重建）
            if oldValue != followingSort { rebuildFlatMedia() }
        }
    }
    var posts: [TwitterPost] = [] {
        // 媒体瀑布流由 posts 派生：放 didSet 保证任何赋值路径都会同步重建，
        // 不会因为某处忘记调用 rebuildFlatMedia 而出现"切换形态后数据不更新"
        didSet { rebuildFlatMedia() }
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

    /// 排序后的可见帖子（热门 = 按赞数排序；最新 = 时间线原序）
    var visiblePosts: [TwitterPost] {
        guard mode == .following, followingSort == .hot else { return posts }
        return posts.sorted { ($0.favoriteCount ?? 0) > ($1.favoriteCount ?? 0) }
    }

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
            posts = newPosts          // didSet 已重建 flatMedia
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
            posts.append(contentsOf: fresh)   // didSet 已重建 flatMedia
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

    /// 重建媒体瀑布流数据。
    /// 必须跟随 `visiblePosts`（含"热门"按赞数排序）——否则切到媒体形态时顺序与推文形态不一致，
    /// 表现为"切换热门/最新对媒体流没反应"。
    private func rebuildFlatMedia() {
        flatMedia = visiblePosts.flatMap { post in
            (post.medias ?? []).enumerated().map { (index, media) in
                (post, media, index + 1)
            }
        }
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
