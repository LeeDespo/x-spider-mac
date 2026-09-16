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
        didSet { UserDefaults.standard.set(followingSort.rawValue, forKey: "home.followingSort") }
    }
    var posts: [TwitterPost] = []
    var loading = false
    var loadingMore = false
    /// 展平后的媒体列表（媒体瀑布流用）。getHomeTimeline 只返回有媒体的推文，
    /// 因此无需额外请求即可切换形态 —— 不额外消耗 X 配额。
    var flatMedia: [(post: TwitterPost, media: TwitterMedia, index: Int)] = []
    private var cursor: String?
    /// 是否还有更多可加载（视图展示"已加载全部"用；不暴露 cursor 本身）
    var hasMore: Bool { cursor != nil }
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
        defer { loading = false }
        do {
            let (newPosts, next) = try await TwitterAPI.shared.getHomeTimeline(mode: mode)
            guard gen == generation else { return }
            posts = newPosts
            seenIds = Set(newPosts.map(\.id))
            cursor = next
            rebuildFlatMedia()
        } catch {
            guard gen == generation else { return }
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
            rebuildFlatMedia()
            self.cursor = next
        } catch {
            AppLogger.warn("主页时间线翻页失败", category: "HOME", ["error": error.localizedDescription])
        }
    }

    /// 重建媒体瀑布流数据（增量语义：只在 posts 变化时调用，不在视图 body 里重算）
    private func rebuildFlatMedia() {
        flatMedia = posts.flatMap { post in
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
