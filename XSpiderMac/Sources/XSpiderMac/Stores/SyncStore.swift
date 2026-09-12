import Foundation
import AppKit

/// 同步页状态：选择若干用户 → 一键拉取各自媒体时间线并入队下载（跳过已下载）。
@MainActor
final class SyncStore: ObservableObject {
    struct TargetUser: Identifiable, Hashable {
        let screenName: String
        let name: String
        let avatar: String
        var id: String { screenName }
    }

    struct UserProgress: Identifiable {
        let screenName: String
        var status: Status = .pending
        var fetchedPosts = 0
        var enqueued = 0
        var skipped = 0
        var message: String?
        var id: String { screenName }

        enum Status { case pending, loading, done, failed }
    }

    @Published var selected: Set<String> = []
    @Published var progress: [UserProgress] = []
    @Published var running = false
    /// 每个用户最多回溯多少页（20 条/页）
    @Published var maxPages: Int = 5 {
        didSet { UserDefaults.standard.set(maxPages, forKey: "sync.maxPages") }
    }

    init() {
        maxPages = UserDefaults.standard.object(forKey: "sync.maxPages") as? Int ?? 5
    }

    // MARK: - 候选用户（下载历史里出现过的账号 + 主页看过的账号）

    var candidateUsers: [TargetUser] {
        var byName: [String: TargetUser] = [:]
        for user in DownloadStore.shared.knownUsers {
            byName[user.screenName] = TargetUser(screenName: user.screenName, name: user.name, avatar: user.avatar)
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    func toggle(_ user: TargetUser) {
        if selected.contains(user.screenName) {
            selected.remove(user.screenName)
        } else {
            selected.insert(user.screenName)
        }
    }

    // MARK: - 同步执行

    func startSync() async {
        guard !running, !selected.isEmpty else { return }
        running = true
        defer { running = false }

        let targets = candidateUsers.filter { selected.contains($0.screenName) }
        progress = targets.map { UserProgress(screenName: $0.screenName, status: .pending) }

        for target in targets {
            await syncUser(target)
        }
    }

    private func syncUser(_ target: TargetUser) async {
        updateProgress(target.screenName) { $0.status = .loading }

        do {
            // 用户 ID：优先用已知历史的 post.user.id；否则现查
            let userId = try await resolveUserId(target)

            var cursor: String? = nil
            var enqueued = 0
            var skipped = 0
            var pages = 0

            while pages < max(maxPages, 1) {
                let (posts, next) = try await TwitterAPI.shared.getUserMedias(userId: userId, cursor: cursor, count: 20)
                pages += 1

                var pageMedias: [(post: TwitterPost, media: TwitterMedia)] = []
                for post in posts {
                    for media in post.medias ?? [] {
                        if DownloadStore.shared.hasDownloaded(media: media, dir: DownloadStore.shared.targetDir(for: post)) {
                            skipped += 1
                        } else {
                            pageMedias.append((post, media))
                        }
                    }
                }
                enqueued += pageMedias.count
                if !pageMedias.isEmpty {
                    await DownloadStore.shared.batchCreateDownloadTasks(pageMedias)
                }
                updateProgress(target.screenName) {
                    $0.fetchedPosts += posts.count
                    $0.enqueued = enqueued
                    $0.skipped = skipped
                }

                guard let next, pages < maxPages else { break }
                cursor = next
            }

            updateProgress(target.screenName) {
                $0.status = .done
                $0.message = L("新任务 ") + "\(enqueued)" + L("，跳过 ") + "\(skipped)"
            }
            AppLogger.info("同步完成", category: "SYNC", [
                "user": target.screenName, "enqueued": "\(enqueued)", "skipped": "\(skipped)", "pages": "\(pages)",
            ])
        } catch is CancellationError {
            updateProgress(target.screenName) { $0.status = .failed; $0.message = L("已取消") }
        } catch {
            updateProgress(target.screenName) {
                $0.status = .failed
                $0.message = error.localizedDescription
            }
            AppLogger.warn("同步失败", category: "SYNC", ["user": target.screenName, "error": error.localizedDescription])
        }
    }

    /// 从下载历史找该用户的 post.user.id；找不到再调 getUser
    private func resolveUserId(_ target: TargetUser) async throws -> String {
        if let known = DownloadStore.shared.tasks.first(where: { $0.post.user.screenName == target.screenName })?.post.user.id,
           !known.isEmpty {
            return known
        }
        let user = try await TwitterAPI.shared.getUser(screenName: target.screenName)
        return user.id
    }

    private func updateProgress(_ screenName: String, _ mutation: (inout UserProgress) -> Void) {
        if let idx = progress.firstIndex(where: { $0.screenName == screenName }) {
            mutation(&progress[idx])
        }
    }
}
