import Foundation
import UserNotifications

/// 上游 download store + aria2 的原生替代：URLSessionDownloadTask。
/// 支持暂停/恢复（resumeData）/重试×5/批量创建/sameFileSkip/系统通知。
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()

    // MARK: - 状态

    var tasks: [DownloadTask] = [] {
        didSet { persistTasks() }
    }
    var currentTab: String = "下载中"
    var creationTasks: [CreationTask] = []
    /// 历史记录筛选：nil = 全部；否则仅显示该 screen_name 的任务
    var userFilterScreenName: String?
    /// 用户筛选小窗是否弹出（DownloadsView 用）
    var userFilterPickerVisible = false

    /// 出现过的账号（昵称 + screenName + 头像），按最近任务时间排序
    var knownUsers: [(name: String, screenName: String, avatar: String)] {
        var seen: [String: (String, Date)] = [:]  // screenName -> (name, latestUpdated)
        var avatars: [String: String] = [:]
        for task in tasks {
            let sn = task.post.user.screenName
            let prev = seen[sn]
            if prev == nil || task.updatedAt > prev!.1 {
                seen[sn] = (task.post.user.name, task.updatedAt)
            }
            if avatars[sn] == nil { avatars[sn] = task.post.user.avatar }
        }
        return seen
            .sorted { $0.value.1 > $1.value.1 }
            .map { (name: $0.value.0, screenName: $0.key, avatar: avatars[$0.key] ?? "") }
    }

    /// 按当前 Tab + 用户筛选后的任务
    func tasksForCurrentTab(statuses: [DownloadStatus]) -> [DownloadTask] {
        tasks.filter { task in
            statuses.contains(task.status) &&
            (userFilterScreenName == nil || task.post.user.screenName == userFilterScreenName)
        }
    }

    /// 删除当前 Tab + 用户筛选范围内的记录；alsoDeleteFiles = 同时删除源文件与未完成临时文件。
    /// 文件删除在后台线程批量执行（UI 不卡顿）：先同步摘除记录与引擎任务，再异步清盘。
    func removeVisibleRecords(statuses: [DownloadStatus], alsoDeleteFiles: Bool = false) {
        let targets = tasksForCurrentTab(statuses: statuses).map(\.gid)
        // 先摘记录/停引擎（同步,快）,收集要删的文件路径
        var pathsToDelete: [String] = []
        if alsoDeleteFiles {
            for gid in targets {
                if let task = tasks.first(where: { $0.gid == gid }) {
                    let dest = (task.dir as NSString).appendingPathComponent(task.fileName)
                    pathsToDelete.append(dest)
                    // 组件的断点文件（名字带引擎标识，见 docs/02 §E3：两个引擎的断点物理隔开）
                    for suffix in [".part.http", ".part.aria2next",
                                   ".part.http.aria2", ".part.aria2next.aria2"] {
                        pathsToDelete.append(dest + suffix)
                    }
                }
            }
        }
        for gid in targets { remove(gid, alsoDeleteFiles: false) }
        if alsoDeleteFiles && !pathsToDelete.isEmpty {
            let paths = pathsToDelete
            Task.detached(priority: .utility) {
                let fm = FileManager.default
                var removed = 0
                for p in paths {
                    if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p); removed += 1 }
                }
                AppLogger.info("已删除记录和源文件", category: "DL", ["files": "\(removed)"])
            }
        }
        AppLogger.info("删除历史记录", category: "DL", [
            "count": "\(targets.count)", "files": alsoDeleteFiles ? "yes" : "no",
            "user": userFilterScreenName ?? "all",
        ])
    }

    /// 下载执行现在全部归组件（`dl.*`）。应用侧只留：
    /// 目录与文件名的计算（`targetDir` / `fileNameWithIndex`）、
    /// 收尾的内容校验（`FileIntegrity`）、下载记录（`.downloaded.json`）、通知。
    ///
    /// 为什么不留一份 URLSession 实现：断点续传与完整性校验一旦有两份实现，
    /// 就会出现"内置引擎好好的、外派引擎拼出损坏文件"这类只在部分用户那里复现的问题
    /// ——`docs/01-ARCHITECTURE.md` §5.2 把这条写成了纪律。
    ///
    /// `dl.events` 的增量游标（下次把返回的 seq 传回去）。
    private var componentCursor: UInt64 = 0
    /// 轮询任务：只要还有 active/waiting 就活着。
    private var componentPoller: Task<Void, Never>?
    /// 已经交给组件的任务（`gid` 就是契约里的 `job_id`，跨重启稳定）。
    private var componentJobs: Set<String> = []
    /// 已经做完应用侧收尾（内容校验 + 记录）的任务，避免事件与列表两条路重复收尾。
    private var finalized: Set<String> = []

    private var settings: Settings { SettingsStore.shared.settings }
    private let fm = FileManager.default

    private init() {
        restoreTasks()
        loadRecordCaches()
        syncWithComponentOnLaunch()
        // CDN 限流解除（到期 / 用户点重试 / 某任务成功后确认恢复）时唤醒等待队列。
        // 没有这条回调，限流期间被压住的 waiting 任务在恢复后不会自动启动——
        // 并发上限虽回到设置值，却没人调用 pump。
        AccountStatusStore.shared.onCDNRecovered = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                AppLogger.info("媒体 CDN 恢复,唤醒下载队列", category: "DL", [
                    "effectiveConcurrent": "\(self.effectiveMaxConcurrent())",
                ])
                self.pump()
            }
        }
    }

    /// 「已下载」判定结果的版本号。
    ///
    /// 为什么需要：判定结果由 `hasDownloaded` 即时算出，它读的是两个 **static** 缓存
    /// （recordCache / completedFileNameCache）与文件系统 —— 这些都**不参与
    /// `@Observable` 的依赖追踪**。于是切换判定依据、换保存路径、清缓存之后，
    /// 判定结果其实变了，但 SwiftUI 不知道要重绘，媒体卡上的下载/已下载按钮状态
    /// 会停在旧结果（用户报告的现象）。
    ///
    /// 视图读取本属性即建立观察依赖；影响判定的操作自增它即可触发刷新。
    private(set) var judgementVersion = 0

    /// 判定依据变化后调用：清掉派生缓存并通知视图重算判定
    func invalidateJudgements() {
        refreshDownloadedCaches()
        judgementVersion += 1
        AppLogger.info("判定依据已变更,刷新已下载状态", category: "DL", [
            "mode": settings.sameFileCheckModeValue.rawValue,
        ])
    }

    /// 启动时扫描各用户文件夹的记录文件到内存缓存（避免覆盖旧记录）
    /// 保存路径/子文件夹设置变更时调用:重载记录缓存 + 清完成文件名缓存(判定立即刷新)
    func refreshDownloadedCaches() {
        Self.recordCache.removeAll()
        Self.completedFileNameCache.removeAll()
        loadRecordCaches()
        judgementVersion += 1
    }

    private func loadRecordCaches() {
        let base = settings.download.saveDirBase
        guard !base.isEmpty, fm.fileExists(atPath: base) else { return }
        let recordName = settings.recordFileNameValue
        let enumerator = fm.enumerator(atPath: base)
        var loaded = 0
        while let sub = enumerator?.nextObject() as? String {
            guard sub.hasSuffix(recordName) || sub.contains("/" + recordName) || sub == recordName else { continue }
            let full = (base as NSString).appendingPathComponent(sub)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // v2: { downloaded: [...], files: { id: name } }
                // v1: { downloaded: [...] }；更旧: { anchorDay, dayIds }
                let names = (obj["files"] as? [String: String]) ?? [:]
                if let list = obj["downloaded"] as? [String] {
                    Self.recordCache[full] = RecordEntry(anchorDay: "", dayIds: list, fileNames: names)
                    loaded += 1
                } else if let list = obj["dayIds"] as? [String] {
                    Self.recordCache[full] = RecordEntry(anchorDay: "", dayIds: list, fileNames: names)
                    loaded += 1
                }
            }
        }
        if loaded > 0 {
            AppLogger.info("已载入下载记录", category: "DL", ["files": "\(loaded)"])
        }
    }

    /// 隐私开关：离开下载页时清空下载历史（仅记录，不删文件）
    func clearHistoryIfEnabled() {
        guard SettingsStore.shared.settings.autoClearDownloadHistoryEnabled, !tasks.isEmpty else { return }
        removeAll()
        AppLogger.info("自动清空下载历史", category: "DL")
    }

    // MARK: - 创建任务

    /// 上游 prepareDownloadTask + createDownloadTask：解析模板 → 检查 sameFileSkip → 启动下载
    /// - Parameter silent: 批量爬取(path)下为 true —— 跳过时不发系统通知，
    ///   否则「下载全部」扫到成百上千条已下载媒体会弹满通知并卡住 UI
    func createDownloadTask(post: TwitterPost, media: TwitterMedia, silent: Bool = false) async -> DownloadTask? {
        guard let downloadUrl = downloadURL(for: media) else {
            AppLogger.warn("媒体没有下载链接", category: "DL", ["mediaId": media.id ?? "nil", "type": media.type.rawValue])
            return nil
        }

        let templateData = FileNameTemplateData(post: post, media: media)
        let dir = targetDir(for: post)
        let rawName = FileNameTemplate.resolve(template: settings.download.fileNameTemplate, data: templateData)
        // 「按文件名」模式：落盘名末尾带资源索引（判据与去重都基于它）。
        // 「按下载记录文件」模式：保持用户模板原样——判定不依赖文件名，
        // 改文件名也不会让记录失效，无需为此改变既有用户的命名。
        var fileName = settings.sameFileCheckModeValue == .fileName
            ? fileNameWithIndex(rawName, media: media, post: post, template: settings.download.fileNameTemplate)
            : rawName

        // sameFileSkip：按当前判定依据决定跳过
        if settings.download.sameFileSkip {
            if isDuplicate(media: media, post: post, fileName: rawName, dir: dir) {
                // 单媒体点击下载被跳过时给可见反馈（否则用户以为按钮失灵）；批量路径静默
                if !silent {
                    notify(title: L("任务已跳过"), body: L("该媒体已下载过：") + fileName)
                }
                return nil
            }
        }

        // 文件名重复消解：目标位置已存在同名文件、或任务列表里有同路径未完成任务
        // → 追加「 (2)」「 (3)」序号（索引已保证同推文内唯一，这里兜跨推文的同名）
        fileName = uniquedFileName(fileName, dir: dir)

        let task = DownloadTask(
            gid: UUID().uuidString,
            post: post,
            media: media,
            fileName: fileName,
            dir: dir,
            totalSize: 0,
            completeSize: 0,
            status: .waiting,
            error: nil,
            updatedAt: Date(),
            downloadUrl: downloadUrl,
            retryCountRemains: 5
        )

        AppLogger.info("创建下载任务", category: "DL", ["file": fileName, "dir": dir, "url": downloadUrl, "mediaId": media.id ?? "?"])
        tasks.append(task)
        start(task)
        SleepPreventer.shared.update(activeDownloadCount: tasks.count { $0.status == .active || $0.status == .waiting })
        return task
    }

    /// 批量建任务。`yielding` 每批之间让出并短暂停顿。
    ///
    /// 为什么要分批：全选一次可能灌入上千个任务，每个都要解析模板、查判定、
    /// 逐个 `start(task)` 起 aria2 请求。瞬时灌入会让主线程连续卡顿（界面僵住），
    /// 也让 aria2 的连接数瞬间打满。分批后每批之间让出主线程、并按需停顿。
    ///
    /// - Parameter yielding: 传 true 时启用节流（爬虫路径用它；小批量调用不必）。
    func batchCreateDownloadTasks(_ paramsList: [(post: TwitterPost, media: TwitterMedia)],
                                  yielding: Bool = true) async {
        // 小批量不值得节流（一次点击下载几张，停顿反而变慢）
        guard yielding, paramsList.count > Self.batchThrottleThreshold else {
            for params in paramsList {
                _ = await createDownloadTask(post: params.post, media: params.media, silent: true)
            }
            return
        }
        var processed = 0
        for params in paramsList {
            if Task.isCancelled { return }
            _ = await createDownloadTask(post: params.post, media: params.media, silent: true)
            processed += 1
            if processed % Self.batchSize == 0 {
                // 让出主线程：否则大批量会让界面在这些等待点之间完全无响应
                await Task.yield()
                try? await Task.sleep(nanoseconds: Self.batchPauseNanos)
            }
        }
    }

    /// 超过这个数量才启用分批节流（低于它不值得停顿）
    static let batchThrottleThreshold = 50
    /// 每批大小
    static let batchSize = 25
    /// 批间停顿（50ms：够让 UI 喘口气，又不明显拖慢总时长）
    static let batchPauseNanos: UInt64 = 50_000_000

    // MARK: - 跳过相同文件判定

    /// 判定依据（设置里可选）——两者语义**有意不同**，理由见 docs/DEVELOPMENT.md：
    ///
    /// - **recordFile（按下载记录文件）**：只查记录文件里是否已有该媒体 ID，
    ///   命中即信任，**不回头校验文件是否存在/完整**。
    ///   这正是该依据存在的意义：改文件名模板、重命名或移动文件、整目录搬家，
    ///   记录都依然有效。若额外做"记录 ↔ 文件"双向校验，会把"用户改过文件名"
    ///   误判成"没下载过"而重复下载，恰好抵消掉它唯一优于"按文件名"的地方。
    ///
    /// - **fileName（按文件名）**：解析模板后**在扩展名前强制追加资源索引**
    ///   （见 fileNameWithIndex），再查该文件是否存在。索引让文件名本身成为
    ///   可靠判据：即使模板不含任何唯一变量，同一推文的多张媒体也不会互相覆盖。
    private func isDuplicate(media: TwitterMedia, post: TwitterPost?, fileName: String, dir: String) -> Bool {
        switch settings.sameFileCheckModeValue {
        case .recordFile:
            guard let mediaId = media.id, !mediaId.isEmpty else { return false }
            let recordURL = recordFileURL(dir: dir)
            if Self.recordCache[recordURL.path]?.dayIds.contains(mediaId) == true {
                AppLogger.info("下载记录命中，跳过", category: "DL", ["mediaId": mediaId, "dir": dir])
                return true
            }
            return false
        case .fileName:
            let judged = fileNameWithIndex(fileName, media: media, post: post, template: settings.download.fileNameTemplate)
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(judged)) {
                AppLogger.info("sameFileSkip 跳过已存在文件", category: "DL", ["file": judged])
                return true
            }
            // 兼容升级前未追加索引的旧文件，避免改名后把整库重下一遍
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(fileName)) {
                AppLogger.info("sameFileSkip 命中旧命名文件", category: "DL", ["file": fileName])
                return true
            }
            return false
        }
    }

    /// 在扩展名前追加资源索引，如默认模板 `… %POST_ID% %EXT%` 解析出
    /// `… 123 .jpg` → `… 123 1.jpg`。
    ///
    /// 为什么必须加：判定依据是"文件名"时，用户模板可能不含任何唯一变量
    /// （如 `%USER_SCREEN_NAME%%EXT%`），同一用户的多张媒体会解析成同名 →
    /// 判定永远只认第一个文件，其余被误判为"已下载"。索引让每张媒体获得
    /// 稳定且唯一的文件名，判据才成立。
    ///
    /// 三个细节：
    /// - **分隔符按需补**：模板自带分隔时直接用（默认模板在 `%EXT%` 前留了空格，
    ///   解析后 stem 已以空格结尾）；没有分隔则补一个空格，避免拼出 `1231.jpg`
    ///   这种歧义名。已有分隔符时不重复补，否则会出现双空格。
    /// - **模板已含 `%MEDIA_INDEX%` 时不追加**：尊重用户显式选择，
    ///   也保证既有用户的已下载文件仍能被正确判定（不会误判成未下载而重下）。
    /// - 只在**按文件名**模式使用；记录文件模式判定不依赖文件名，保持模板原样。
    func fileNameWithIndex(_ fileName: String, media: TwitterMedia, post: TwitterPost?, template: String) -> String {
        guard !template.uppercased().contains("%MEDIA_INDEX%") else { return fileName }
        let idx = mediaIndexInPost(media: media, post: post)
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        // 已有分隔符（空格/连字符/下划线/点）则不补，避免双分隔
        let separators = [" ", "-", "_", "."]
        let needsSeparator = !separators.contains { stem.hasSuffix($0) }
        let joined = needsSeparator ? "\(stem) \(idx)" : "\(stem)\(idx)"
        return ext.isEmpty ? joined : "\(joined).\(ext)"
    }

    /// 媒体在其推文内的序号（1 起）。无推文上下文时退化为 1
    /// （此时模板通常已含唯一变量，不需要靠索引区分）
    private func mediaIndexInPost(media: TwitterMedia, post: TwitterPost?) -> Int {
        guard let post, let list = post.medias,
              let i = list.firstIndex(where: { $0.id == media.id }) else { return 1 }
        return i + 1
    }

    /// 记录文件路径（每用户文件夹一份）
    private func recordFileURL(dir: String) -> URL {
        URL(fileURLWithPath: dir).appendingPathComponent(settings.recordFileNameValue)
    }

    /// 下载记录条目。
    /// v1：只有媒体 ID 列表（`{"downloaded":[...]}`）。
    /// v2：额外记录「媒体 ID → 文件名」（`{"downloaded":[...],"files":{...}}`），
    ///     用于**双向校验**——记录说已下载但文件不存在/为 0 字节时以文件系统为准并清除该条目。
    ///     这能自愈历史遗留的坏记录（早期版本把 0 字节文件当成功写入了记录）。
    struct RecordEntry: Codable, Sendable {
        var anchorDay: String        // "yyyy-MM-dd"
        var dayIds: [String]
        /// 媒体 ID → 下载后的文件名（v2 起写入；旧记录为空）
        var fileNames: [String: String]

        init(anchorDay: String, dayIds: [String], fileNames: [String: String] = [:]) {
            self.anchorDay = anchorDay
            self.dayIds = dayIds
            self.fileNames = fileNames
        }
    }

    /// 各记录文件的缓存（内存态，进程内有效）
    private static var recordCache: [String: RecordEntry] = [:]

    private static func todayString(_ date: Date = Date()) -> String {
        DateFormatter.fallback.string(from: date)
    }

    /// 下载成功后写入记录文件（媒体 ID + 文件名）。
    /// 每完成一个任务异步落盘（后台队列串行写，不阻塞下载回调）。
    private func recordDownloaded(mediaId: String?, created: Date?, dir: String, fileName: String?) {
        guard settings.sameFileCheckModeValue == .recordFile,
              let mediaId, !mediaId.isEmpty else { return }
        let url = recordFileURL(dir: dir)
        var entry = Self.recordCache[url.path] ?? RecordEntry(anchorDay: "", dayIds: [])
        guard !entry.dayIds.contains(mediaId) else { return }
        entry.dayIds.append(mediaId)
        if let fileName { entry.fileNames[mediaId] = fileName }
        Self.recordCache[url.path] = entry
        let snapshot = entry.dayIds.sorted()
        let names = entry.fileNames
        Self.recordWriteQueue.async { [weak self] in
            let fm = FileManager.default
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: [
                    "downloaded": snapshot,
                    "files": names,
                ])
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.warn("下载记录写入失败", category: "DL", ["dir": dir, "error": error.localizedDescription])
            }
            _ = self
        }
    }

    /// 记录文件异步写入队列（串行,避免并发写互相覆盖）
    private static let recordWriteQueue = DispatchQueue(label: "xspider.recordfile", qos: .utility)

    private static func parseAnchorDay(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        return DateFormatter.dayOnly.date(from: s)
    }

    /// 某推文媒体应保存的目标目录（主页"已下载"判定用）。
    /// `post` 为 nil 时回落到根目录——查看窗口等"拿不到 post"的场景不必各自判断。
    func targetDir(for post: TwitterPost?) -> String {
        var dir = settings.download.saveDirBase
        if dir.isEmpty,
           let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            dir = downloads.path
        }
        if let post, settings.accountSubfolderEnabled {
            let folderName = "\(post.user.name)-@\(post.user.screenName)".safePathComponent()
            dir = (dir as NSString).appendingPathComponent(folderName)
        }
        return dir
    }

    /// 文件名是否已包含 %MEDIA_ID% 模板变量
    private func templateHasMediaId() -> Bool {
        settings.download.fileNameTemplate.contains("%MEDIA_ID%")
    }

    /// 文件名重复消解：同路径冲突时追加「 (n)」序号（(2) 起）；检查文件系统与未完成任务表
    private func uniquedFileName(_ fileName: String, dir: String) -> String {
        func taken(_ name: String) -> Bool {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(name)) { return true }
            return tasks.contains {
                $0.dir == dir && $0.fileName == name &&
                $0.status != .error && $0.status != .removed
            }
        }
        guard taken(fileName) else { return fileName }
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }


    // MARK: - 历史持久化（重启后恢复记录；进行中的任务恢复为等待态，用户手动继续）

    /// 下载历史文件。**故意不是 private**：live 测试要先备份再还原它——
    /// 那是用户的真实数据（1500+ 条），测试在里面留下的条目指向临时目录，是纯垃圾。
    static let historyURL = AppDirectories.support
        .appendingPathComponent("download-history.json")

    private struct PersistedTask: Codable {
        var gid: String
        var post: TwitterPost
        var media: TwitterMedia
        var fileName: String
        var dir: String
        var totalSize: Int64
        var completeSize: Int64
        var statusRaw: String
        var error: String?
        var updatedAt: Date
        var downloadUrl: String
        var retryCountRemains: Int
        /// 实际使用过的引擎（旧记录无此字段 → 解码为 nil，视为未知）
        var engineRaw: String?
    }

    private func persistTasks() {
        let items = tasks.map {
            PersistedTask(gid: $0.gid, post: $0.post, media: $0.media, fileName: $0.fileName,
                          dir: $0.dir, totalSize: $0.totalSize, completeSize: $0.completeSize,
                          statusRaw: $0.status.rawValue, error: $0.error, updatedAt: $0.updatedAt,
                          downloadUrl: $0.downloadUrl, retryCountRemains: $0.retryCountRemains,
                          engineRaw: $0.engine?.rawValue)
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.historyURL, options: .atomic)
    }

    private func restoreTasks() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              let items = try? JSONDecoder().decode([PersistedTask].self, from: data) else { return }
        tasks = items.map { item in
            var status = DownloadStatus(rawValue: item.statusRaw) ?? .error
            // 上次退出时还在下载中的任务：恢复为等待态（不自动重启，防止意外流量）
            if status == .active || status == .waiting { status = .paused }
            return DownloadTask(
                gid: item.gid, post: item.post, media: item.media, fileName: item.fileName,
                dir: item.dir, totalSize: item.totalSize, completeSize: item.completeSize,
                status: status, error: item.error, updatedAt: item.updatedAt,
                downloadUrl: item.downloadUrl, retryCountRemains: item.retryCountRemains,
                engine: item.engineRaw.flatMap(DownloadEngine.init(rawValue:))
            )
        }
    }

    // MARK: - 任务控制

    /// 启动时与组件对账一次。
    ///
    /// 两件事，缺一件都会出现"界面与事实相反"：
    /// 1. **组件会自动重新排队未完成的任务**（它读自己的记录做断点续传），
    ///    而本应用的策略是"重启不自动续传"（怕意外流量）——所以对账之后要把它
    ///    **真的暂停掉**，而不是只在界面上写着"已暂停"；
    /// 2. 停机期间组件可能已经下完（或被取消）：用 `dl.list` 的权威状态收尾，
    ///    否则那几条会永远停在"暂停"。
    ///
    /// 为什么以前不需要：事件轮询只在**有新任务入队**时才启动，
    /// 而"这次启动只有恢复任务"的情况不会有任何入队动作。
    private func syncWithComponentOnLaunch() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await XSpiderComponent.shared.call("dl.list")
                let jobs = (list[array: "jobs"] ?? []).compactMap { $0.asObject }
                guard !jobs.isEmpty else { return }

                var toPause: [String] = []
                for job in jobs {
                    guard let jobId = job[string: "job_id"],
                          let task = self.tasks.first(where: { $0.gid == jobId }) else { continue }
                    let state = job[string: "state"] ?? ""
                    if task.status == .paused, state == "waiting" || state == "active" {
                        toPause.append(jobId)
                        continue  // 不要再走 reconcile 把它标成 active
                    }
                    self.reconcile(job)
                }
                for jobId in toPause {
                    _ = try? await XSpiderComponent.shared.call("dl.pause", ["job_id": .string(jobId)])
                }
                AppLogger.info("启动时与组件对账", category: "DL", [
                    "jobs": "\(jobs.count)", "已按策略暂停": "\(toPause.count)",
                ])
            } catch {
                AppLogger.debug("启动对账失败（组件可能还没起来）", category: "DL", [
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func refreshSleepAssertion() {
        SleepPreventer.shared.update(activeDownloadCount: tasks.count { $0.status == .active || $0.status == .waiting })
    }

    /// 启动任务：受并发数限制，超出则保持 waiting，有空位时由 pump() 拉起
    func start(_ task: DownloadTask) {
        update(gid: task.gid) { $0.status = .waiting }
        pump()
    }

    /// 并发调度：把 waiting 任务按序填入空闲并发槽位。
    /// 有效并发 = min(用户设置, CDN 限流时的降级上限)——CDN 429 时自动降到 1，
    /// 避免"越限越试"；限流解除后自动恢复（状态变更会再次 pump）。
    private func pump() {
        let maxConcurrent = effectiveMaxConcurrent()
        let activeCount = tasks.count { $0.status == .active }
        guard activeCount < maxConcurrent else { return }

        let slots = maxConcurrent - activeCount
        var launched = 0
        for task in tasks where task.status == .waiting {
            guard launched < slots else { break }
            launch(task)
            launched += 1
        }
        refreshSleepAssertion()
    }

    /// 有效并发 = min(用户设置, CDN 限流时的降级上限)。
    ///
    /// CDN 限流的完整流程：
    /// 1. 某任务收到 429 → `noteCDNRateLimited` 记下截止时刻 → 本函数开始返回降级上限（默认 1）；
    /// 2. **已在下载中的任务不被打断**（pump 只负责拉起 waiting，从不暂停 active ——
    ///    中途掐断正在写的文件正是损坏的来源之一）；
    /// 3. waiting 任务保持排队，每次有任务结束触发 pump 时只补足到降级上限；
    /// 4. 恢复（三条路径）：任务成功确认正常 / 冷却到期 / 用户点 CDN 行重试。
    ///    三条路径都会触发 `onCDNRecovered` → pump → 上限回到用户设置值并继续拉起积压任务。
    private func effectiveMaxConcurrent() -> Int {
        let configured = settings.maxConcurrentDownloads
        guard settings.cdnThrottleEnabled, AccountStatusStore.shared.cdnThrottled else {
            return configured
        }
        return min(configured, settings.cdnMaxConcurrent)
    }

    /// 实际拉起：**把任务交给组件**（`dl.enqueue`）。
    ///
    /// 目录与文件名仍然是应用算好的（组件只收 `dest_dir` + `file_name`）；
    /// `job_id` 用 `gid`——它本来就是"跨重启稳定的业务 id"，正好当幂等键：
    /// 重复入队（暂停后恢复、重试、重启对账）不会重复下载。
    private func launch(_ task: DownloadTask) {
        guard URL(string: task.downloadUrl) != nil else {
            update(gid: task.gid) { $0.status = .error; $0.error = "无效的下载地址" }
            return
        }
        try? fm.createDirectory(atPath: task.dir, withIntermediateDirectories: true)
        let engine = engineFor(task)
        update(gid: task.gid) { $0.status = .active; $0.engine = engine }
        AppLogger.debug("任务交给组件下载", category: "DL", [
            "gid": task.gid, "engine": engine.rawValue,
            "file": task.fileName, "user": task.post.user.screenName,
        ])

        var params: [String: JSONValue] = [
            "job_id": .string(task.gid),
            "url": .string(task.downloadUrl),
            "dest_dir": .string(task.dir),
            "file_name": .string(task.fileName),
            // `tag` 是不透明的：组件只存不解释，这里放推文 id 便于排障
            "tag": .string(task.post.id),
            "requirements": .object([
                "resume": .bool(true),
                "segments": .int(segmentsFor(task)),
            ]),
        ]
        // 已知大小就给它：组件的完成判据是**落盘字节数**，给了它才能校验完整性。
        // 不知道就不传这个键（契约里 `expect_size` 是整数，**不接受 null**）；
        // 组件会自己探（`net.probe_size` 那条路径），代价是一次 CDN 请求。
        if task.totalSize > 0 {
            params["expect_size"] = .int(Int(task.totalSize))
        }

        componentJobs.insert(task.gid)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await XSpiderComponent.shared.call("dl.enqueue", params)
                // `already_known` = 组件里**已经有**这个 job（暂停中 / 失败 / 已完成），
                // 而 **enqueue 不会重启它**——幂等键的语义就是"别重复做"。
                // 所以"继续"与"重试"走到这里时必须补一次 `dl.resume`
                // （对 paused 与 error 都有效，只拒绝已完成）。
                // 少了这一步的症状很隐蔽：界面显示"下载中"，而组件里任务还是 paused，
                // 进度永远停在断点处不动。
                if result[string: "accepted_by"] == "already_known" {
                    do {
                        _ = try await XSpiderComponent.shared.call(
                            "dl.resume", ["job_id": .string(task.gid)])
                    } catch {
                        // 已完成的任务 resume 会被拒（契约如此），交给 dl.list 对账收尾
                        AppLogger.debug("dl.resume 被拒（任务可能已完成）", category: "DL", [
                            "gid": task.gid, "error": error.localizedDescription,
                        ])
                    }
                }
                self.startComponentPolling()
            } catch {
                self.handleComponentLaunchFailure(gid: task.gid, error: error)
            }
        }
    }

    /// 「希望多连接」的分片数。
    ///
    /// 组件的 `requirements` 是**能力表达**而不是引擎名（契约 §4.11）：
    /// - 内置引擎 → 1（单连接）；
    /// - aria2 引擎 → 用户设的每文件连接数；
    /// - 自动 → 1，由组件按**真实大小**决定要不要多连接
    ///   （旧实现拿"码率×时长"估算，实测差 5 倍，已废弃）。
    private func segmentsFor(_ task: DownloadTask) -> Int {
        switch settings.engineMode {
        case .builtIn, .auto: return 1
        case .aria2: return max(1, settings.aria2Split)
        }
    }

    /// 引擎分流：**只用于展示与分片意图**，真正的引擎选择在组件里。
    ///
    /// 旧实现会按"码率 × 时长"估算大小来挑引擎，实测那个估算差 5.25 倍
    /// （`docs/02` §E9），所以现在的判据只有两个：用户的设置，以及组件拿到的真实大小。
    private func engineFor(_ task: DownloadTask) -> DownloadEngine {
        switch settings.engineMode {
        case .builtIn, .aria2:
            return settings.engineMode
        case .auto:
            // 展示层面的粗判：知道大小就按阈值，不知道就先算 aria2（组件也会这么判）
            guard XSpiderComponent.locate("aria2next") != nil else { return .builtIn }
            let threshold = Int64(settings.aria2SizeThresholdMB) * 1_048_576
            if task.totalSize > 0 { return task.totalSize > threshold ? .aria2 : .builtIn }
            return .aria2
        }
    }

    /// 暂停：**保留断点**（组件会把半成品留在目标目录，恢复时接着下）。
    /// 与"取消"的区别只在这里——取消会连半成品一起清掉。
    func pause(_ gid: String) {
        update(gid: gid) { $0.status = .paused }
        componentCall("dl.pause", gid)
        refreshSleepAssertion()
    }

    func unpause(_ gid: String) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        start(tasks[index])
    }

    func remove(_ gid: String, alsoDeleteFiles: Bool = false) {
        // 取消 = 丢弃断点并清掉临时文件（组件负责），目标目录保持干净
        componentCall("dl.cancel", gid)
        componentJobs.remove(gid)
        if let index = tasks.firstIndex(where: { $0.gid == gid }) {
            let task = tasks[index]
            if alsoDeleteFiles {
                // 源文件 + 目标目录内引擎临时文件 + 旧 staging 残留
                let destURL = URL(fileURLWithPath: (task.dir as NSString).appendingPathComponent(task.fileName))
                try? fm.removeItem(at: destURL)
                // 组件可能把断点留在目标目录（文件名带引擎标识），一并清掉
                for suffix in [".part.http", ".part.aria2next", ".part.http.aria2", ".part.aria2next.aria2"] {
                    try? fm.removeItem(atPath: (task.dir as NSString)
                        .appendingPathComponent(task.fileName + suffix))
                }
            }
            tasks.remove(at: index)
        }
        pump()
        refreshSleepAssertion()
    }

    func pauseAll() {
        for task in tasks where task.status == .active || task.status == .waiting {
            pause(task.gid)
        }
    }

    func unpauseAll() {
        for task in tasks where task.status == .paused {
            unpause(task.gid)
        }
        refreshSleepAssertion()
    }

    func removeAll(status: DownloadStatus? = nil, alsoDeleteFiles: Bool = false) {
        let toRemove = tasks.filter { status == nil || $0.status == status }
        for task in toRemove { remove(task.gid, alsoDeleteFiles: alsoDeleteFiles) }
    }

    /// 是否已下载过同一媒体——用于主页网格「已下载」禁用态。
    /// recordFile 模式：查目标文件夹记录文件里的媒体 ID；
    /// fileName 模式：下载历史里有同 URL 且完成的任务。
    /// 是否已下载过同一媒体——主页「已下载」判定。
    /// recordFile 模式：目标文件夹记录文件里的媒体 ID（内存缓存,异步落盘同步命中）；
    /// fileName 模式：目标路径真实文件存在性（保存路径 + 用户名子文件夹）,不依赖下载历史。
    func hasDownloaded(media: TwitterMedia, dir: String? = nil, post: TwitterPost? = nil) -> Bool {
        if settings.sameFileCheckModeValue == .recordFile {
            guard let mediaId = media.id, !mediaId.isEmpty else { return false }
            let targetDir = dir ?? settings.download.saveDirBase
            let recordPath = recordFileURL(dir: targetDir).path
            // 只信记录，不回查文件（改文件名/移动文件后依然算已下载 —— 见 isDuplicate 说明）
            return Self.recordCache[recordPath]?.dayIds.contains(mediaId) ?? false
        }
        guard let downloadUrl = downloadURL(for: media) else { return false }
        // 文件名模式:在目标目录找同 URL 派生不出文件名(模板依赖 post/media 数据),
        // 调用方传 dir;这里用任务里最近一次的同 URL 文件名(完成任务携带),再查文件系统
        if let fileName = Self.completedFileNameCache[downloadUrl] {
            let targetDir = dir ?? settings.download.saveDirBase
            return fm.fileExists(atPath: (targetDir as NSString).appendingPathComponent(fileName))
        }
        // 本会话尚未下载过它：按当前模板算出带索引的名字，直接查一次文件系统
        // （否则网格里的按钮状态在"以前已下载"时不会显示为已下载）
        if let post, let dir {
            let raw = FileNameTemplate.resolve(template: settings.download.fileNameTemplate,
                                               data: FileNameTemplateData(post: post, media: media))
            let judged = fileNameWithIndex(raw, media: media, post: post, template: settings.download.fileNameTemplate)
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(judged)) { return true }
            // 兼容升级前的旧命名
            return fm.fileExists(atPath: (dir as NSString).appendingPathComponent(raw))
        }
        return false
    }

    /// URL → 最近完成文件名缓存（fileName 模式的文件存在判定需要）
    private static var completedFileNameCache: [String: String] = [:]

    func redownload(_ gid: String) async {
        guard let task = tasks.first(where: { $0.gid == gid }) else { return }
        remove(gid)
        _ = await createDownloadTask(post: task.post, media: task.media)
    }

    func batchRedownload(_ gids: [String]) async {
        for gid in gids {
            await redownload(gid)
        }
    }

    // MARK: - 任务更新

    func update(gid: String, now: Date = Date(), _ mutation: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        var task = tasks[index]
        if task.updatedAt > now { return }
        mutation(&task)
        task.updatedAt = now
        tasks[index] = task
    }

    // MARK: - 下载完成回调（DownloadDelegate / Aria2Engine 调用）

    /// URLSession 引擎的完成回调
    // MARK: - 组件事件轮询

    /// 起一个轮询任务（幂等）：只要还有 active/waiting 就活着，全静下来就自己结束。
    ///
    /// 为什么用轮询而不是流：契约的三种形态（HTTP / stdio / C ABI）都不支持推送流，
    /// 统一用"带游标的增量 + 列表对账"才可能三形态行为一致（ADR-029）。
    /// 400ms 是**外壳自己的节流**——组件按事件发，多久刷新由调用方决定。
    private func startComponentPolling() {
        guard componentPoller == nil else { return }
        componentPoller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = self.tasks.contains { $0.status == .active || $0.status == .waiting }
                if !busy && self.componentJobs.isEmpty {
                    self.componentPoller = nil
                    return
                }
                await self.pollComponentOnce()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    /// 拉一次增量事件 + 一次列表对账。
    ///
    /// 两个都要：事件用来画进度（增量日志），而"结束了没有"必须问 `dl.list`
    /// ——外壳崩溃重连之后只有它是权威的（`docs/07-API-REFERENCE.md` §5）。
    private func pollComponentOnce() async {
        do {
            let events = try await XSpiderComponent.shared.call("dl.events", ["since": .int(Int(componentCursor))])
            componentCursor = UInt64(events[int: "seq"] ?? Int(componentCursor))
            for event in events[array: "events"] ?? [] {
                applyComponentEvent(event)
            }

            let list = try await XSpiderComponent.shared.call("dl.list")
            for job in (list[array: "jobs"] ?? []).compactMap({ $0.asObject }) {
                reconcile(job)
            }
        } catch {
            // 传输抖动不该让整轮崩：下一轮再试（组件内部对单次请求已重试过）
            AppLogger.debug("组件轮询失败（下一轮再试）", category: "DL", [
                "error": error.localizedDescription,
            ])
        }
    }

    /// 单个事件的即时反应（进度、完成、失败）。
    private func applyComponentEvent(_ event: JSONValue) {
        guard let fields = event.asObject,
              let jobId = fields[string: "job_id"],
              tasks.contains(where: { $0.gid == jobId }) else { return }
        switch fields[string: "kind"] {
        case "progress":
            let done = Int64(fields[int: "done"] ?? 0)
            let total = Int64(fields[int: "total"] ?? 0)
            update(gid: jobId) { task in
                task.completeSize = max(task.completeSize, done)   // 单调不减
                if total > 0 { task.totalSize = total }
                if task.status != .active { task.status = .active }
            }
        case "completed":
            let bytes = Int64(fields[int: "bytes"] ?? 0)
            finalizeComponentDownload(gid: jobId, reportedBytes: bytes)
        case "failed":
            let reason = fields[string: "reason"] ?? "unknown"
            let message = (fields[object: "error"])?[string: "message"] ?? reason
            handleComponentFailure(gid: jobId, reason: reason,
                                   status: fields[object: "error"]?[int: "status"], message: message)
        case "skipped":
            // 文件已经在且大小对：直接算完成（不重复下载）
            update(gid: jobId) { $0.status = .complete }
            componentJobs.remove(jobId)
            pump()
        default:
            break
        }
    }

    /// 用 `dl.list` 的权威状态对账（事件可能漏、也可能被我们中途接手）。
    private func reconcile(_ job: [String: JSONValue]) {
        guard let jobId = job[string: "job_id"], tasks.contains(where: { $0.gid == jobId }) else { return }
        let state = job[string: "state"] ?? "unknown"
        let done = Int64(job[int: "done"] ?? 0)
        let total = Int64(job[int: "total"] ?? 0)
        update(gid: jobId) { task in
            task.completeSize = max(task.completeSize, done)
            if total > 0 { task.totalSize = total }
            switch state {
            case "waiting":
                // 组件自己在排队（并发额度），保持 active 的展示语义即可
                if task.status != .active { task.status = .active }
            case "active":
                task.status = .active
            case "paused":
                task.status = .paused
            case "complete":
                task.status = .complete
                task.error = nil
            case "error":
                if task.status != .error { task.status = .error }
            default:
                break
            }
        }
        if state == "complete" || state == "error" {
            componentJobs.remove(jobId)
            // 组件报"完成"之后，应用自己再验一遍内容（见 finalizeComponentDownload 的说明）
            if state == "complete", tasks.first(where: { $0.gid == jobId })?.status == .complete {
                // finalizeComponentDownload 已处理过收尾；这里只兜底清账
                if !finalized.contains(jobId) {
                    finalizeComponentDownload(gid: jobId, reportedBytes: done)
                }
            }
        }
    }

    /// 收尾：内容校验 → 记录 → 通知 → 让出并发槽位。
    ///
    /// **为什么应用还要自己验一遍**：组件回答的是"字节数与服务端声明一致"，
    /// 而 CDN 出错时可能返回一个 HTML 错误页、字节数还可能是对的。
    /// 所以"这是不是一张真的图/真的 mp4"留在应用侧判（`docs/06` §5.4 的分工）。
    private func finalizeComponentDownload(gid: String, reportedBytes: Int64) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        let task = tasks[index]
        finalized.insert(gid)
        defer {
            componentJobs.remove(gid)
            pump()
            refreshSleepAssertion()
        }

        let destPath = (task.dir as NSString).appendingPathComponent(task.fileName)
        let expected = reportedBytes > 0 ? reportedBytes : task.totalSize
        switch FileIntegrity.verify(path: destPath, expectedTotal: expected, type: task.media.type) {
        case .failure(let reason):
            AppLogger.warn("下载内容校验未通过,按失败处理", category: "DL", [
                "file": task.fileName,
                "reason": reason.errorDescription ?? "?",
            ])
            cleanupFailedArtifacts(task: task, path: destPath)
            handleTaskError(gid: gid, error: reason)
        case .success(let size):
            update(gid: gid) {
                $0.status = .complete
                $0.completeSize = size
                $0.totalSize = size
                $0.error = nil
            }
            AppLogger.info("下载完成", category: "DL", [
                "file": task.fileName, "size": "\(size)",
                "user": task.post.user.screenName,
                "engine": task.engine?.rawValue ?? settings.engine.rawValue,
            ])
            Self.completedFileNameCache[task.downloadUrl] = task.fileName
            recordDownloaded(mediaId: task.media.id, created: task.media.createdTime,
                             dir: task.dir, fileName: task.fileName)
            AccountStatusStore.shared.noteCDNSuccess()
        }
    }

    /// 组件的结构化失败 → 应用的重试/状态机。
    ///
    /// **只按结构化字段判断**（`reason` / `error.code` / `error.status`），
    /// 绝不匹配文案——那是契约里明令禁止的（旧实现曾按 aria2 的输出文案判断能否重试，
    /// 引擎一换就全错）。
    private func handleComponentFailure(gid: String, reason: String, status: Int?, message: String) {
        componentJobs.remove(gid)
        finalized.remove(gid)
        let error = ComponentDownloadError(reason: reason, status: status, message: message)
        reportComponentCDNOutcome(reason: reason, status: status)
        handleTaskError(gid: gid, error: error)
    }

    /// 入队就失败（连不上组件 / 参数不对）：不重试，直接把话说清楚。
    private func handleComponentLaunchFailure(gid: String, error: Error) {
        componentJobs.remove(gid)
        update(gid: gid) {
            $0.status = .error
            $0.error = error.localizedDescription
        }
        notify(title: "任务下载失败", body: "\(tasks.first(where: { $0.gid == gid })?.fileName ?? "")\n\(error.localizedDescription)")
        pump()
        refreshSleepAssertion()
    }

    /// 组件的 CDN 相关失败上报给状态行（只有 429 / 4xx 才写，避免把磁盘错误误报成 CDN 异常）。
    private func reportComponentCDNOutcome(reason: String, status: Int?) {
        if status == 429 || reason == "rate_limited" {
            AccountStatusStore.shared.noteCDNRateLimited(retryAfter: nil)
        } else if let status, [403, 404, 410, 451].contains(status) {
            AccountStatusStore.shared.noteCDNFailure("HTTP \(status)")
        }
    }

    /// 发一条不关心结果的组件调用（暂停/取消这类"尽力而为"的操作）。
    private func componentCall(_ method: String, _ gid: String) {
        Task { [weak self] in
            do {
                _ = try await XSpiderComponent.shared.call(method, ["job_id": .string(gid)])
            } catch {
                AppLogger.debug("组件调用 \(method) 失败", category: "DL", [
                    "gid": gid, "error": error.localizedDescription,
                ])
                _ = self  // 保持闭包对 self 的弱引用语义
            }
        }
    }

    private func handleTaskError(gid: String, error: Error) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        let task = tasks[index]
        let retryable = isRetryable(error)

        // CDN 侧结果上报（被动）：驱动侧边栏第二行与并发降级
        reportComponentCDNOutcome(reason: (error as? ComponentDownloadError)?.reason ?? "unknown",
                                  status: (error as? ComponentDownloadError)?.status)

        if retryable, task.retryCountRemains > 0 {
            let attempt = 5 - task.retryCountRemains          // 0,1,2,3,4
            let delay = min(16.0, pow(2.0, Double(attempt)))  // 1,2,4,8,16
            AppLogger.warn("任务失败将重试", category: "DL", [
                "file": task.fileName,
                "remains": "\(task.retryCountRemains)",
                "backoffSec": String(format: "%.0f", delay),
                "error": error.localizedDescription,
            ])
            update(gid: gid) {
                $0.status = .waiting
                $0.retryCountRemains -= 1
                $0.error = error.localizedDescription
            }
            let retryGid = gid
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if let t = self.tasks.first(where: { $0.gid == retryGid }), t.status == .waiting {
                    self.pump()
                }
            }
        } else {
            update(gid: gid) {
                $0.status = .error
                $0.error = error.localizedDescription
            }
            AppLogger.error("任务下载失败", category: "DL", [
                "file": task.fileName, "user": task.post.user.screenName,
                "retryable": retryable ? "yes" : "no",
                "error": error.localizedDescription,
            ])
            notify(title: "任务下载失败", body: "\(task.fileName)\n\(error.localizedDescription)")
            pump()
            refreshSleepAssertion()
        }
    }

    /// 是否值得重试。**只看结构化字段**：`reason`（组件给的短标签）与 `status`（HTTP 码）。
    ///
    /// 这里正是"不许按文案判断"的发源地：旧实现按 aria2 的输出文案（`exit 3` / `404`）
    /// 猜能不能重试，引擎一换就全错——现在 `reason` 是组件用**数字错误码**映射出来的。
    private func isRetryable(_ error: Error) -> Bool {
        if let failure = error as? FileIntegrity.Failure {
            switch failure {
            case .htmlErrorPage, .notAnImage: return false  // 内容不对，重试无用
            case .missing, .empty, .truncated: return true  // 可能被限流/中断，值得重试
            }
        }
        if let componentError = error as? ComponentDownloadError {
            if let status = componentError.status {
                switch status {
                case 403, 404, 410, 451: return false
                case 429, 500, 502, 503, 504: return true
                default: return status >= 500
                }
            }
            switch componentError.reason {
            case "not_found", "invalid", "integrity_failed", "disk_full", "permission_denied":
                return false
            default:
                return true   // transport / upstream / cancelled 之外的都值得再试
            }
        }
        return true
    }

    /// 清理某任务的失败残留：目标文件 + 组件留下的断点（`.part.http` / `.part.aria2next`）。
    ///
    /// 不清理的话，下次续传会把半截文件当"已下载"接着写，拼出损坏文件——
    /// 这是参考实现里验证过的一条（`docs/02` §E4）。
    private func cleanupFailedArtifacts(task: DownloadTask, path: String) {
        try? fm.removeItem(atPath: path)
        for suffix in [".part.http", ".part.aria2next", ".part.http.aria2", ".part.aria2next.aria2"] {
            try? fm.removeItem(atPath: path + suffix)
        }
    }

    /// 等到所有任务离开 active/waiting(下载完成或失败)。
    /// 每 2s 轮询;用于批量下载后关机前的等待。
    func waitUntilAllSettled() async {
        while tasks.contains(where: { $0.status == .active || $0.status == .waiting }) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - 系统通知（上游 notification.sendNotification）

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// 组件报回来的下载失败（**结构化**：reason 是短标签，status 是 HTTP 码）。
///
/// 单独包一层而不是直接把组件的 `ComponentError` 传来传去：下载侧要的是
/// "重试不重试"这一个判断，而它只用得上 reason 与 status 两个字段。
struct ComponentDownloadError: LocalizedError {
    let reason: String
    let status: Int?
    let message: String

    var errorDescription: String? { message.isEmpty ? reason : message }
}
