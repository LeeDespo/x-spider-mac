import Foundation
import SwiftUI

/// 同步清单条目
struct SyncUser: Codable, Identifiable, Equatable, Sendable {
    var screenName: String
    var name: String
    var avatar: String

    var id: String { screenName }
}

/// 同步状态机：idle（等待）→ syncing（同步中）→ done（完成）→ idle…
/// syncing 时点击 = 意外中断（取消）→ 显示 interrupted，下次点击回 idle
enum SyncPhase: Equatable, Sendable {
    case idle
    case syncing
    case done
    case interrupted

    var label: String {
        switch self {
        case .idle: return L("等待同步")
        case .syncing: return L("同步中…")
        case .done: return L("完成同步")
        case .interrupted: return L("意外中断")
        }
    }

    var buttonHint: String {
        switch self {
        case .idle, .interrupted: return L("开始同步")
        case .syncing: return L("暂停")
        case .done: return L("再次同步")
        }
    }
}

@Observable
@MainActor
final class SyncStore {
    static let shared = SyncStore()

    /// 同步清单（持久化；可观察——删除/添加实时驱动蜂窝重排动画）
    private(set) var users: [SyncUser] = [] {
        didSet { persistUsers() }
    }

    var phase: SyncPhase = .idle
    /// 当前正在同步的用户下标（-1 = 无）
    var currentUserIndex: Int = -1
    /// 当前正在同步的用户 screenName（单用户同步时定位单元格）
    var currentUser: String?
    /// 同步完成的用户（头像右上角打勾；下次同步开始时清空）
    var completedUsers: Set<String> = []
    /// 每用户状态文本（如 "新任务 3，跳过 12"）
    var userMessages: [String: String] = [:]
    var autoSyncOnLaunch: Bool {
        get { SettingsStore.shared.settings.autoSyncOnLaunchEnabled }
        set { SettingsStore.shared.settings.sync.autoSyncOnLaunch = newValue }
    }
    private(set) var syncTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "sync.users"),
           let list = try? JSONDecoder().decode([SyncUser].self, from: data) {
            users = list
        }
    }

    func persistUsers() {
        if let data = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(data, forKey: "sync.users")
        }
    }

    // MARK: - 清单管理

    /// 输入框添加：支持中英文逗号分隔多个用户名
    func addUsers(fromInput input: String) -> Int {
        let parts = input
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
            .filter { !$0.isEmpty }
        var added = 0
        for sn in parts {
            let lowered = sn.lowercased()
            guard !users.contains(where: { $0.screenName.lowercased() == lowered }) else { continue }
            // 名称/头像：先查下载历史，再查 TwitterAPI（异步补全）
            if let known = DownloadStore.shared.knownUsers.first(where: { $0.screenName.lowercased() == lowered }) {
                users.append(SyncUser(screenName: known.screenName, name: known.name, avatar: known.avatar))
            } else {
                users.append(SyncUser(screenName: sn, name: sn, avatar: ""))
                Task { await resolveUserInfo(screenName: sn) }
            }
            added += 1
        }
        return added
    }

    /// 异步补全用户昵称头像
    private func resolveUserInfo(screenName: String) async {
        guard let user = try? await TwitterAPI.shared.getUser(screenName: screenName) else { return }
        if let idx = users.firstIndex(where: { $0.screenName.lowercased() == screenName.lowercased() }) {
            users[idx].name = user.name
            users[idx].avatar = user.avatar
        }
    }

    func removeUser(_ screenName: String) {
        users.removeAll { $0.screenName == screenName }
        userMessages.removeValue(forKey: screenName)
    }

    // MARK: - 同步执行

    func startSync(target: [SyncUser]? = nil) {
        guard phase != .syncing else { return }
        let list = target ?? users
        guard !list.isEmpty else { return }
        phase = .syncing
        userMessages = [:]
        completedUsers = []
        syncTask = Task { [weak self] in
            await self?.runSync(list)
        }
    }

    /// 同步中点击圆形按钮 = 中断
    func interrupt() {
        guard phase == .syncing else { return }
        syncTask?.cancel()
        syncTask = nil
        phase = .interrupted
        currentUserIndex = -1
        currentUser = nil
    }

    /// done/interrupted 状态点击 → 回到 idle 可再次同步
    func resetPhase() {
        phase = .idle
        currentUserIndex = -1
        currentUser = nil
    }

    /// 圆形按钮动作分发
    func primaryAction() {
        switch phase {
        case .idle: startSync()
        case .syncing: interrupt()
        case .done, .interrupted: resetPhase()
        }
    }

    private func runSync(_ target: [SyncUser]) async {
        for user in target {
            if Task.isCancelled { return }
            currentUserIndex = users.firstIndex(where: { $0.screenName == user.screenName }) ?? -1
            currentUser = user.screenName
            do {
                guard let info = try? await TwitterAPI.shared.getUser(screenName: user.screenName), !info.id.isEmpty else {
                    userMessages[user.screenName] = L("用户不存在")
                    continue
                }
                var newTasks = 0
                var skipped = 0
                var cursor: String? = nil
                let maxPages = 5
                var page = 0
                repeat {
                    if Task.isCancelled { return }
                    let (posts, next) = try await TwitterAPI.shared.getUserMedias(userId: info.id, cursor: cursor)
                    for post in posts {
                        for media in post.medias ?? [] {
                            if DownloadStore.shared.hasDownloaded(media: media, dir: DownloadStore.shared.targetDir(for: post)) {
                                skipped += 1
                            } else {
                                if await DownloadStore.shared.createDownloadTask(post: post, media: media) != nil {
                                    newTasks += 1
                                } else {
                                    skipped += 1
                                }
                            }
                        }
                    }
                    cursor = next
                    page += 1
                } while cursor != nil && page < maxPages
                userMessages[user.screenName] = L("新任务 ") + "\(newTasks)" + L("，跳过 ") + "\(skipped)"
                if !Task.isCancelled { completedUsers.insert(user.screenName) }
            } catch {
                userMessages[user.screenName] = error.localizedDescription
            }
        }
        if !Task.isCancelled {
            currentUserIndex = -1
            currentUser = nil
            phase = .done
        }
    }

    /// 打开应用自动同步（设置开关）
    func syncOnLaunchIfNeeded() {
        guard autoSyncOnLaunch, phase == .idle, !users.isEmpty else { return }
        startSync()
    }
}
