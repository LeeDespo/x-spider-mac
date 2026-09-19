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
                    pathsToDelete.append((task.dir as NSString).appendingPathComponent(task.fileName))
                    let tmpName = tmpFileName(for: task)
                    let dirURL = URL(fileURLWithPath: task.dir)
                    pathsToDelete.append(dirURL.appendingPathComponent(tmpName).path)
                    pathsToDelete.append(dirURL.appendingPathComponent(tmpName + ".aria2").path)
                    // 旧版 staging 位置兼容清理
                    let legacy = AppDirectories.staging.appendingPathComponent(legacyAria2FileName(for: task))
                    pathsToDelete.append(legacy.path)
                    pathsToDelete.append(legacy.path + ".aria2")
                    // URLSession 引擎的新位置 tmp(带 UUID 无法精确匹配,按前缀清理交给 resolveStale)
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

    /// 引擎内部状态（resumeData、进行中的 URLSession 任务）
    private var sessionTasks: [String: URLSessionDownloadTask] = [:]
    /// aria2 引擎（进程管理）
    private let aria2 = Aria2Engine.shared
    /// aria2 任务 → 暂存文件路径（完成后原子移动到目标位置）
    private var aria2StagingPaths: [String: URL] = [:]
    private var resumeDataMap: [String: Data] = [:]
    private var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    private var settings: Settings { SettingsStore.shared.settings }
    private let fm = FileManager.default

    private init() {
        restoreTasks()
        loadRecordCaches()
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

    func batchCreateDownloadTasks(_ paramsList: [(post: TwitterPost, media: TwitterMedia)]) async {
        for params in paramsList {
            _ = await createDownloadTask(post: params.post, media: params.media, silent: true)
        }
    }

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

    private static let historyURL = AppDirectories.support
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

    /// 实际拉起（引擎分发），供 pump 与恢复场景使用
    private func launch(_ task: DownloadTask) {
        guard let url = URL(string: task.downloadUrl) else {
            update(gid: task.gid) { $0.status = .error; $0.error = "无效的下载地址" }
            return
        }
        try? fm.createDirectory(atPath: task.dir, withIntermediateDirectories: true)
        let engine = engineFor(task)
        // 记录本次实际使用的引擎：恢复时据此判断引擎是否变更（变更则丢弃断点重下）
        let previousEngine = task.engine
        update(gid: task.gid) { $0.status = .active; $0.engine = engine }
        AppLogger.debug("任务开始下载", category: "DL", [
            "gid": task.gid, "engine": engine.rawValue,
            "file": task.fileName, "user": task.post.user.screenName,
        ])

        // 引擎切换过：丢弃另一引擎遗留的断点与半成品，从头下载
        // （resumeData 是 URLSession 独有的，aria2 无法续写；混合会导致损坏文件）
        if let previousEngine, previousEngine != engine {
            resumeDataMap.removeValue(forKey: task.gid)
            discardPartialArtifacts(for: task)
            AppLogger.info("引擎已变更,丢弃断点重新下载", category: "DL", [
                "file": task.fileName,
                "from": previousEngine.rawValue, "to": engine.rawValue,
            ])
        }

        if engine == .aria2, Aria2Engine.isAvailable {
            launchAria2(task, proxy: currentProxyArgument())
            return
        }

        launchBuiltIn(task, url: url)
    }

    /// 引擎分流。auto = 按**文件大小**而非媒体类型：
    /// aria2 的价值是多连接分块与跨会话续传，收益随文件增大而显现；小图走内置更省开销，
    /// 也少一层"进程/RPC 是否就绪"的失败面。
    ///
    /// 大小判据优先用 `totalSize`（进度回调或历史记录已知），未知时按媒体元数据估算；
    /// **不发额外请求探测**（CDN 请求同样消耗配额）。
    private func engineFor(_ task: DownloadTask) -> DownloadEngine {
        switch settings.engineMode {
        case .builtIn:
            return .builtIn
        case .aria2:
            return .aria2
        case .auto:
            guard Aria2Engine.isAvailable else { return .builtIn }
            let threshold = Int64(settings.aria2SizeThresholdMB) * 1_048_576
            let known = task.totalSize > 0 ? task.totalSize : estimatedSize(task.media)
            if known <= 0 {
                // 大小未知：视频/GIF 体积通常远大于阈值，照片走内置
                return (task.media.type == .video || task.media.type == .gif) ? .aria2 : .builtIn
            }
            return known > threshold ? .aria2 : .builtIn
        }
    }

    /// 从媒体元数据粗估字节数（仅用于引擎选择，不求精确）
    private func estimatedSize(_ media: TwitterMedia) -> Int64 {
        // 视频：最高码率(bits/s) × 时长(s) ÷ 8
        if let variants = media.videoInfo?.variants,
           let best = variants.compactMap(\.bitrate).max(),
           let ms = media.videoInfo?.duration, ms > 0 {
            return Int64(Double(best) * (ms / 1000.0) / 8.0)
        }
        // 图片：按像素粗估（原图约 0.5 字节/像素，量级够用）
        if let w = media.width, let h = media.height, w > 0, h > 0 {
            return Int64(Double(w * h) * 0.5)
        }
        return 0
    }

    /// 当前代理参数（手动代理优先，其次系统代理）——aria2c 不继承系统代理需显式传
    private func currentProxyArgument() -> String? {
        let proxy = settings.proxy
        if proxy.enable, !proxy.useSystem, !proxy.url.isEmpty { return proxy.url }
        if proxy.useSystem { return Aria2Engine.systemProxy() }
        return nil
    }

    /// 丢弃某任务在目标目录内的半成品与断点（引擎切换/重下前调用）
    private func discardPartialArtifacts(for task: DownloadTask) {
        let dir = task.dir
        let names = [tmpFileName(for: task), tmpFileName(for: task) + ".aria2",
                     legacyAria2FileName(for: task), legacyAria2FileName(for: task) + ".aria2"]
        for name in names {
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        }
        aria2StagingPaths.removeValue(forKey: task.gid)
    }

    private func launchAria2(_ task: DownloadTask, proxy: String?) {
        // 手动代理(非系统)时的身份验证凭证注入
        let proxySettings = settings.proxy
        if !proxySettings.useSystem, proxySettings.enable, let user = proxySettings.username, !user.isEmpty {
            Aria2Engine.proxyCredential = (user, proxySettings.password ?? "")
        } else {
            Aria2Engine.proxyCredential = nil
        }
        aria2.progressHandler = { [weak self] gid, done, total in
            Task { @MainActor in
                self?.update(gid: gid) {
                    $0.completeSize = done
                    if total > 0 { $0.totalSize = total }
                }
            }
        }
        aria2.pauseHandler = { [weak self] gid in
            Task { @MainActor in
                self?.update(gid: gid) { $0.status = .paused }
                self?.pump()
                self?.refreshSleepAssertion()
            }
        }
        aria2.completionHandler = { [weak self] gid, result in
            Task { @MainActor in
                switch result {
                case .success(let fileURL):
                    self?.finalizeDownload(gid: gid, stagedFile: fileURL)
                case .failure(let error):
                    self?.handleTaskError(gid: gid, error: error)
                }
            }
        }
        // 临时文件直接放目标目录（免拷贝），统一用 tmpFileName 命名，
        // 保证清理时能准确删除（旧实现两种命名并存，删的是从未创建的路径）
        let stagingName = tmpFileName(for: task)
        aria2StagingPaths[task.gid] = URL(fileURLWithPath: (task.dir as NSString).appendingPathComponent(stagingName))
        aria2.start(
            gid: task.gid, urlString: task.downloadUrl,
            destDir: task.dir,
            fileName: stagingName,
            proxy: proxy,
            connections: settings.aria2Split,
            fileAllocation: settings.aria2FileAllocation
        )
    }

    /// 统一的引擎临时文件名：`.xspider-tmp-<gid>-<原名>`（目标目录内，隐藏前缀防重名）。
    /// 两种引擎共用同一个名字——此前 aria2 用 `<gid>-<name>`、URLSession 用
    /// `.xspider-tmp-urlsession-<uuid>`、而 `aria2StagingPaths` 记的是第三种，
    /// 导致删除清理时删的是一个从未被创建的路径（残留永远留在用户目录）。
    private func tmpFileName(for task: DownloadTask) -> String {
        let safe = task.fileName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return ".xspider-tmp-\(task.gid)-\(safe)"
    }

    /// 历史遗留的 aria2 临时命名（`<gid>-<name>`）：仅用于清理旧版本残留。
    /// 新任务不再使用，保留此函数以免旧残留永远删不掉。
    private func legacyAria2FileName(for task: DownloadTask) -> String {
        let safe = task.fileName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(task.gid)-\(safe)"
    }

    /// 内置 URLSession 引擎分支体（launch 尾部调用）
    private func launchBuiltIn(_ task: DownloadTask, url: URL) {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://x.com", forHTTPHeaderField: "Referer")

        let sessionTask: URLSessionDownloadTask
        if let resumeData = resumeDataMap[task.gid] {
            sessionTask = session.downloadTask(withResumeData: resumeData)
            resumeDataMap.removeValue(forKey: task.gid)
        } else {
            sessionTask = session.downloadTask(with: request)
        }

        let gid = task.gid
        let delegate = DownloadDelegate(store: self, gid: gid, dir: task.dir)
        sessionTask.delegate = delegate
        sessionTask.resume()
        sessionTasks[gid] = sessionTask
    }

    func pause(_ gid: String) {
        guard let task = sessionTasks[gid] else {
            // aria2 引擎的任务
            aria2.pause(gid: gid)
            update(gid: gid) { $0.status = .paused }
            pump()
            refreshSleepAssertion()
            return
        }
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                if let data { self?.resumeDataMap[gid] = data }
                self?.sessionTasks.removeValue(forKey: gid)
                self?.update(gid: gid) { $0.status = .paused }
                self?.refreshSleepAssertion()
            }
        })
    }

    func unpause(_ gid: String) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        start(tasks[index])
    }

    func remove(_ gid: String, alsoDeleteFiles: Bool = false) {
        sessionTasks[gid]?.cancel()
        sessionTasks.removeValue(forKey: gid)
        aria2.cancel(gid: gid)
        // 引擎临时文件(现在位于目标目录内;兼容旧版 staging 位置)
        if let tmp = aria2StagingPaths.removeValue(forKey: gid) {
            try? fm.removeItem(at: tmp)
            try? fm.removeItem(at: URL(fileURLWithPath: tmp.path + ".aria2"))
        }
        resumeDataMap.removeValue(forKey: gid)
        if let index = tasks.firstIndex(where: { $0.gid == gid }) {
            let task = tasks[index]
            if alsoDeleteFiles {
                // 源文件 + 目标目录内引擎临时文件 + 旧 staging 残留
                let destURL = URL(fileURLWithPath: (task.dir as NSString).appendingPathComponent(task.fileName))
                try? fm.removeItem(at: destURL)
                let tmpName = tmpFileName(for: task)
                try? fm.removeItem(at: URL(fileURLWithPath: (task.dir as NSString).appendingPathComponent(tmpName)))
                try? fm.removeItem(at: URL(fileURLWithPath: (task.dir as NSString).appendingPathComponent(tmpName + ".aria2")))
                let legacyStaging = legacyAria2FileName(for: task)
                try? fm.removeItem(at: AppDirectories.staging.appendingPathComponent(legacyStaging))
                try? fm.removeItem(at: AppDirectories.staging.appendingPathComponent(legacyStaging + ".aria2"))
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
    func handleDownloadCompleted(gid: String, localURL: URL?, response: URLResponse?, error: Error?) {
        defer {
            sessionTasks.removeValue(forKey: gid)
            // 失败路径：目标目录内的稳定临时文件清理（成功路径由 finalizeDownload rename 消化）
            if let localURL,
               localURL.lastPathComponent.hasPrefix(".xspider-tmp-"),
               error != nil {
                try? fm.removeItem(at: localURL)
            }
        }

        if let error {
            handleTaskError(gid: gid, error: error)
            return
        }
        guard let localURL else {
            update(gid: gid) { $0.status = .error; $0.error = "本地文件缺失" }
            AppLogger.error("下载完成但本地文件缺失", category: "DL", ["gid": gid])
            return
        }
        finalizeDownload(gid: gid, stagedFile: localURL)
    }

    /// 统一错误处理：可重试 → **指数退避**后重新排队；不可重试或重试耗尽 → error + 通知。
    ///
    /// 两点改进（对应"提升下载稳定性"）：
    /// 1. **指数退避**（1/2/4/8/16s）：固定 1s 在限流场景下等于持续敲门，会加重限流。
    /// 2. **区分可否重试**：403/404/410 与"内容不是媒体/不是图片"再试也不会成功，
    ///    直接终结（原先一律重试 5 次，纯属放大限流）。
    private func handleTaskError(gid: String, error: Error) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        let task = tasks[index]
        let retryable = isRetryable(error)

        // CDN 侧结果上报（被动）：驱动侧边栏第二行与并发降级
        reportCDNOutcome(error)

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

    /// 是否值得重试。资源不存在/无权限/内容根本不是媒体 → 重试无用且会放大限流。
    private func isRetryable(_ error: Error) -> Bool {
        if let failure = error as? FileIntegrity.Failure {
            switch failure {
            case .htmlErrorPage, .notAnImage: return false  // 内容不对，重试无用
            case .missing, .empty, .truncated: return true  // 可能被限流/中断，值得重试
            }
        }
        if let netError = error as? NetworkError, case .httpStatus(let code) = netError {
            switch code {
            case 403, 404, 410, 451: return false
            case 429, 500, 502, 503, 504: return true
            default: return code >= 500
            }
        }
        if let engineError = error as? EngineError, case .failed(let message) = engineError {
            // aria2 把 HTTP 状态写进错误文案（exit 3 = 资源未找到，exit 13 = 文件已存在）
            if message.contains("exit 3") || message.contains("exit 13") { return false }
            if message.contains("404") || message.contains("403") { return false }
            return true
        }
        return true
    }

    /// 把下载失败按类型上报到状态（CDN 行）。只对 CDN 相关错误写 CDN 状态，
    /// 避免把本地磁盘错误误报成"媒体服务器异常"。
    private func reportCDNOutcome(_ error: Error) {
        if let netError = error as? NetworkError, case .httpStatus(let code) = netError, code == 429 {
            AccountStatusStore.shared.noteCDNRateLimited(retryAfter: nil)
            return
        }
        let message = error.localizedDescription
        if message.contains("429") {
            AccountStatusStore.shared.noteCDNRateLimited(retryAfter: nil)
        } else if message.contains("404") || message.contains("403") || message.contains("exit 3") {
            AccountStatusStore.shared.noteCDNFailure(message)
        }
    }

    /// 把暂存文件落盘到目标位置并更新状态（URLSession 与 aria2 共用）。
    ///
    /// **完整性校验是唯一的成功判据**：实测 aria2 失败时会留下 0 字节文件，旧代码
    /// 只看"文件存在"就判成功 → 坏文件被标记完成、写进下载记录、永不重试（成批损坏的根因）。
    private func finalizeDownload(gid: String, stagedFile: URL) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else {
            try? fm.removeItem(at: stagedFile)
            return
        }
        let task = tasks[index]

        // 移动到目标目录（aria2 已在目标位置；URLSession 的临时文件需立即搬运）
        let destURL = URL(fileURLWithPath: (task.dir as NSString).appendingPathComponent(task.fileName))
        try? fm.createDirectory(atPath: task.dir, withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
            if stagedFile.standardizedFileURL.path == destURL.standardizedFileURL.path {
                // aria2 直接写到目标位置
            } else {
                try fm.moveItem(at: stagedFile, to: destURL)
            }
        } catch {
            // 临时文件即将被系统删除：move 失败时先拷贝兜底，仍失败才报错
            do {
                try? fm.removeItem(at: destURL)
                try fm.copyItem(at: stagedFile, to: destURL)
            } catch {
                update(gid: gid) { $0.status = .error; $0.error = error.localizedDescription }
                AppLogger.error("下载文件落盘失败", category: "DL", [
                    "file": task.fileName, "error": error.localizedDescription,
                ])
                notify(title: "任务下载失败", body: "\(task.fileName)\n文件写入失败: \(error.localizedDescription)")
                cleanupFailedArtifacts(task: task, path: destURL.path)
                pump()
                refreshSleepAssertion()
                return
            }
        }

        // 落盘完成 → 校验内容（0 字节 / 大小不符 / 错误页 / 非图片一律判失败并重试）
        let expected = task.totalSize
        switch FileIntegrity.verify(path: destURL.path, expectedTotal: expected, type: task.media.type) {
        case .failure(let reason):
            AppLogger.warn("下载内容校验未通过,按失败处理", category: "DL", [
                "file": task.fileName,
                "reason": reason.errorDescription ?? "?",
                "bytes": "\(((try? fm.attributesOfItem(atPath: destURL.path)[.size]) as? Int64) ?? 0)",
            ])
            // 清掉坏文件与 .aria2 控制文件，避免下次 --continue 读到脏状态拼出损坏文件
            cleanupFailedArtifacts(task: task, path: destURL.path)
            handleTaskError(gid: gid, error: reason)
            return
        case .success(let size):
            update(gid: gid) {
                $0.status = .complete
                $0.completeSize = size
                $0.totalSize = size
                $0.error = nil
            }
            AppLogger.info("下载完成", category: "DL", [
                "file": task.fileName, "size": "\(size)", "user": task.post.user.screenName,
                "engine": task.engine?.rawValue ?? SettingsStore.shared.settings.engine.rawValue,
            ])
            Self.completedFileNameCache[task.downloadUrl] = task.fileName
            recordDownloaded(mediaId: task.media.id, created: task.media.createdTime, dir: task.dir, fileName: task.fileName)
            // CDN 恢复正常：清除限流标记，让并发恢复（若此前被降级）
            AccountStatusStore.shared.noteCDNSuccess()
            pump()
            refreshSleepAssertion()
        }
    }

    /// 清理某任务的失败残留：目标位置半成品 + aria2 控制文件 + 临时文件 + 旧 staging 位置。
    /// 不清理的话，下次 --continue 会把 0 字节/半截文件当"已下载"续写，拼出损坏文件。
    private func cleanupFailedArtifacts(task: DownloadTask, path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + ".aria2")
        // 目标目录内的引擎临时文件（统一命名后与 tmpFileName 一致）
        let dir = task.dir
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(tmpFileName(for: task)))
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(tmpFileName(for: task) + ".aria2"))
        // 兼容历史遗留命名（<gid>-<name>，早期版本用过）
        let legacy = (dir as NSString).appendingPathComponent(legacyAria2FileName(for: task))
        try? fm.removeItem(atPath: legacy)
        try? fm.removeItem(atPath: legacy + ".aria2")
        aria2StagingPaths.removeValue(forKey: task.gid)
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

// MARK: - URLSession 代理（进度 + 完成）

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let store: DownloadStore
    let gid: String
    /// 目标目录（稳定临时文件直接放这里,免二次拷贝）
    let taskDir: String

    init(store: DownloadStore, gid: String, dir: String) {
        self.store = store
        self.gid = gid
        self.taskDir = dir
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.store.update(gid: self.gid) {
                $0.completeSize = totalBytesWritten
                if totalBytesExpectedToWrite > 0 { $0.totalSize = totalBytesExpectedToWrite }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 关键：必须在回调返回前同步处理——回调返回后系统会删除 location 临时文件。
        // 稳定位置直接放目标目录（.xspider-tmp- 前缀）：这一次拷贝是跨卷/跨目录的必经一步,
        // 之后的 finalize 是同卷 rename,零拷贝。
        let destDir = self.taskDir
        let stableURL = URL(fileURLWithPath: (destDir as NSString)
            .appendingPathComponent(".xspider-tmp-urlsession-\(UUID().uuidString)"))
        do {
            try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: stableURL)
            try FileManager.default.copyItem(at: location, to: stableURL)
            Task { @MainActor in
                self.store.handleDownloadCompleted(gid: self.gid, localURL: stableURL, response: downloadTask.response, error: nil)
            }
        } catch {
            struct TempCopyError: LocalizedError { let errorDescription: String? }
            let msg = TempCopyError(errorDescription: "临时文件拷贝失败: \(error.localizedDescription)")
            Task { @MainActor in
                self.store.handleDownloadCompleted(gid: self.gid, localURL: nil, response: downloadTask.response, error: msg)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.store.handleDownloadCompleted(gid: self.gid, localURL: nil, response: task.response, error: error)
        }
    }
}
