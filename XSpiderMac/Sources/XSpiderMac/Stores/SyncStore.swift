import Foundation
import SwiftUI
import AppKit

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
    /// 同步失败的用户 → 失败原因（红字说明；下次同步开始时清空）
    var failedUsers: [String: String] = [:]
    /// 用户「忽略失败」后从失败集合移除（视为完成）
    var ignoredFailures: Set<String> = []
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

    /// 从 TwitterUser 添加(去重)
    func addUser(user: TwitterUser) {
        guard !users.contains(where: { $0.screenName.lowercased() == user.screenName.lowercased() }) else { return }
        users.append(SyncUser(screenName: user.screenName, name: user.name, avatar: user.avatar))
    }

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
        failedUsers.removeValue(forKey: screenName)
        ignoredFailures.remove(screenName)
    }

    /// 忽略某用户的同步失败（视为完成无异常）
    func ignoreFailure(_ screenName: String) {
        failedUsers.removeValue(forKey: screenName)
        ignoredFailures.insert(screenName)
        completedUsers.insert(screenName)
        maybeQuitOnComplete()
    }

    // MARK: - 同步记录文件（syncRecordFile 模式）

    /// 记录条目：某用户最新媒体的年月日 + 当天全部媒体资源索引
    struct SyncRecord: Codable, Sendable {
        var anchorDay: String       // "yyyy-MM-dd"
        var dayIds: [String]
    }

    /// 记录文件路径：保存路径（开启账号子文件夹时按用户拆分）
    private func syncRecordURL(screenName: String) -> URL {
        var dir = SettingsStore.shared.settings.download.saveDirBase
        if dir.isEmpty,
           let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            dir = downloads.path
        }
        if SettingsStore.shared.settings.accountSubfolderEnabled,
           let user = users.first(where: { $0.screenName.lowercased() == screenName.lowercased() }) {
            let folderName = "\(user.name)-@\(user.screenName)".safePathComponent()
            dir = (dir as NSString).appendingPathComponent(folderName)
        }
        return URL(fileURLWithPath: dir).appendingPathComponent(".synced.json")
    }

    static func loadSyncRecord(screenName: String) -> SyncRecord? {
        let shared = SyncStore.shared
        let url = shared.syncRecordURL(screenName: screenName)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONDecoder().decode(SyncRecord.self, from: data) else { return nil }
        return obj
    }

    static func writeSyncRecord(screenName: String, anchorDay: String, dayIds: [String]) {
        let shared = SyncStore.shared
        let url = shared.syncRecordURL(screenName: screenName)
        let rec = SyncRecord(anchorDay: anchorDay, dayIds: dayIds.sorted())
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(atPath: url.deletingLastPathComponent().path,
                                                     withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(rec) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static func dayString(_ date: Date) -> String {
        DateFormatter.fallback.string(from: date)
    }

    static func parseDay(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        return DateFormatter.dayOnly.date(from: s)
    }

    /// 重试失败用户（对失败清单批量再同步）
    func retryFailures() {
        let targets = users.filter { failedUsers.keys.contains($0.screenName) }
        guard !targets.isEmpty else { return }
        startSync(target: targets)
    }

    /// 成功用户数（含被忽略的失败）
    var succeededCount: Int {
        users.filter {
            completedUsers.contains($0.screenName) && failedUsers[$0.screenName] == nil ||
            ignoredFailures.contains($0.screenName)
        }.count
    }

    /// 失败（未忽略）用户数
    var failureCount: Int { failedUsers.count }

    /// 失败用户（给 UI 显示）
    var failedUserList: [SyncUser] {
        users.filter { failedUsers.keys.contains($0.screenName) }
    }

    /// 是否存在未忽略的失败
    var hasFailures: Bool { !failedUsers.isEmpty }

    // MARK: - 同步执行

    func startSync(target: [SyncUser]? = nil) {
        guard phase != .syncing else { return }
        let list = target ?? users
        guard !list.isEmpty else { return }
        phase = .syncing
        userMessages = [:]
        completedUsers = []
        failedUsers = [:]
        ignoredFailures = []
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
                // 单用户总闸 150s：任何未知慢点(密钥加载/分页翻页)兜底快速失败
                let info = try await withTimeout(150) {
                    try await TwitterAPI.shared.getUser(screenName: user.screenName, fast: true)
                }
                guard !info.id.isEmpty else {
                    throw SyncFailure.userNotFound(user.screenName)
                }
                var newTasks = 0
                var skipped = 0
                var partialFailures = 0
                var cursor: String? = nil
                let maxPages = 5
                var page = 0
                // 同步记录文件：仅 syncRecordFile 模式。record = 最新媒体日期 + 当天媒体 ID 集
                let syncCheck = SettingsStore.shared.settings.syncCheckModeValue
                let record = syncCheck == .syncRecordFile ? try? Self.loadSyncRecord(screenName: user.screenName) : nil
                var latestDay = ""
                var dayIds = Set<String>()
                repeat {
                    if Task.isCancelled { return }
                    let cursorIn = cursor
                    let (posts, next) = try await withTimeout(150) {
                        try await TwitterAPI.shared.getUserMedias(userId: info.id, cursor: cursorIn, fast: true)
                    }
                    // 记录文件模式:翻到比记录锚点更早的日期就停(当天媒体仍要按 ID 排除)
                    if let record, let anchor = Self.parseDay(record.anchorDay) {
                        let olderThanAnchor = posts.allSatisfy { post in
                            guard let created = post.createdAt else { return false }
                            return Self.dayString(created) < record.anchorDay
                        }
                        if olderThanAnchor && page > 0 { break }
                    }
                    for post in posts {
                        if let created = post.createdAt {
                            let day = Self.dayString(created)
                            if day > latestDay { latestDay = day }
                        }
                        for media in post.medias ?? [] {
                            // 记录文件模式:锚点日当天的媒体按资源索引排除;其他日期走常规判定
                            let anchorDay = record?.anchorDay ?? ""
                            let postDay = post.createdAt.map(Self.dayString) ?? ""
                            if let record, postDay == anchorDay, let mid = media.id, record.dayIds.contains(mid) {
                                skipped += 1
                                dayIds.insert(mid)
                                continue
                            }
                            if DownloadStore.shared.hasDownloaded(media: media, dir: DownloadStore.shared.targetDir(for: post)) {
                                skipped += 1
                            } else {
                                if await DownloadStore.shared.createDownloadTask(post: post, media: media) != nil {
                                    newTasks += 1
                                } else {
                                    partialFailures += 1
                                }
                            }
                            if let mid = media.id { dayIds.insert(mid) }
                        }
                    }
                    cursor = next
                    page += 1
                } while cursor != nil && page < maxPages
                if partialFailures > 0 {
                    throw SyncFailure.partialMediaFailure(count: partialFailures)
                }
                userMessages[user.screenName] = L("新任务 ") + "\(newTasks)" + L("，跳过 ") + "\(skipped)"
                if !Task.isCancelled {
                    completedUsers.insert(user.screenName)
                    if syncCheck == .syncRecordFile {
                        Self.writeSyncRecord(screenName: user.screenName,
                                             anchorDay: latestDay.isEmpty ? (record?.anchorDay ?? "") : latestDay,
                                             dayIds: Array(dayIds))
                    }
                }
            } catch is CancellationError {
                return
            } catch let failure as SyncFailure {
                failedUsers[user.screenName] = failure.localizedDescription
                userMessages[user.screenName] = failure.localizedDescription
                AppLogger.warn("用户同步失败", category: "SYNC", [
                    "user": user.screenName, "reason": failure.localizedDescription,
                ])
            } catch {
                // 网络/封禁/权限等统一归类失败（快速失败,不再长时间卡「同步中」）
                let failure = SyncFailure.classify(error, screenName: user.screenName)
                failedUsers[user.screenName] = failure.localizedDescription
                userMessages[user.screenName] = failure.localizedDescription
                AppLogger.warn("用户同步失败", category: "SYNC", [
                    "user": user.screenName, "reason": failure.localizedDescription,
                ])
            }
        }
        if !Task.isCancelled {
            currentUserIndex = -1
            currentUser = nil
            phase = .done
            maybeQuitOnComplete()
        }
    }

    /// 同步全部结束:无未忽略失败 + 设置开启 → 延迟一小段时间(让用户看到完成态)后退出
    private func maybeQuitOnComplete() {
        guard phase == .done, !hasFailures,
              SettingsStore.shared.settings.quitOnSyncCompleteEnabled else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            NSApplication.shared.terminate(nil)
        }
    }

    /// 打开应用自动同步（设置开关）
    func syncOnLaunchIfNeeded() {
        guard autoSyncOnLaunch, phase == .idle, !users.isEmpty else { return }
        startSync()
    }
}


/// 同步失败分类（UI 红字说明 + 诊断）
enum SyncFailure: LocalizedError {
    /// 网络连接超时/失败（离线、代理不可达、DNS 失败等）
    case network(Error)
    /// 用户被封禁（X 返回 403 + suspended）
    case userSuspended(String)
    /// 用户更改访问权限（受保护/私密账号）
    case userProtected(String)
    /// 用户不存在（404/解析不到 rest_id）
    case userNotFound(String)
    /// 部分媒体创建下载任务失败
    case partialMediaFailure(count: Int)
    /// 登录状态失效（Cookie 过期）
    case authExpired

    var errorDescription: String? {
        switch self {
        case .network(let err):
            return L("网络连接失败：") + err.localizedDescription
        case .userSuspended(let sn):
            return L("用户 @\(sn) 已被封禁")
        case .userProtected(let sn):
            return L("用户 @\(sn) 已更改访问权限，无法访问")
        case .userNotFound(let sn):
            return L("用户 @\(sn) 不存在")
        case .partialMediaFailure(let count):
            return L("\(count) 个媒体创建下载任务失败")
        case .authExpired:
            return L("登录状态已失效，请重新导入 Cookie")
        }
    }

    /// 从底层错误归类
    static func classify(_ error: Error, screenName: String) -> SyncFailure {
        if let apiErr = error as? TwitterAPIError {
            switch apiErr {
            case .userNotFound: return .userNotFound(screenName)
            case .missingScreenName, .missingAvatar: return .authExpired
            default: break
            }
        }
        if let netErr = error as? NetworkError, case .httpStatus(let code) = netErr {
            switch code {
            case 403: return .userSuspended(screenName)   // X 封禁返回 403
            case 401: return .authExpired
            case 404: return .userNotFound(screenName)
            default: break
            }
        }
        return .network(error)
    }
}
