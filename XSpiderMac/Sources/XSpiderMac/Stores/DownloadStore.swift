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
        didSet {
            // **节流**落盘，不是每次改动都写：进度事件按片到达，1000 个任务时
            // 每个事件都全量重编码会把主线程顶死（见 `markHistoryDirty` 的说明）。
            markHistoryDirty()
            rebuildTaskIndex()
            filteredCache.removeAll(keepingCapacity: true)
            knownUsersCache = nil
        }
    }

    /// `gid → tasks 下标`。
    ///
    /// 为什么需要：轮询的 `reconcile` 对**每个** job 调一次 `update(gid:)`，
    /// 而它原来是 `tasks.firstIndex(where:)` 线性扫描——几千条任务 × 每轮上千个 job，
    /// 每 400ms 就是几百万次字符串比较（实测下载页滚动卡到吃不掉手势）。
    /// 索引在 `tasks` 的 didSet 里重建：一次 O(n)，换掉每次 O(n) 的查找。
    private var taskIndex: [String: Int] = [:]

    /// 当前 Tab + 用户筛选的结果缓存。
    ///
    /// 为什么需要：`tasksForCurrentTab` 原来在**每次 body 求值**时全量 filter
    /// （几千条），滚动时 SwiftUI 每帧重算一次，等于每帧都扫一遍全表——
    /// 这才是"滑动卡到被吃掉"的主因。缓存只在 `tasks` / Tab / 用户筛选变化时失效。
    private var filteredCache: [String: [DownloadTask]] = [:]
    private var knownUsersCache: [KnownUser]?

    /// 筛选栏里的一行：账号 + 它在历史里的记录条数。
    struct KnownUser: Identifiable, Sendable {
        var name: String
        var screenName: String
        var avatar: String
        /// 该账号在历史里的记录条数（筛选栏右侧的小字）。
        var count: Int
        var id: String { screenName }
    }

    private func rebuildTaskIndex() {
        taskIndex = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($0.element.gid, $0.offset) })
    }
    var currentTab: String = "下载中"
    var creationTasks: [CreationTask] = []
    /// 历史记录筛选：nil = 全部；否则仅显示该 screen_name 的任务
    var userFilterScreenName: String?
    /// 用户筛选小窗是否弹出（DownloadsView 用）
    var userFilterPickerVisible = false

    /// 出现过的账号（昵称 + screenName + 头像），按最近任务时间排序。
    ///
    /// **带缓存**：它遍历全部任务（几千条）并排序，而筛选栏每次 body 求值都会读它
    /// （`DownloadsView` 的 `store.knownUsers`）——不缓存就是每帧扫全表 + 全排序。
    var knownUsers: [KnownUser] {
        if let cached = knownUsersCache { return cached }
        var seen: [String: (name: String, latest: Date, count: Int)] = [:]
        var avatars: [String: String] = [:]
        for task in tasks {
            let sn = task.post.user.screenName
            let prev = seen[sn]
            if prev == nil || task.updatedAt > prev!.latest {
                seen[sn] = (task.post.user.name, task.updatedAt, (prev?.count ?? 0) + 1)
            } else {
                seen[sn] = (prev!.name, prev!.latest, prev!.count + 1)
            }
            if avatars[sn] == nil { avatars[sn] = task.post.user.avatar }
        }
        let result = seen
            .sorted { $0.value.latest > $1.value.latest }
            .map { KnownUser(name: $0.value.name, screenName: $0.key,
                             avatar: avatars[$0.key] ?? "", count: $0.value.count) }
        knownUsersCache = result
        return result
    }

    /// 按当前 Tab + 用户筛选后的任务（**带缓存**，见 `filteredCache`）。
    ///
    /// 结果按状态排序（下载中 → 暂停 → 等待 → 失败 → 完成），
    /// 排序键是常量表——原实现在比较闭包里**每次比较**都新建一个字典，
    /// 几千条排序就是几万次字典分配。
    func tasksForCurrentTab(statuses: [DownloadStatus]) -> [DownloadTask] {
        let key = "\(userFilterScreenName ?? "*")|\(statuses.map(\.rawValue).joined(separator: ","))"
        if let cached = filteredCache[key] { return cached }
        let filterName = userFilterScreenName
        let filtered = tasks
            .filter { task in
                statuses.contains(task.status) &&
                    (filterName == nil || task.post.user.screenName == filterName)
            }
            .sorted { Self.statusOrder[$0.status, default: 9] < Self.statusOrder[$1.status, default: 9] }
        filteredCache[key] = filtered
        return filtered
    }

    /// 排序键表（常量，避免在排序闭包里反复分配字典）。
    private static let statusOrder: [DownloadStatus: Int] = [
        .active: 0, .paused: 1, .waiting: 2, .error: 3, .complete: 4, .removed: 5,
    ]

    /// 删除当前 Tab + 用户筛选范围内的记录；alsoDeleteFiles = 同时删除源文件与未完成临时文件。
    /// 文件删除在后台线程批量执行（UI 不卡顿）：先同步摘除记录与引擎任务，再异步清盘。
    func removeVisibleRecords(statuses: [DownloadStatus], alsoDeleteFiles: Bool = false) {
        let targets = Set(tasksForCurrentTab(statuses: statuses).map(\.gid))
        guard !targets.isEmpty else { return }
        removeBatch(targets, alsoDeleteFiles: alsoDeleteFiles)
        AppLogger.info("删除历史记录", category: "DL", [
            "count": "\(targets.count)", "files": alsoDeleteFiles ? "yes" : "no",
            "user": userFilterScreenName ?? "all",
        ])
    }

    /// 下载执行现在全部归组件（`dl.*`）。应用侧只留：
    /// 目录与文件名的计算（`targetDir` / `MediaJudgement`）、
    /// 收尾的内容校验（`FileIntegrity`）、下载记录（`MediaRecords`）、通知。
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

    /// 下载历史是否已脏（有改动还没落盘）。与 `historySaveScheduled` 一起做节流，见 `markHistoryDirty`。
    private var historyDirty = false
    private var historySaveScheduled = false
    /// 历史落盘的最小间隔：进度事件按片到达，这个粒度对"重启后能看到进度"完全够用。
    private static let historySaveIntervalNanos: UInt64 = 1_000_000_000

    private var settings: Settings { SettingsStore.shared.settings }
    private let fm = FileManager.default

    private init() {
        restoreTasks()
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
    /// 为什么需要：判定结果由 `hasDownloaded` 即时算出，它读的是文件系统与记录层缓存
    /// （`MediaRecords`）——这些都**不参与 `@Observable` 的依赖追踪**。于是切换判定依据、
    /// 换保存路径、清缓存之后，判定结果其实变了，但 SwiftUI 不知道要重绘，
    /// 媒体卡上的下载/已下载按钮状态会停在旧结果（用户报告的现象）。
    ///
    /// 视图读取本属性即建立观察依赖；影响判定的操作自增它即可触发刷新。
    private(set) var judgementVersion = 0

    /// 判定依据变化后调用：失效记录层缓存并通知视图重算判定
    func invalidateJudgements() {
        refreshDownloadedCaches()
        AppLogger.info("判定依据已变更,刷新已下载状态", category: "DL", [
            "mode": settings.sameFileCheckModeValue.rawValue,
            "syncMode": settings.syncCheckModeValue.rawValue,
        ])
    }

    /// 失效记录层缓存 + 自增判定版本号（视图重算）。
    ///
    /// 保存路径 / 子文件夹设置变更、导入导出之后都要调用它。
    /// 语义变更（记录体系重构）：不再预扫全目录——记录层按需加载，
    /// 失效即可；`judgementVersion++` 让 SwiftUI 重绘「已下载」按钮状态。
    func refreshDownloadedCaches() {
        MediaRecords.shared.invalidate()
        AccountFolder.invalidateIndex()
        judgementVersion += 1
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

        let dir = targetDir(for: post)
        // 落盘名：模板解析 + （设置允许时）`_媒体id` 唯一标识后缀，再过一遍重名消解。
        // 不再按判定依据分叉文件名——命名是**素材本身**的属性，判定是**另一件事**；
        // 旧实现让两者互相决定（记录模式保持模板原样、文件名模式自动追加序号），
        // 于是"换个判定依据"会连带改变已下文件的命名。
        //
        // **判据与落盘名一致**：带唯一标识（媒体 id）时 `landingFileName` 不做重命名，
        // 于是"判定查的名字"与"文件将落在的名字"是同一个；
        // 没有唯一标识时才可能出现 `… (2)`，此时判定看的仍是模板算出的那个名字
        // （记录模式判定不看文件名；文件名模式下唯一标识被强制打开，走的是前一个分支）。
        let judgedName = MediaJudgement.fileName(
            post: post, media: media,
            template: settings.download.fileNameTemplate,
            appendUniqueId: settings.appendUniqueIdEnabled)
        let landingName = resolvedLandingFileName(judgedName, media: media, dir: dir)

        // sameFileSkip：按当前判定依据决定跳过。
        // 「按文件名」判据用的是 `landingName`——与将要落盘的名字**是同一个**
        // （带唯一标识时 `landingFileName` 不改名，两者恒等；没有唯一标识时
        // 判定看的确实该是最后落下去的那个名字）。记录模式的判据与文件名无关，
        // 传哪个都不影响。
        if settings.download.sameFileSkip {
            if isDuplicate(fileName: landingName, media: media, post: post, dir: dir) {
                // 单媒体点击下载被跳过时给可见反馈（否则用户以为按钮失灵）；批量路径静默
                if !silent {
                    notify(title: L("任务已跳过"), body: L("该媒体已下载过：") + landingName)
                }
                return nil
            }
        }

        let task = DownloadTask(
            gid: UUID().uuidString,
            post: post,
            media: media,
            fileName: landingName,
            dir: dir,
            totalSize: 0,
            completeSize: 0,
            status: .waiting,
            error: nil,
            updatedAt: Date(),
            downloadUrl: downloadUrl,
            retryCountRemains: 5
        )

        AppLogger.info("创建下载任务", category: "DL", ["file": landingName, "dir": dir, "url": downloadUrl, "mediaId": media.id ?? "?"])
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

    /// 该媒体最终的落盘文件名：模板解析 + 唯一标识后缀 + 重名消解。
    ///
    /// **判定与落盘必须用同一个名字**（都走这里）。以前判定查模板算出的名字、
    /// 落盘却可能改成「 (2)」，于是文件明明在、判定永远说没有——
    /// 用户每点一次就多一份副本（隔离复现：三次点击得到 (2)/(3)/(4)，`hasDownloaded` 恒 false）。
    ///
    /// 重名消解规则见 `MediaJudgement.landingFileName`：**带唯一标识时不改名**
    /// （媒体 id 全局唯一，撞名只可能是同一个媒体）。没有唯一标识时保留保护
    /// （只可能出现在记录模式，判定不看文件名）。
    func resolvedFileName(post: TwitterPost, media: TwitterMedia, dir: String) -> String {
        resolvedLandingFileName(
            MediaJudgement.fileName(post: post, media: media,
                                    template: settings.download.fileNameTemplate,
                                    appendUniqueId: settings.appendUniqueIdEnabled),
            media: media, dir: dir)
    }

    /// 已算好的模板名 → 最终落盘名（重名消解只作用于没有唯一标识的名字）
    private func resolvedLandingFileName(_ raw: String, media: TwitterMedia, dir: String) -> String {
        MediaJudgement.landingFileName(
            raw,
            hasUniqueId: settings.appendUniqueIdEnabled && !(media.id ?? "").isEmpty,
            dir: dir,
            extraTaken: { [tasks] name in
                tasks.contains {
                    $0.dir == dir && $0.fileName == name &&
                    $0.status != .error && $0.status != .removed
                }
            })
    }

    /// 判定依据（设置三选一，契约 `MEDIA_RECORDS.md` §6.1）——三者语义**有意不同**：
    ///
    /// - **distributed / centralized（记录文件）**：只查记录里是否已有该媒体 id，
    ///   命中即信任，**不回头校验文件是否存在/完整**。
    ///   这正是该依据存在的意义：改文件名模板、重命名或移动文件、整目录搬家，
    ///   记录都依然有效。若额外做"记录 ↔ 文件"双向校验，会把"用户改过文件名"
    ///   误判成"没下载过"而重复下载，恰好抵消掉它唯一优于"按文件名"的地方。
    ///   两种记录形态的差别只在**记录文件放哪**（账号文件夹 / 应用数据目录）。
    ///
    /// - **fileName（按文件名）**：查目标文件夹里 `resolvedFileName` 是否存在。
    ///   唯一标识让文件名本身成为可靠判据：即使模板不含任何唯一变量，
    ///   同一推文的多张媒体也不会互相覆盖。
    private func isDuplicate(fileName: String, media: TwitterMedia,
                             post: TwitterPost?, dir: String) -> Bool {
        switch settings.sameFileCheckModeValue {
        case .fileName:
            if MediaJudgement.isDownloaded(fileName: fileName, in: dir) {
                AppLogger.info("sameFileSkip 跳过已存在文件", category: "DL", ["file": fileName])
                return true
            }
            return false
        case .distributed:
            guard let mediaId = media.id, !mediaId.isEmpty else { return false }
            let url = distributedRecordURL(dir: dir)
            if MediaRecords.shared.isDownloaded(mediaId: mediaId, fileURL: url) {
                AppLogger.info("下载记录命中，跳过", category: "DL", [
                    "mediaId": mediaId, "form": "distributed", "file": url.path,
                ])
                return true
            }
            return false
        case .centralized:
            guard let mediaId = media.id, !mediaId.isEmpty, let post,
                  let userId = accountIdForRecord(post: post, media: media, dir: dir) else { return false }
            if MediaRecords.shared.isDownloaded(mediaId: mediaId, userId: userId) {
                AppLogger.info("下载记录命中，跳过", category: "DL", [
                    "mediaId": mediaId, "form": "centralized", "userId": userId,
                ])
                return true
            }
            return false
        }
    }

    /// 媒体作者的数字 id（记录的账号身份）。
    ///
    /// `post.user.id` 缺失时回落到 `%USER_ID%` 模板解析——与用户配置的取数口径一致
    /// （契约 §2：账号一律用数字 id，不能用用户名兜底）。
    private func mediaAuthorId(post: TwitterPost, media: TwitterMedia) -> String? {
        if !post.user.id.isEmpty { return post.user.id }
        let resolved = FileNameTemplate.resolve(template: "%USER_ID%",
                                                data: FileNameTemplateData(post: post, media: media))
        return resolved.isEmpty ? nil : resolved
    }

    /// 账号身份的**兜底**：作者 id 取不到时，用目标文件夹名里的 `[数字id]`
    /// （分布式场景本就有这个信息——文件夹名就是账号身份的唯一依据）。
    ///
    /// 为什么需要：`post.user.id` 缺失（响应形态变化 / 解析漏字段）时，
    /// 记录里的 `user_id` 会写成空串；而"从保存路径扫描导入"与导出都要求
    /// `user_id` 非空才收，于是这些 id **无声消失**（用户只看到"导入完成 0 条"）。
    ///
    /// - Returns: nil = 账号无法确定 → 调用方**不写记录**，改告警（F7）。
    func accountIdForRecord(post: TwitterPost, media: TwitterMedia, dir: String) -> String? {
        if let direct = mediaAuthorId(post: post, media: media) { return direct }
        let folder = (dir as NSString).lastPathComponent
        if let fromFolder = AccountFolder.accountId(fromFolderName: folder) { return fromFolder }
        return nil
    }

    /// 分布式下载记录文件路径（账号文件夹里一份；关闭子文件夹时落在保存路径根下）
    private func distributedRecordURL(dir: String) -> URL {
        URL(fileURLWithPath: dir)
            .appendingPathComponent(settings.recordFileNameValue)
    }

    /// 下载成功后按当前形态写入下载记录（媒体 id）。
    ///
    /// 只在**记录模式**下写：选「按文件名」时文件名本身就是判据，不需要记录文件
    /// （写了反而是第三种判据，正是这次重构要消除的东西）。
    /// 同步发生在主线程（记录文件很小），保证任务标完成的那一刻记录已经落盘——
    /// 否则紧接着的 `hasDownloaded` 查询会读到旧值。
    ///
    /// **账号无法确定时不写**：记录只写"能定位账号"的——空 `user_id` 的下载记录
    /// 在扫描/导入/导出时会被当成无法定位而丢弃（`RecordsIO` 要求非空），
    /// 写下去等于让这条 id 无声消失。宁可少一条记录、留一条告警。
    ///
    /// 非 private：`MediaRecordsTests` 直接断言"账号判不出来时不落盘"这条行为。
    func recordDownloaded(mediaId: String?, post: TwitterPost, media: TwitterMedia, dir: String) {
        guard let mediaId, !mediaId.isEmpty else { return }
        switch settings.sameFileCheckModeValue {
        case .fileName:
            return
        case .distributed:
            guard let userId = accountIdForRecord(post: post, media: media, dir: dir) else {
                AppLogger.warn("下载记录无法定位账号,未写入", category: "DL", [
                    "mediaId": mediaId, "dir": dir,
                ])
                return
            }
            _ = MediaRecords.shared.appendDownloadId(
                mediaId, userId: userId, fileURL: distributedRecordURL(dir: dir))
        case .centralized:
            guard let userId = accountIdForRecord(post: post, media: media, dir: dir) else {
                AppLogger.warn("下载记录无法定位账号,未写入", category: "DL", [
                    "mediaId": mediaId, "dir": dir,
                ])
                return
            }
            _ = MediaRecords.shared.appendCentralDownloadId(mediaId, userId: userId)
        }
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
            // 同一 user id 永远指向同一个文件夹：已有文件夹优先（见 `AccountFolder.directory`）。
            // 直接拿当前昵称拼名字的话，改一次昵称就会出现第二个文件夹、
            // 记录写进新的空文件，旧记录读不到 → 整个账号的媒体被当成没下过（整库重下）。
            dir = AccountFolder.directory(saveDir: dir,
                                          name: post.user.name,
                                          screenName: post.user.screenName,
                                          userId: post.user.id)
        }
        return dir
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
        // 编码与写盘挪到后台：1000 个任务（每条内嵌完整推文）编码一次要几十毫秒，
        // 放主线程会直接顶住界面。路径先取出来——`historyURL` 是 MainActor 隔离的，
        // 后台任务里碰不到。
        let url = Self.historyURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(items) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 标记历史需要落盘（**节流**：最多每 `historySaveIntervalNanos` 写一次，多次改动合并成一次）。
    ///
    /// 为什么必须节流：`tasks` 的任何改动都走 didSet，而进度是按片高频到达的——
    /// 1000 个任务并发时，一轮 400ms 轮询可能带来上百个进度事件。
    /// 之前每个事件都把**全部任务**重新编码写盘，实测主线程 94% CPU 全在
    /// `JSONEncoder.encode` 上，下载页卡到动不了（`sample` 抓到的调用栈）。
    private func markHistoryDirty() {
        historyDirty = true
        guard !historySaveScheduled else { return }   // 已排期 → 那次写盘会覆盖本次改动
        historySaveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.historySaveIntervalNanos)
            guard let self else { return }
            self.historySaveScheduled = false
            self.flushHistory()
        }
    }

    /// 异步落盘（若确实脏了）。
    func flushHistory() {
        guard historyDirty else { return }
        historyDirty = false
        persistTasks()
    }

    /// **同步**落盘，给退出路径用：那里必须确定写完，不能等异步任务。
    func flushHistoryNow() {
        guard historyDirty else { return }
        historyDirty = false
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
        guard let index = taskIndex[gid], tasks.indices.contains(index),
              tasks[index].gid == gid else { return }
        start(tasks[index])
    }

    func remove(_ gid: String, alsoDeleteFiles: Bool = false) {
        // 取消 = 丢弃断点并清掉临时文件（组件负责），目标目录保持干净
        componentCall("dl.cancel", gid)
        componentJobs.remove(gid)
        if let index = taskIndex[gid], tasks.indices.contains(index),
           tasks[index].gid == gid {
            let task = tasks[index]
            if alsoDeleteFiles {
                // 源文件 + 目标目录内引擎临时文件 + 旧 staging 残留
                let destURL = URL(fileURLWithPath: (task.dir as NSString).appendingPathComponent(task.fileName))
                try? fm.removeItem(at: destURL)
                // 组件可能把断点留在目标目录（文件名带引擎标识），一并清掉
                for suffix in MediaJudgement.enginePartialSuffixes {
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
        // 走批量路径：逐个 `remove(gid:)` 会让 didSet 跑 N 次（每次重建索引 + 清缓存），
        // 删几千条时主线程会卡死一小段时间（用户实测报过）。
        let toRemove = tasks.filter { status == nil || $0.status == status }.map(\.gid)
        guard !toRemove.isEmpty else { return }
        removeBatch(Set(toRemove), alsoDeleteFiles: alsoDeleteFiles)
    }

    /// 批量摘除（一次数组赋值 + 一次 pump）。文件删除在后台。
    private func removeBatch(_ gids: Set<String>, alsoDeleteFiles: Bool) {
        var pathsToDelete: [String] = []
        if alsoDeleteFiles {
            for task in tasks where gids.contains(task.gid) {
                let dest = (task.dir as NSString).appendingPathComponent(task.fileName)
                pathsToDelete.append(dest)
                for suffix in MediaJudgement.enginePartialSuffixes {
                    pathsToDelete.append(dest + suffix)
                }
            }
        }
        for gid in gids { componentCall("dl.cancel", gid); componentJobs.remove(gid) }
        tasks.removeAll { gids.contains($0.gid) }
        pump()
        refreshSleepAssertion()
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
    }

    /// 是否已下载过同一媒体——主页网格「已下载」禁用态（与 `isDuplicate` 同一套判据）。
    ///
    /// - 记录模式（分布式 / 集中式）：查记录里的媒体 id；**只信记录、不回查文件**
    ///   （改文件名 / 移动文件后依然算已下载 —— 见 `isDuplicate` 说明）。
    /// - 文件名模式：按 `resolvedFileName`（与落盘名同一个函数）算名字，查目标文件夹里
    ///   是否存在。`post` 缺失时无法算名（模板依赖推文数据）→ 返回 false。
    func hasDownloaded(media: TwitterMedia, dir: String? = nil, post: TwitterPost? = nil) -> Bool {
        let targetDir = dir ?? settings.download.saveDirBase
        switch settings.sameFileCheckModeValue {
        case .fileName:
            guard let post else { return false }
            // 判定与落盘用同一个名字（`resolvedFileName`）——带唯一标识时它不做重名消解，
            // 于是"文件在不在"与"下载会落在哪个名字"恒等（F9 的核心）。
            return MediaJudgement.isDownloaded(
                fileName: resolvedFileName(post: post, media: media, dir: targetDir),
                in: targetDir)
        case .distributed:
            guard let mediaId = media.id, !mediaId.isEmpty else { return false }
            return MediaRecords.shared.isDownloaded(
                mediaId: mediaId, fileURL: distributedRecordURL(dir: targetDir))
        case .centralized:
            guard let mediaId = media.id, !mediaId.isEmpty, let post,
                  let userId = accountIdForRecord(post: post, media: media, dir: targetDir) else { return false }
            return MediaRecords.shared.isDownloaded(mediaId: mediaId, userId: userId)
        }
    }

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
        guard let index = taskIndex[gid], tasks.indices.contains(index),
              tasks[index].gid == gid else { return }   // 索引过期就当作没找到（didSet 会重建）
        var task = tasks[index]
        if task.updatedAt > now { return }
        let before = task
        mutation(&task)
        // **内容没变就不写**：`tasks[index] = task` 会触发 @Observable 通知 →
        // 视图重算 body → 全量 filter/sort。轮询里大多数 job 的进度在同一秒内
        // 没有变化，无条件写等于每轮都给界面标一次脏（实测就是滚动卡顿的放大器）。
        //
        // 只比轮询/收尾会改的字段（不是整个 struct 的相等）：这些类型都没有
        // `Equatable`，为这一处给整条模型链加 conformance 不划算，也没必要。
        guard task.status != before.status
            || task.completeSize != before.completeSize
            || task.totalSize != before.totalSize
            || task.error != before.error
            || task.retryCountRemains != before.retryCountRemains
            || task.fileName != before.fileName
            || task.engine != before.engine
        else { return }
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
        guard let index = taskIndex[gid], tasks.indices.contains(index),
              tasks[index].gid == gid else { return }
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
            recordDownloaded(mediaId: task.media.id, post: task.post, media: task.media, dir: task.dir)
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
        guard let index = taskIndex[gid], tasks.indices.contains(index),
              tasks[index].gid == gid else { return }
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
        for suffix in MediaJudgement.enginePartialSuffixes {
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
