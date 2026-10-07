import Foundation
import SwiftUI
import AppKit

// MARK: - 同步窗口语义（契约 `MEDIA_RECORDS.md` §6.3）
//
// 纯逻辑单独放这里，不读设置、不碰网络、不碰磁盘——`SyncStore` 只负责把它接到
// 翻页循环与记录层上。这样窗口语义（停止条件 / 命中跳过 / 写回）可以按契约直接单测，
// 而不必起一个真实的 store + 网络。见 `Tests/XSpiderMacTests/SyncRecordWindowTests.swift`。

/// 同步窗口的判定结果：一条媒体下一步该做什么。
enum SyncWindowDecision: Equatable, Sendable {
    /// 窗口内、id 已在同步记录里 → 跳过（不查文件、不建任务）
    case skipRecorded
    /// 时间比锚点窗口更新（晚于 anchor+1）→ 常规处理（走下载判定）
    case regular
    /// 落在窗口 `[anchor-1, anchor+1]` 内、id 不在记录里 → 走下载判定（该下就下）
    case windowUnrecorded
    /// 时间已早于窗口下界（`< anchor-1`）→ 停止翻页
    case stop
}

/// 一条推文（按本地日历折算出的日期串）相对窗口的位置。
enum SyncWindowPosition: Equatable, Sendable {
    /// 早于窗口下界（`< anchor-1`）→ 时间线降序，之后只会更老，停止翻页
    case stopsCrawl
    /// 落在窗口 `[anchor-1, anchor+1]` 内
    case inWindow
    /// 晚于窗口上界（`> anchor+1`）→ 常规处理
    case newerThanWindow
    /// 没有日期（历史数据缺 `created_at`）或没有锚点 → 无法/无需判位置，常规处理
    case undecided
}

/// 同步窗口（契约 §6.3）。
///
/// 契约的三件事都在这里：
/// 1. **停止条件**：见到「本地日期 < `anchor_day` 减 1 天」的内容 → 停（时间线降序，之后只会更老）；
/// 2. **处理**：窗口 `[anchor-1, anchor+1]` 内 id 命中记录 → 跳过；不在 → 走下载判定；
///    晚于 `anchor+1` → 常规处理；
/// 3. **写回**：`anchor_day` = 本轮见到的最新媒体日期；`ids` = 窗口内已确认存在的全部媒体 id
///    （含本轮跳过的）。
///
/// 为什么窗口两侧各放宽一天：`created_at` 是 UTC、天按设备本地日历折算，
/// 时区 / DST 变化会让同一条内容跨天（同一条内容今天算 9-29、明天可能算 9-30）。
/// 只信"恰好等于 anchor_day"会漏掉跨天的那批，于是两侧各留一天余量。
struct SyncWindow: Sendable {
    /// 记录的锚点日 `yyyy-MM-dd`；空串 = 没有记录（整轮都是常规处理，不提前停）
    let anchorDay: String
    /// 记录里窗口内已确认存在的媒体 id
    let recordedIds: Set<String>
    /// 窗口下界 `anchor-1`（构造时算好：逐条媒体去解析日期太贵）
    let lowerBound: String
    /// 窗口上界 `anchor+1`
    let upperBound: String

    init(anchorDay: String, recordedIds: Set<String>) {
        self.anchorDay = anchorDay
        self.recordedIds = recordedIds
        if anchorDay.isEmpty {
            self.lowerBound = ""
            self.upperBound = ""
        } else {
            self.lowerBound = Self.shiftedDay(anchorDay, byDays: -1)
            self.upperBound = Self.shiftedDay(anchorDay, byDays: 1)
        }
    }

    /// 没有记录（首次同步）：不提前停、全部常规处理。
    static let empty = SyncWindow(anchorDay: "", recordedIds: [])

    /// `yyyy-MM-dd` ∓ 天数（纯"日期"的整日加减，按 **UTC 日历**算）。
    ///
    /// 为什么用 UTC 日历而不是本地日历：入参 `day` 已经是"按本地日历折算好"的日期串，
    /// 这里只是对**日期本身**做整数天加减。若再套一次本地时区，DST 切换日会出现
    /// "加一天还是同一天"（本地一天 ≠ 24 小时）；日期串的语义是"日历上的一天"，
    /// UTC 日历正好保证每天恰好一天。
    static func shiftedDay(_ day: String, byDays offset: Int) -> String {
        guard !day.isEmpty else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = cal
        fmt.timeZone = cal.timeZone
        guard let date = fmt.date(from: day),
              let shifted = cal.date(byAdding: .day, value: offset, to: date) else { return day }
        return fmt.string(from: shifted)
    }

    /// 一条内容（按本地日历算出的日子）落在窗口的哪一侧。
    func position(postDay: String) -> SyncWindowPosition {
        // 没有记录：不设窗口，整轮常规处理（也不提前停）
        guard !anchorDay.isEmpty else { return .undecided }
        // 缺时间戳：无法判位置，按常规处理（保守：宁可多查一次判定，不能误停）
        guard !postDay.isEmpty else { return .undecided }
        if postDay < lowerBound { return .stopsCrawl }
        if postDay > upperBound { return .newerThanWindow }
        return .inWindow
    }

    /// 单条媒体的判定。
    ///
    /// 窗口内：id 在记录里 → 跳过；不在 → 走下载判定（`windowUnrecorded`，调用方接
    /// `DownloadStore.hasDownloaded`，判成"已下载"才算**已确认存在**、
    /// 才写进记录的 ids，见 `SyncWindowRound.confirm`）。
    func decision(postDay: String, mediaId: String?) -> SyncWindowDecision {
        switch position(postDay: postDay) {
        case .stopsCrawl: return .stop
        case .newerThanWindow, .undecided: return .regular
        case .inWindow:
            if let mediaId, recordedIds.contains(mediaId) { return .skipRecorded }
            return .windowUnrecorded
        }
    }

    /// 写回：anchor = 本轮见到的最新媒体日期；ids = 写回窗口
    /// `[anchor-1, anchor+1]` 内已确认存在的全部媒体 id（见 `SyncWindowRound.writtenBack`）。
    ///
    /// 这条纯函数只是把"窗口边界"算给测试用；真正的 id 集合由 `SyncWindowRound` 维护
    /// （它手里有本轮逐条的确认记录）。
    static func windowBounds(anchorDay: String) -> (lower: String, upper: String) {
        guard !anchorDay.isEmpty else { return ("", "") }
        return (shiftedDay(anchorDay, byDays: -1), shiftedDay(anchorDay, byDays: 1))
    }
}

/// 一轮同步的窗口账本（跨页累积）：本轮最新媒体日期 + 已确认存在的媒体 id（按本地日期记）。
///
/// 抽成独立类型是为了能脱离网络 / 设置单测（见 `SyncRecordWindowTests`）：
/// 循环只负责"每看一条推文就 `observe`、每确认一个媒体就 `confirm`"。
///
/// 为什么记「日期 → id」而不是一个 id 集合：写回时 `ids` 只收**写回窗口**
/// `[anchor-1, anchor+1]` 里的确认结果（契约 §6.3「ids = 窗口内已确认存在的全部媒体 id」），
/// 而本轮翻页范围（下界是**旧**锚点减一天）比写回窗口更宽——把窗口外的 id 写进去
/// 与契约不符，也让记录里堆积与本轮无关的 id。
struct SyncWindowRound: Sendable {
    /// 本地日期 `yyyy-MM-dd` → 该日已确认存在（记录命中，或下载判定判成已下载）的媒体 id
    private var confirmedByDay: [String: Set<String>] = [:]
    /// 本轮见到的最新**媒体**日期（推文层时间的最大值；没有媒体就不算）
    private(set) var latestMediaDay = ""

    init() {}

    /// 看一条推文的时间（本地日历 `yyyy-MM-dd`）。空串（缺 `created_at`）忽略；
    /// 只保留最大值——「本轮见到的最新媒体日期」（契约 §6.3 的写回锚点）。
    ///
    /// 与旧实现一致按**每条推文**看，不因为某条恰好没有媒体而漏掉它更新的日期。
    mutating func observe(postDay: String) {
        guard !postDay.isEmpty else { return }
        if postDay > latestMediaDay { latestMediaDay = postDay }
    }

    /// 确认一个媒体 id 在某个本地日期上存在。
    ///
    /// - 记录命中跳过的；
    /// - 走下载判定、判成"已下载"的（含文件模式与记录模式）。
    ///
    /// **不包括**本轮才建任务、还没落盘的：写进去就等于"没下成也算已同步"（静默丢数据）。
    mutating func confirm(mediaDay: String, mediaId: String?) {
        guard let mediaId, !mediaId.isEmpty, !mediaDay.isEmpty else { return }
        confirmedByDay[mediaDay, default: []].insert(mediaId)
    }

    /// 写回：`anchor_day` = 本轮见到的最新媒体日期；`ids` = 写回窗口
    /// `[anchor-1, anchor+1]` 内已确认存在的全部媒体 id。
    ///
    /// 本轮一条带日期的媒体都没见到时，锚点回落到旧值（不清空锚点）；
    /// 旧锚点也为空（首次同步）→ 空记录条目，等下一轮填。
    ///
    /// 只写**窗口内**的确认结果：窗口外的 id 在判定里根本不会被读
    /// （`SyncWindow.decision` 只在 `.inWindow` 分支看 ids），写进去只会让记录无谓变大。
    /// 本轮因 5 页上限没翻到的窗口内媒体不会进 ids——下一轮它会再走一次下载判定，
    /// 判成"已下载"即重新确认。**这是有意的**：没确认就不写，
    /// 好过把没探过的部分当成"已确认"。
    func writtenBack(existingAnchor: String) -> (anchorDay: String, ids: [String]) {
        let anchor = latestMediaDay.isEmpty ? existingAnchor : latestMediaDay
        let bounds = SyncWindow.windowBounds(anchorDay: anchor)
        guard !bounds.lower.isEmpty else { return ("", []) }
        var ids: [String] = []
        for (day, set) in confirmedByDay where day >= bounds.lower && day <= bounds.upper {
            ids.append(contentsOf: set)
        }
        return (anchor, DownloadRecord.normalizedIds(ids))
    }
}

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
            // 名称/头像：先查下载历史，再查 XSpiderAPI（异步补全）
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
        guard let user = try? await XSpiderAPI.shared.getUser(screenName: screenName) else { return }
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

    // MARK: - 同步记录（记录模式：分布式 / 集中式）

    /// 被同步账号的文件夹：`<保存路径>/<昵称-用户名[数字id]>`（契约 §5.1）。
    ///
    /// 昵称 / 用户名只作展示；身份由 `[数字id]` 后缀保证（用户名与昵称都会改）。
    /// **同一 user id 永远指向同一个文件夹**：保存路径下已有该 id 的文件夹就用它，
    /// 找不到才用当前昵称 / 用户名新建（`AccountFolder.directory` 按保存路径缓存了索引）。
    /// 否则改一次昵称就会出现第二个文件夹、同步记录写进新的空文件，旧记录读不到。
    ///
    /// 即使「按账号创建子文件夹」关着，记录模式的同步记录也要按账号分开：
    /// 同步记录天生一账号一条目，混在一个文件里没有意义
    /// （与下载记录"多作者共用一份、判定只看 ids"的语义不同）。
    /// 目录不存在时由写路径（`MediaRecordJSON.writeAtomically`）创建。
    static func accountDirectory(name: String, screenName: String, userId: String) -> String {
        var dir = SettingsStore.shared.settings.download.saveDirBase
        if dir.isEmpty,
           let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            dir = downloads.path
        }
        return AccountFolder.directory(saveDir: dir, name: name, screenName: screenName, userId: userId)
    }

    /// 读同步窗口：记录模式下从记录层取该账号的条目；无记录 → `.empty`（首次同步）。
    ///
    /// 集中式与分布式只是记录文件位置不同，窗口语义完全一致（契约 §6.3）。
    /// 旧的 `.synced.json` 形状（`{anchorDay, dayIds}`）kind/version 对不上，
    /// `SyncRecord.decode` 会整份忽略——不读、不迁移、不删（契约 §2）。
    private func loadWindow(form: RecordForm, accountDir: String?, userId: String) -> SyncWindow {
        guard let url = MediaRecords.shared.syncURL(form: form, accountDir: accountDir),
              let account = MediaRecords.shared.syncAccount(userId: userId, fileURL: url) else {
            return .empty
        }
        return SyncWindow(anchorDay: account.anchorDay, recordedIds: Set(account.ids))
    }

    /// 写回同步条目（只替换该账号那一份，其他账号不动；原子写、自动建目录）。
    private func writeWindow(form: RecordForm, accountDir: String?, userId: String,
                             anchorDay: String, ids: [String]) {
        guard let url = MediaRecords.shared.syncURL(form: form, accountDir: accountDir) else {
            AppLogger.warn("同步记录无法定位（缺账号文件夹）", category: "SYNC", ["userId": userId])
            return
        }
        do {
            try MediaRecords.shared.setSyncAccount(userId: userId, anchorDay: anchorDay,
                                                   ids: ids, fileURL: url)
        } catch {
            AppLogger.warn("同步记录写入失败", category: "SYNC", [
                "userId": userId, "file": url.path, "error": error.localizedDescription,
            ])
        }
    }

    static func dayString(_ date: Date) -> String {
        DateFormatter.fallback.string(from: date)
    }

    /// 一条媒体是否**已经在本地**（同步判定）。
    ///
    /// - `syncCheck == .fileName`：**直接复用下载判定的"按文件名"实现**
    ///   （`MediaJudgement.isDownloaded`）——契约 §6.3 明说要复用同一个实现，
    ///   所以两条路径不可能漂移；
    /// - 两个记录模式：走 `DownloadStore.hasDownloaded`（它按**下载判定**的设置读记录，
    ///   同样是"只信记录、不回查文件"）。
    private func isAlreadyPresent(post: TwitterPost, media: TwitterMedia,
                                  syncCheck: SyncCheckMode, settings: Settings) -> Bool {
        let dir = DownloadStore.shared.targetDir(for: post)
        switch syncCheck {
        case .fileName:
            return MediaJudgement.isDownloaded(
                post: post, media: media,
                template: settings.download.fileNameTemplate,
                appendUniqueId: settings.appendUniqueIdEnabled,
                in: dir)
        case .distributed, .centralized:
            return DownloadStore.shared.hasDownloaded(media: media, dir: dir, post: post)
        }
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
                    try await XSpiderAPI.shared.getUser(screenName: user.screenName, fast: true)
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
                let settings = SettingsStore.shared.settings
                let syncCheck = settings.syncCheckModeValue
                // 判定依据（契约 §6.3）：
                // - 按文件名：直接复用下载判定的同一实现（`MediaJudgement`），没有窗口、不写记录；
                // - 记录文件·分布式 / 集中式：走窗口语义，记录的读写全交给 `MediaRecords`。
                let form: RecordForm? = {
                    switch syncCheck {
                    case .fileName: return nil
                    case .distributed: return .distributed
                    case .centralized: return .centralized
                    }
                }()
                // 账号文件夹按**数字 id** 定位（昵称/用户名只是给人看的，见契约 §5.1）：
                // 已有该 id 的文件夹优先，改昵称不会写出第二个文件夹、旧记录也不会失联。
                let accountDir = form == nil ? nil : Self.accountDirectory(
                    name: info.name, screenName: info.screenName, userId: info.id)
                let window = form.map { loadWindow(form: $0, accountDir: accountDir, userId: info.id) } ?? .empty
                // 本轮账本从空开始：写回时 `ids` = **写回窗口**（新 anchor ∓1 天）内
                // 已确认存在的全部媒体 id。翻页从最新开始下降，且遇到 `windowLower` 就停，
                // 所以窗口一旦被翻到就是完整覆盖的；5 页上限没翻到的部分下一轮会重新判定
                // （判成"已下载"即重新确认），不会丢下载、也不会把没探过的当成已同步。
                var round = SyncWindowRound()
                pageLoop: repeat {
                    if Task.isCancelled { return }
                    let cursorIn = cursor
                    let (posts, next) = try await withTimeout(150) {
                        try await XSpiderAPI.shared.getUserMedias(userId: info.id, cursor: cursorIn, fast: true)
                    }
                    for post in posts {
                        let postDay = post.createdAt.map(Self.dayString) ?? ""
                        // 停止条件在**推文层**判（契约 §6.3：「见到本地日期 < anchor-1 的内容即可停」）：
                        // 时间线降序，出现一条更老的后，本页剩余与后续页只会更老；
                        // 放在推文层才不会因为"这条老推文恰好没有媒体"而白翻一页。
                        if window.position(postDay: postDay) == .stopsCrawl {
                            break pageLoop
                        }
                        let medias = post.medias ?? []
                        // 记录「本轮见到的最新媒体日期」——与旧实现一致：**每条推文**都看，
                        // 不因为某条恰好没有媒体就漏掉它更新的日期。
                        round.observe(postDay: postDay)
                        for media in medias {
                            switch window.decision(postDay: postDay, mediaId: media.id) {
                            case .stop:
                                // 推文层已判过一次，这里是媒体层的兜底（同输入不会分叉）。
                                break pageLoop
                            case .skipRecorded:
                                skipped += 1
                                round.confirm(mediaDay: postDay, mediaId: media.id)
                            case .regular, .windowUnrecorded:
                                let already = isAlreadyPresent(post: post, media: media,
                                                               syncCheck: syncCheck, settings: settings)
                                if already {
                                    skipped += 1
                                } else if await DownloadStore.shared.createDownloadTask(
                                    post: post, media: media) != nil {
                                    newTasks += 1
                                } else {
                                    // `createDownloadTask` 返回 nil = 建不了任务
                                    // （没有下载地址，或它内部的 sameFileSkip 判重）——
                                    // 与旧实现一致，计入失败；这个假红是既有行为，
                                    // 不在本次"只改判定"的范围内。
                                    partialFailures += 1
                                }
                                // 已确认存在的媒体（含本轮跳过的）按**本地日期**记账，
                                // 写回时只取窗口 [anchor-1, anchor+1] 内的那部分。
                                if already {
                                    round.confirm(mediaDay: postDay, mediaId: media.id)
                                }
                            }
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
                    // 写回：anchor = 本轮见到的最新媒体日期；ids = 窗口内已确认存在的全部媒体 id。
                    // 「按文件名」模式没有记录文件，不写。
                    if let form {
                        let written = round.writtenBack(existingAnchor: window.anchorDay)
                        writeWindow(form: form, accountDir: accountDir, userId: info.id,
                                    anchorDay: written.anchorDay, ids: written.ids)
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
        if let apiErr = error as? XSpiderAPIError {
            switch apiErr {
            case .userNotFound: return .userNotFound(screenName)
            case .missingScreenName, .missingAvatar, .notAuthorized: return .authExpired
            default: break
            }
        }
        // 组件给的是**结构化错误码**（契约只允许按 code 判断，不许匹配文案）。
        // 这一层决定"账号被封 / 登录失效 / 用户不存在 / 网络问题"给用户看什么提示。
        if let component = error as? XSpiderComponent.ComponentError {
            if let status = component.status {
                switch status {
                case 403: return .userSuspended(screenName)   // X 封禁返回 403
                case 401: return .authExpired
                case 404: return .userNotFound(screenName)
                default: break
                }
            }
            switch component.code {
            case "unauthorized": return .authExpired
            case "not_found": return .userNotFound(screenName)
            default: break
            }
        }
        return .network(error)
    }
}
