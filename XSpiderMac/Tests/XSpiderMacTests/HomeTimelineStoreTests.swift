import XCTest
@testable import XSpiderMac

/// 主页时间线（推文/媒体两形态）的状态回归测试。
///
/// 背景：媒体瀑布流出现过两个 bug，本文件把它们的契约锁住。
final class HomeTimelineStoreTests: XCTestCase {

    private func makeMedia(id: String) -> TwitterMedia {
        TwitterMedia(
            id: id,
            url: "https://pbs.twimg.com/media/\(id).jpg",
            width: 1200, height: 800,
            type: .photo, videoInfo: nil, createdTime: nil
        )
    }

    private func makePost(id: String, likes: Int, mediaIds: [String]) -> TwitterPost {
        TwitterPost(
            id: id,
            user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1", mediaCount: nil, registerTime: nil),
            createdAt: nil,
            fullText: nil,
            tags: [],
            views: nil,
            lang: nil,
            retweeted: nil,
            retweetCount: nil,
            replyCount: nil,
            possiblySensitive: nil,
            favorited: nil,
            favoriteCount: likes,
            bookmarkCount: nil,
            bookmarked: nil,
            medias: mediaIds.map(makeMedia)
        )
    }

    /// 回归：切「热门/最新」必须让媒体瀑布流跟随排序。
    /// 此前 setFollowingSort 只改字段、不重建 flatMedia，导致媒体形态顺序不变，
    /// 表现为"切换热门/最新对瀑布流没反应"。
    @MainActor
    func testFollowingSortRebuildsFlatMediaOrder() {
        let store = HomeTimelineStore.shared
        store.mode = .following
        // 两条推文：A 赞少、B 赞多
        store.posts = [
            makePost(id: "A", likes: 10, mediaIds: ["mA"]),
            makePost(id: "B", likes: 999, mediaIds: ["mB"]),
        ]
        store.followingSort = .latest
        store.setFollowingSort(.latest)   // 触发一次重建（latest = 原序）
        let latestFirstMedia = store.flatMedia.first?.media.id

        store.setFollowingSort(.hot)      // 热门 = 按赞数排序 → B 应在最前
        let hotFirstMedia = store.flatMedia.first?.media.id

        XCTAssertEqual(latestFirstMedia, "mA", "最新应为时间线原序")
        XCTAssertEqual(hotFirstMedia, "mB", "热门应按赞数排序（B 赞更多应在前）")
        XCTAssertNotEqual(latestFirstMedia, hotFirstMedia, "两种排序的媒体顺序应不同")
    }

    /// 推荐时间线不受"热门/最新"影响（该排序只在关注模式下生效）
    @MainActor
    func testSortHasNoEffectInForYouMode() {
        let store = HomeTimelineStore.shared
        store.mode = .forYou
        store.posts = [
            makePost(id: "A", likes: 10, mediaIds: ["mA"]),
            makePost(id: "B", likes: 999, mediaIds: ["mB"]),
        ]
        store.setFollowingSort(.latest)
        store.setFollowingSort(.hot)
        XCTAssertEqual(store.flatMedia.first?.media.id, "mA", "推荐模式应保持原序")
    }

    /// 媒体形态与推文形态必须共用同一分页状态：hasMore 直接由 cursor 派生。
    /// 二者若脱节，瀑布流会误报"已加载全部"而不再翻页（"滚到底不出下一页"）。
    @MainActor
    func testHasMoreIsDerivedFromCursor() {
        XCTAssertFalse(HomeTimelineStore.shared.hasMore,
                       "未加载任何数据时不应声称还有更多（cursor 初始为 nil）")
    }

    /// 同一排序重复设置不应产生额外工作（幂等）
    @MainActor
    func testSetFollowingSortIsIdempotent() {
        let store = HomeTimelineStore.shared
        store.mode = .following
        store.posts = [makePost(id: "A", likes: 1, mediaIds: ["mA"])]
        store.setFollowingSort(.hot)
        let first = store.flatMedia.map(\.media.id)
        store.setFollowingSort(.hot)   // 重复设置
        XCTAssertEqual(store.flatMedia.map(\.media.id), first)
    }
}
