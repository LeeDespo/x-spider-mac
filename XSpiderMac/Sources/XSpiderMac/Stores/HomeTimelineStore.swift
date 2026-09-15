import Foundation
import SwiftUI

/// 主页时间线状态：推荐 / 关注（热门·最新），分页加载与去重
@MainActor
@Observable
final class HomeTimelineStore {
    static let shared = HomeTimelineStore()

    var mode: HomeTimelineMode = .forYou
    var followingSort: FollowingSort = .hot
    var posts: [TwitterPost] = []
    var loading = false
    var loadingMore = false
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
            self.cursor = next
        } catch {
            AppLogger.warn("主页时间线翻页失败", category: "HOME", ["error": error.localizedDescription])
        }
    }
}

enum FollowingSort: String, CaseIterable, Sendable {
    case hot
    case latest
}
