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

    /// 删除当前 Tab + 用户筛选范围内的记录；alsoDeleteFiles = 同时删除源文件与未完成临时文件
    func removeVisibleRecords(statuses: [DownloadStatus], alsoDeleteFiles: Bool = false) {
        let targets = tasksForCurrentTab(statuses: statuses).map(\.gid)
        for gid in targets { remove(gid, alsoDeleteFiles: alsoDeleteFiles) }
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
    }

    /// 启动时扫描各用户文件夹的记录文件到内存缓存（避免覆盖旧记录）
    /// 保存路径/子文件夹设置变更时调用:重载记录缓存 + 清完成文件名缓存(判定立即刷新)
    func refreshDownloadedCaches() {
        Self.recordCache.removeAll()
        Self.completedFileNameCache.removeAll()
        loadRecordCaches()
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
                // 全量格式 { downloaded: [...] }；兼容旧锚定格式 { anchorDay, dayIds }（读入 dayIds）
                if let list = obj["downloaded"] as? [String] {
                    Self.recordCache[full] = RecordEntry(anchorDay: "", dayIds: list)
                    loaded += 1
                } else if let list = obj["dayIds"] as? [String] {
                    Self.recordCache[full] = RecordEntry(anchorDay: "", dayIds: list)
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
    func createDownloadTask(post: TwitterPost, media: TwitterMedia) async -> DownloadTask? {
        guard let downloadUrl = downloadURL(for: media) else {
            AppLogger.warn("媒体没有下载链接", category: "DL", ["mediaId": media.id ?? "nil", "type": media.type.rawValue])
            return nil
        }

        let templateData = FileNameTemplateData(post: post, media: media)
        let dir = targetDir(for: post)
        var fileName = FileNameTemplate.resolve(template: settings.download.fileNameTemplate, data: templateData)
        // 仅记录文件模式追加媒体 ID 锁定段（保证同名歧义下唯一；按文件名模式不加）
        if settings.download.sameFileSkip, settings.sameFileCheckModeValue == .recordFile {
            fileName = lockedFileName(fileName, mediaId: media.id)
        }

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

        // sameFileSkip：按当前判定依据决定跳过
        if settings.download.sameFileSkip {
            if isDuplicate(media: media, fileName: fileName, dir: dir) {
                return nil
            }
        }

        AppLogger.info("创建下载任务", category: "DL", ["file": fileName, "dir": dir, "url": downloadUrl, "mediaId": media.id ?? "?"])
        tasks.append(task)
        start(task)
        SleepPreventer.shared.update(activeDownloadCount: tasks.count { $0.status == .active || $0.status == .waiting })
        return task
    }

    func batchCreateDownloadTasks(_ paramsList: [(post: TwitterPost, media: TwitterMedia)]) async {
        for params in paramsList {
            _ = await createDownloadTask(post: params.post, media: params.media)
        }
    }

    // MARK: - 跳过相同文件判定

    /// 判定依据（设置里可选）：
    /// - fileName：目标文件已存在（文件系统检查）
    /// - recordFile：用户文件夹下的记录文件里已有该媒体 ID（跨文件名模板改动仍然有效）
    /// - recordFile 模式下文件名强制追加媒体 ID 锁定段（模板里已有 %MEDIA_ID% 时不重复）
    private func isDuplicate(media: TwitterMedia, fileName: String, dir: String) -> Bool {
        switch settings.sameFileCheckModeValue {
        case .recordFile:
            // 全量记录判定：记录文件里已有该媒体 ID → 已下载（改文件名模板也不影响）
            guard let mediaId = media.id, !mediaId.isEmpty else { return false }
            let recordURL = recordFileURL(dir: dir)
            if Self.recordCache[recordURL.path]?.dayIds.contains(mediaId) == true {
                AppLogger.info("下载记录命中，跳过", category: "DL", ["mediaId": mediaId, "dir": dir])
                return true
            }
            return false
        case .fileName:
            let filePath = (dir as NSString).appendingPathComponent(fileName)
            if fm.fileExists(atPath: filePath) {
                AppLogger.info("sameFileSkip 跳过已存在文件", category: "DL", ["file": filePath])
                return true
            }
            return false
        }
    }

    /// 记录文件路径（每用户文件夹一份）
    private func recordFileURL(dir: String) -> URL {
        URL(fileURLWithPath: dir).appendingPathComponent(settings.recordFileNameValue)
    }

    /// 时间锚定的记录条目：锚点日期 + 当天媒体 ID 集合
    struct RecordEntry: Codable, Sendable {
        var anchorDay: String        // "yyyy-MM-dd"
        var dayIds: [String]
    }

    /// 各记录文件的缓存（内存态，进程内有效）
    private static var recordCache: [String: RecordEntry] = [:]

    private static func todayString(_ date: Date = Date()) -> String {
        DateFormatter.fallback.string(from: date)
    }

    /// 下载成功后写入记录文件（全量媒体 ID）。开始下载时创建文件；每完成一个任务
    /// 异步落盘一个条目（后台队列串行写,不阻塞下载回调）。
    private func recordDownloaded(mediaId: String?, created: Date?, dir: String) {
        guard settings.sameFileCheckModeValue == .recordFile,
              let mediaId, !mediaId.isEmpty else { return }
        let url = recordFileURL(dir: dir)
        var entry = Self.recordCache[url.path] ?? RecordEntry(anchorDay: "", dayIds: [])
        guard !entry.dayIds.contains(mediaId) else { return }
        entry.dayIds.append(mediaId)
        Self.recordCache[url.path] = entry
        let snapshot = entry.dayIds.sorted()
        Self.recordWriteQueue.async { [weak self] in
            let fm = FileManager.default
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)   // 开始下载即创建记录文件
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: ["downloaded": snapshot])
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

    /// 某推文媒体应保存的目标目录（主页"已下载"判定用）
    func targetDir(for post: TwitterPost) -> String {
        var dir = settings.download.saveDirBase
        if dir.isEmpty,
           let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            dir = downloads.path
        }
        if settings.accountSubfolderEnabled {
            let folderName = "\(post.user.name)-@\(post.user.screenName)".safePathComponent()
            dir = (dir as NSString).appendingPathComponent(folderName)
        }
        return dir
    }

    /// 文件名是否已包含 %MEDIA_ID% 模板变量
    private func templateHasMediaId() -> Bool {
        settings.download.fileNameTemplate.contains("%MEDIA_ID%")
    }

    /// recordFile 模式下给文件名追加媒体 ID 锁定段（模板已有 %MEDIA_ID% 时保持原样）
    private func lockedFileName(_ fileName: String, mediaId: String?) -> String {
        guard settings.download.sameFileSkip,
              !templateHasMediaId(),
              let mediaId, !mediaId.isEmpty else { return fileName }
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let locked = ext.isEmpty ? "\(stem) [\(mediaId)]" : "\(stem) [\(mediaId)].\(ext)"
        return locked
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
    }

    private func persistTasks() {
        let items = tasks.map {
            PersistedTask(gid: $0.gid, post: $0.post, media: $0.media, fileName: $0.fileName,
                          dir: $0.dir, totalSize: $0.totalSize, completeSize: $0.completeSize,
                          statusRaw: $0.status.rawValue, error: $0.error, updatedAt: $0.updatedAt,
                          downloadUrl: $0.downloadUrl, retryCountRemains: $0.retryCountRemains)
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
                downloadUrl: item.downloadUrl, retryCountRemains: item.retryCountRemains
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

    /// 并发调度：把 waiting 任务按序填入空闲并发槽位
    private func pump() {
        let maxConcurrent = SettingsStore.shared.settings.maxConcurrentDownloads
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

    /// 实际拉起（引擎分发），供 pump 与恢复场景使用
    private func launch(_ task: DownloadTask) {
        guard let url = URL(string: task.downloadUrl) else {
            update(gid: task.gid) { $0.status = .error; $0.error = "无效的下载地址" }
            return
        }
        try? fm.createDirectory(atPath: task.dir, withIntermediateDirectories: true)
        update(gid: task.gid) { $0.status = .active }
        AppLogger.debug("任务开始下载", category: "DL", [
            "gid": task.gid, "engine": SettingsStore.shared.settings.engine.rawValue,
            "file": task.fileName, "user": task.post.user.screenName,
        ])

        if SettingsStore.shared.settings.engine == .aria2, Aria2Engine.isAvailable {
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
            let proxyArg: String?
            if settings.proxy.enable, !settings.proxy.useSystem, !settings.proxy.url.isEmpty {
                proxyArg = settings.proxy.url          // 手动代理
            } else if settings.proxy.useSystem {
                proxyArg = Aria2Engine.systemProxy()   // 系统代理显式读取（aria2c 不继承）
            } else {
                proxyArg = nil
            }
            let stagingURL = AppDirectories.staging.appendingPathComponent(aria2FileName(for: task))
            aria2StagingPaths[task.gid] = stagingURL
            aria2.start(
                gid: task.gid, urlString: task.downloadUrl,
                destDir: AppDirectories.staging.path,
                fileName: aria2FileName(for: task),
                proxy: proxyArg,
                connections: settings.aria2Split,
                minSplitSizeMB: settings.aria2MinSplitSize,
                fileAllocation: settings.aria2FileAllocation
            )
            return
        }

        launchBuiltIn(task, url: url)
    }

    /// aria2 暂存文件名：gid 前缀 + 简化名，避免多任务同名竞态（文件名中的 / 等替换掉）
    private func aria2FileName(for task: DownloadTask) -> String {
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
        let delegate = DownloadDelegate(store: self, gid: gid)
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
        if let staging = aria2StagingPaths.removeValue(forKey: gid) {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: URL(fileURLWithPath: staging.path + ".aria2"))
        }
        resumeDataMap.removeValue(forKey: gid)
        if let index = tasks.firstIndex(where: { $0.gid == gid }) {
            let task = tasks[index]
            if alsoDeleteFiles {
                // 源文件 + URL之中置引擎临时文件(.aria2 控制文件已随 staging 删)
                let destURL = URL(fileURLWithPath: (task.dir as NSString).appendingPathComponent(task.fileName))
                try? fm.removeItem(at: destURL)
                let stagingName = aria2FileName(for: task)
                try? fm.removeItem(at: AppDirectories.staging.appendingPathComponent(stagingName))
                try? fm.removeItem(at: AppDirectories.staging.appendingPathComponent(stagingName + ".aria2"))
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
    func hasDownloaded(media: TwitterMedia, dir: String? = nil) -> Bool {
        if settings.sameFileCheckModeValue == .recordFile {
            guard let mediaId = media.id, !mediaId.isEmpty else { return false }
            let targetDir = dir ?? settings.download.saveDirBase
            let recordPath = recordFileURL(dir: targetDir).path
            return Self.recordCache[recordPath]?.dayIds.contains(mediaId) ?? false
        }
        guard let downloadUrl = downloadURL(for: media) else { return false }
        // 文件名模式:在目标目录找同 URL 派生不出文件名(模板依赖 post/media 数据),
        // 调用方传 dir;这里用任务里最近一次的同 URL 文件名(完成任务携带),再查文件系统
        if let fileName = Self.completedFileNameCache[downloadUrl] {
            let targetDir = dir ?? settings.download.saveDirBase
            return fm.fileExists(atPath: (targetDir as NSString).appendingPathComponent(fileName))
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
            if let localURL, localURL.deletingLastPathComponent() == AppDirectories.staging {
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

    /// 统一错误处理：重试未用尽 → 重新排队（pump 拉起）；用尽 → error + 通知
    private func handleTaskError(gid: String, error: Error) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        let task = tasks[index]
        if task.retryCountRemains > 0 {
            AppLogger.warn("任务失败将重试", category: "DL", [
                "file": task.fileName,
                "remains": "\(task.retryCountRemains)",
                "error": error.localizedDescription,
            ])
            update(gid: gid) {
                $0.status = .waiting
                $0.retryCountRemains -= 1
                $0.error = error.localizedDescription
            }
            let retryGid = gid
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let t = self.tasks.first(where: { $0.gid == retryGid }), t.status == .waiting {
                    self.pump()
                }
            }
        } else {
            update(gid: gid) {
                $0.status = .error
                $0.error = error.localizedDescription
            }
            AppLogger.error("任务下载失败(重试耗尽)", category: "DL", ["file": task.fileName, "user": task.post.user.screenName, "error": error.localizedDescription])
            notify(title: "任务下载失败", body: "\(task.fileName)\n\(error.localizedDescription)")
            pump()
            refreshSleepAssertion()
        }
    }

    /// 把暂存文件落盘到目标位置并更新状态（URLSession 与 aria2 共用）
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
            let size = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
            update(gid: gid) {
                $0.status = .complete
                $0.completeSize = size ?? 0
                $0.totalSize = size ?? 0
                $0.error = nil
            }
            AppLogger.info("下载完成", category: "DL", ["file": task.fileName, "size": "\(size ?? 0)", "user": task.post.user.screenName])
            Self.completedFileNameCache[task.downloadUrl] = task.fileName
            recordDownloaded(mediaId: task.media.id, created: task.media.createdTime, dir: task.dir)
            pump()
            refreshSleepAssertion()
        } catch {
            // 临时文件即将被系统删除：move 失败时先拷贝兜底，仍失败才报错
            do {
                try? fm.removeItem(at: destURL)
                try fm.copyItem(at: stagedFile, to: destURL)
                let size = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                AppLogger.info("下载完成(copy fallback)", category: "DL", ["file": task.fileName, "size": "\(size ?? 0)", "user": task.post.user.screenName])
            recordDownloaded(mediaId: task.media.id, created: task.media.createdTime, dir: task.dir)
                refreshSleepAssertion()
            } catch {
                update(gid: gid) { $0.status = .error; $0.error = error.localizedDescription }
                AppLogger.error("下载文件落盘失败", category: "DL", [
                    "file": task.fileName,
                    "dest": destURL.path,
                    "error": error.localizedDescription,
                ])
                notify(title: "任务下载失败", body: "\(task.fileName)\n文件写入失败: \(error.localizedDescription)")
                refreshSleepAssertion()
            }
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

    init(store: DownloadStore, gid: String) {
        self.store = store
        self.gid = gid
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
        // 先同步拷贝到稳定位置，再投递到 MainActor 更新状态。
        let stableURL = AppDirectories.staging
            .appendingPathComponent("xspider-dl-\(UUID().uuidString)")
        do {
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
