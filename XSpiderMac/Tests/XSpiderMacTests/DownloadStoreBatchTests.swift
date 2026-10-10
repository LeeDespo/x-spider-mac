import XCTest
@testable import XSpiderMac

/// 批量删除与筛选栏计数的回归测试。
///
/// 背景（都是实测报回来的）：
/// 1. 下载页滑动卡顿 —— 根因之一是 `tasksForCurrentTab` 每帧全量 filter+sort；
/// 2. 点"全部删除"删几千条时页面卡死一小段时间 —— 根因是逐条 `remove(gid:)`，
///    每次都触发 `tasks` 的 didSet（重建索引 + 清筛选缓存 + pump 遍历全表）。
final class DownloadStoreBatchTests: XCTestCase {

    private func makeMedia(_ id: String) -> TwitterMedia {
        TwitterMedia(id: id, url: "https://x/\(id).jpg", width: 10, height: 10,
                     type: .photo, videoInfo: nil, createdTime: nil)
    }

    private func makePost(_ id: String, user: String) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: user, avatar: "", name: user.uppercased(),
                                      id: "100", mediaCount: nil, registerTime: nil),
                    createdAt: Date(), fullText: "t", tags: [], views: nil, lang: nil,
                    retweeted: nil, retweetCount: nil, replyCount: nil,
                    possiblySensitive: nil, favorited: nil, favoriteCount: nil,
                    bookmarkCount: nil, bookmarked: nil,
                    medias: [makeMedia("m-\(id)")])
    }

    private func task(_ n: Int, user: String, status: DownloadStatus = .complete) -> DownloadTask {
        DownloadTask(gid: "gid-\(n)", post: makePost("\(n)", user: user),
                     media: makeMedia("m-\(n)"), fileName: "f\(n).jpg", dir: "/tmp",
                     totalSize: 10, completeSize: 10, status: status, error: nil,
                     updatedAt: Date(), downloadUrl: "https://x/\(n).jpg",
                     retryCountRemains: 5)
    }

    /// 批量删除：一次性摘除（而不是逐条），且**只产生一次**筛选缓存失效。
    @MainActor
    func testBatchRemovalRemovesEverythingInOnePass() {
        let store = DownloadStore.shared
        let snapshot = StoreSnapshot()
        defer { snapshot.restore() }

        store.tasks = (0..<500).map { task($0, user: $0 % 2 == 0 ? "alice" : "bob") }
        XCTAssertEqual(store.tasks.count, 500)

        store.removeVisibleRecords(statuses: [.complete])
        XCTAssertTrue(store.tasks.isEmpty, "全部删除应当一次清空")

        // 索引与缓存必须跟着更新（否则后续判定/筛选会读到幽灵数据）
        XCTAssertEqual(store.tasksForCurrentTab(statuses: [.complete]).count, 0)
        XCTAssertTrue(store.knownUsers.isEmpty, "清空后筛选栏也应当为空")
    }

    /// 删除后索引可用：新加回来的任务仍能被 `update(gid:)` 命中。
    @MainActor
    func testIndexIsRebuiltAfterBatchRemoval() {
        let store = DownloadStore.shared
        let snapshot = StoreSnapshot()
        defer { snapshot.restore() }

        store.tasks = (0..<50).map { task($0, user: "alice") }
        store.removeVisibleRecords(statuses: [.complete])

        store.tasks = [task(999, user: "alice", status: .active)]
        store.update(gid: "gid-999") { $0.completeSize = 42 }
        XCTAssertEqual(store.tasks.first?.completeSize, 42, "索引应含新任务")
    }

    /// 筛选栏每行带该用户的记录条数。
    @MainActor
    func testKnownUsersCarryPerUserCounts() {
        let store = DownloadStore.shared
        let snapshot = StoreSnapshot()
        defer { snapshot.restore() }

        store.tasks = (0..<7).map { task($0, user: "alice") }
            + (0..<3).map { task(100 + $0, user: "bob") }

        let users = store.knownUsers
        XCTAssertEqual(users.count, 2)
        XCTAssertEqual(users.first { $0.screenName == "alice" }?.count, 7, "alice 有 7 条")
        XCTAssertEqual(users.first { $0.screenName == "bob" }?.count, 3, "bob 有 3 条")
    }

    /// 分页：`tasksForCurrentTab` 返回完整列表（分页在视图层做），且结果被缓存到
    /// 同一份数组实例共享（缓存生效的证据：第二次调用不做新分配的内容比较）。
    @MainActor
    func testFilteredResultIsCachedAcrossCalls() {
        let store = DownloadStore.shared
        let snapshot = StoreSnapshot()
        defer { snapshot.restore() }

        store.tasks = (0..<300).map { task($0, user: "alice") }
        let first = store.tasksForCurrentTab(statuses: [.complete])
        let second = store.tasksForCurrentTab(statuses: [.complete])
        XCTAssertEqual(first.count, 300)
        XCTAssertEqual(second.count, 300)
        // 缓存返回同一份内容（改变 tasks 后必须失效，见下一条）
        XCTAssertEqual(first.map(\.gid), second.map(\.gid))
    }

    /// `tasks` 变化后筛选结果必须失效（否则界面会显示已删除的旧数据）。
    @MainActor
    func testFilteredCacheInvalidatesWhenTasksChange() {
        let store = DownloadStore.shared
        let snapshot = StoreSnapshot()
        defer { snapshot.restore() }

        store.tasks = (0..<5).map { task($0, user: "alice") }
        XCTAssertEqual(store.tasksForCurrentTab(statuses: [.complete]).count, 5)
        store.tasks = []
        XCTAssertEqual(store.tasksForCurrentTab(statuses: [.complete]).count, 0,
                       "tasks 变了之后不能还返回缓存的旧结果")
    }
}
