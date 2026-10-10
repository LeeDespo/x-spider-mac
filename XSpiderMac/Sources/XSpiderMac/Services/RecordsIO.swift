import Foundation

// MARK: - 导入 / 导出 / 按文件名重建（第 2 阶段实现）
//
// 契约见仓库根目录 `MEDIA_RECORDS.md` §7（导入导出三条入口）与 §8（按文件名重建记录）。
//
// 四条纪律（实现时守住，避免走样）：
// 1. **写回选中的形态**：分布式写账号文件夹（记录文件名取设置里的「记录文件名」），
//    集中式写 `records/`；记录只记媒体 id，账号一律用数字 id；
// 2. **追加 = 并集**（下载 id 并集；同步条目 `anchor_day` 取较晚 + ids 并集），
//    并集天然幂等，所以**重复导入同一份文件不会改变任何东西**；
// 3. **覆盖 = 被导入的条目整体替换**：导入包里出现的账号，其记录被导入内容整份替换；
//    **未出现的账号一个字节都不动**（比"清空整个库再写"安全，也避免了误删用户数据）；
// 4. **不做旧的兼容/迁移**：只认 `.downloadedrecord.json`（或设置里改过的名字）与
//    `.synced.json`、只认导出包形状；旧文件（`.downloaded.json` 等）不读、不删。
//
// 依赖注入：`records` 参数默认 `MediaRecords.shared`，测试传自己的实例（临时目录），
// 从而**绝不触碰**真实的 `~/Library/Application Support/XSpiderMac`。

/// 记录导入的结果报告（给 UI 展示）。
///
/// 三项语义（数字对得上，UI 直接拿去显示）：
/// - `recognizedAccounts`：**成功处理**的账号数（识别到的账号 − 写不进去的账号）；
/// - `addedEntries`：**新增**的条目数——(账号, 媒体 id) 对在导入后比导入前多出来的个数
///   （下载记录与同步记录一起算；已存在的 id 不算新增）；
/// - `unrecognizedEntries`：**无法识别 / 无法定位**的条目数——空账号 id（导出包里
///   或同步记录条目里）、分布式形态下找不到账号文件夹（既没有该账号的文件夹、
///   保存路径下又已经有别的账号文件夹，说明这是"按账号建子文件夹"的目录，
///   记录写到根下不会被判定读到）的账号、保存路径根下 `user_id` 为空的共享记录、
///   以及名字里没有 `[数字id]` 的目录里读到的记录。**这些都要计数 + 告警，
///   不许静默 continue**（静默的症状是"导入完成 0 条"，比报错更难查）。
struct RecordImportReport: Equatable, Sendable {
    /// 识别到的账号数（认知到的记录条目数）
    var recognizedAccounts = 0
    /// 新增的记录数（导入前不存在、导入后新增）
    var addedEntries = 0
    /// 无法识别而跳过的条目数
    var unrecognizedEntries = 0
}

/// 按文件名重建记录的结果报告（契约 §8：三项）。
///
/// - `recognized`：从文件名里解析出媒体 id 的文件数；
/// - `added`：写进记录后**新增**的 (账号, 媒体 id) 个数；
/// - `unrecognized`：文件名里解析不出媒体 id 的文件数 + 保存路径根下（没有账号文件夹，
///   账号无从得知）的文件数 + **名字里没有 `[数字id]` 的目录**里能解析出媒体 id 的文件数
///   （F7：空作者 id 写过记录时留下的那种目录，以前整个目录被静默跳过）。
struct RecordRebuildReport: Equatable, Sendable {
    /// 识别到的媒体 id 数
    var recognized = 0
    /// 新增进记录的数（此前记录里没有）
    var added = 0
    /// 文件名里解析不出媒体 id 的数
    var unrecognized = 0
}

/// 导入方式（三条入口，契约 §7）。
enum RecordImportSource: Sendable {
    /// 从导出文件导入（`.xspider.records-export`）
    case exportFile(URL)
    /// 从分布式记录文件导入（直接扫描保存路径）
    case distributedRecords(saveDir: String)
    /// 按文件名重建（扫描保存路径下的媒体文件）
    case rebuildFromFileNames(saveDir: String)
}

/// 导入策略（重复导入时的选择，契约 §7）。
enum RecordImportStrategy: Sendable {
    /// 覆盖：导入包里出现的账号，其记录被导入内容整体替换
    case overwrite
    /// 追加：id 并集；同步条目 anchor_day 取较晚者 + ids 并集
    case merge
}

/// 导出 / 扫描的结果报告（契约 §7）。
///
/// `unlocatableEntries`：**无法定位账号**的条目数——名字里没有 `[数字id]`、但确实装着
/// 我们媒体的目录（空作者 id 写过记录时留下的那种），以及保存路径根下 `user_id` 为空的
/// 共享记录文件。它们既不能算进某个账号，也**不许静默消失**：
/// 导出包不带它们，界面上必须看得到这个数字（见 `MEDIA_RECORDS.md` §10）。
struct RecordExportReport: Equatable, Sendable {
    /// 导出包本身
    var export = RecordsExport()
    /// 无法定位账号的条目数（每个无法确定账号的记录来源计 1）
    var unlocatableEntries = 0
}

/// 记录导入导出（契约 §7/§8）。
///
/// 纯逻辑层：不弹面板、不读设置（保存路径与记录文件名都由调用方传入），
/// 因此可以整体在测试里跑（临时目录）。面板与「覆盖 / 追加 / 取消」弹窗在设置界面。
enum RecordsIO {

    // MARK: - 导出

    /// 导出：把当前形态的下载记录 + 同步记录写成导出包（契约 §4.3）。
    ///
    /// 分布式形态 = 扫保存路径下所有账号文件夹合并（另含保存路径根下的共享记录文件，
    /// 见 §3 关键性质第 4 条：关闭账号子文件夹时记录落在根下）。
    ///
    /// 遇到无法定位账号的记录（空 `user_id` / 没有 `[数字id]` 的目录）时会告警，
    /// 计数见 `exportRecordsWithReport`（本方法只是为了兼容既有调用点。
    /// **新调用点用带报告的那个**，好把「无法定位」显示给用户）。
    static func exportRecords(form: RecordForm,
                              saveDir: String,
                              recordFileName: String = MediaRecords.defaultDownloadRecordName,
                              records: MediaRecords = .shared) throws -> RecordsExport {
        try exportRecordsWithReport(form: form, saveDir: saveDir,
                                    recordFileName: recordFileName, records: records).export
    }

    /// 导出（带「无法定位」计数）。导出包走与记录文件**同一条**确定性序列化路径。
    static func exportRecordsWithReport(form: RecordForm,
                                        saveDir: String,
                                        recordFileName: String = MediaRecords.defaultDownloadRecordName,
                                        records: MediaRecords = .shared) throws -> RecordExportReport {
        let collected = try collect(form: form, saveDir: saveDir,
                                    recordFileName: recordFileName, records: records)
        return RecordExportReport(
            export: RecordsExport(downloads: collected.state.downloads.mapValues(\.ids),
                                  sync: collected.state.sync.accounts),
            unlocatableEntries: collected.unlocatable)
    }

    // MARK: - 导入

    /// 导入（契约 §7）：按来源读入，按策略写回选中的形态。
    ///
    /// - Throws: 导出文件读不出/不是导出包、保存路径为空（分布式）、写盘失败。
    @discardableResult
    static func importRecords(from source: RecordImportSource,
                              into form: RecordForm,
                              strategy: RecordImportStrategy,
                              saveDir: String,
                              recordFileName: String = MediaRecords.defaultDownloadRecordName,
                              records: MediaRecords = .shared) throws -> RecordImportReport {
        let incoming = try read(source: source, recordFileName: recordFileName, records: records)
        return try apply(incoming, into: form, strategy: strategy,
                         saveDir: saveDir, recordFileName: recordFileName, records: records)
    }

    // MARK: - 按文件名重建

    /// 按文件名重建记录（契约 §8）：扫保存路径下的媒体文件，
    /// 从文件名里解析 `[15~25 位纯 ASCII 数字]` 得到媒体 id；账号取自文件夹名的 `[数字id]`。
    ///
    /// 扫描范围与计数口径：
    /// - 账号文件夹里：**每个**非隐藏文件都参与解析，解析不出媒体 id 计入"无法识别"
    ///   （这些文件都出自本应用，认不出来就是真的认不出来）；
    /// - **组件的断点 / 临时文件**（`.part.http` / `.part.aria2next` / `.part.*.aria2`）
    ///   整个跳过，不计入任何一项：它们不是媒体，但文件名里同样带着媒体 id；
    /// - 保存路径根下：只把**能解析出媒体 id** 的文件计入"无法识别 / 无法定位账号"
    ///   （关闭账号子文件夹时的存量就在这里，它们确实是我们的媒体，但账号无从得知）；
    ///   解析不出的根下文件整个忽略——根目录往往还有大量与下载无关的文件，
    ///   把它们都算进去会让"无法识别"变成一个吓人且无意义的数字。
    /// - **名字里没有 `[数字id]` 的目录**：里面能解析出媒体 id 的文件同样计入
    ///   "无法识别 / 无法定位账号"（F7：空作者 id 写过记录时会留下这种目录，
    ///   以前整个目录被静默跳过）；解析不出的文件忽略（可能只是普通目录）。
    ///
    /// 结果写入选中的形态。写入口径按策略区分：**追加**只有识别出 ≥1 个媒体 id 的账号
    /// 才会被写（空集合并集不会变）；**覆盖**下扫过但 0 命中的账号也写——写空记录
    /// 把残留清掉（上面「扫描过的账号一律登记」正是为此）。
    @discardableResult
    static func rebuildFromFileNames(saveDir: String,
                                     into form: RecordForm,
                                     strategy: RecordImportStrategy,
                                     recordFileName: String = MediaRecords.defaultDownloadRecordName,
                                     records: MediaRecords = .shared) throws -> RecordRebuildReport {
        guard !saveDir.isEmpty else { throw RecordIOError.missingSaveDirectory }
        let folders = accountDirs(in: saveDir)
        var recognized = 0
        var unrecognized = 0
        var found: [String: [String]] = [:]

        for folder in folders {
            // **扫描过的账号一律登记**（哪怕一个都没解析出来）。
            // 覆盖模式要靠它把"记录里有、磁盘上已经没有"的残留清掉——
            // 只登记有命中的账号，残留就永远清不掉（真实故障：
            // 上一版下划线命名解析出的 id 留在记录里，判定一直把它们当成已下载）。
            if found[folder.userId] == nil { found[folder.userId] = [] }
            for file in regularFiles(in: folder.dir) {
                // 断点 / 临时文件不是媒体：它们的名字里同样带着媒体 id
                // （`…[媒体id].jpg.part.http`），解析出来会把从没下完的媒体
                // 永久记成"已下载"（记录模式只信记录、不回查文件，错一次就不会再下）。
                guard !MediaJudgement.isEnginePartial(fileName: file.lastPathComponent) else { continue }
                if let mediaId = mediaId(fromFileName: file.lastPathComponent) {
                    recognized += 1
                    found[folder.userId, default: []].append(mediaId)
                } else {
                    unrecognized += 1
                }
            }
        }
        for file in regularFiles(in: saveDir)
        where !MediaJudgement.isEnginePartial(fileName: file.lastPathComponent)
            && mediaId(fromFileName: file.lastPathComponent) != nil {
            unrecognized += 1
        }
        // 名字里没有 [数字id] 的目录：里面有我们的媒体，账号却无从得知。
        // 不静默跳过——计入"无法定位"，用户能看见这个数字。
        for dir in unparsableDirs(in: saveDir) {
            for file in regularFiles(in: dir)
            where !MediaJudgement.isEnginePartial(fileName: file.lastPathComponent)
                && mediaId(fromFileName: file.lastPathComponent) != nil {
                unrecognized += 1
            }
        }

        var incoming = Incoming(downloads: found.mapValues { DownloadRecord.normalizedIds($0) })
        incoming.unlocatable = unrecognized
        let report = try apply(incoming, into: form, strategy: strategy,
                               saveDir: saveDir, recordFileName: recordFileName, records: records)
        return RecordRebuildReport(recognized: recognized,
                                   added: report.addedEntries,
                                   unrecognized: unrecognized)
    }

    // MARK: - 读取来源

    /// 从来源读到的内容（账号一律是数字 id）。
    private struct Incoming {
        /// 账号 id → 媒体 id 列表
        var downloads: [String: [String]] = [:]
        /// 账号 id → 同步条目
        var sync: [String: SyncAccountRecord] = [:]
        /// 读到了、但**账号无法确定**的条目数（空账号 id、或扫描时定位不到账号的记录来源）
        var unlocatable = 0

        /// 识别到的账号数（下载记录与同步记录里的账号并集）
        var accountCount: Int { Set(downloads.keys).union(sync.keys).count }
    }

    private static func read(source: RecordImportSource,
                             recordFileName: String,
                             records: MediaRecords) throws -> Incoming {
        switch source {
        case .exportFile(let url):
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw RecordIOError.unreadableFile(url.lastPathComponent)
            }
            guard let export = RecordsExport.decode(from: data) else {
                throw RecordIOError.invalidExportFile
            }
            return incoming(fromExport: export)

        case .distributedRecords(let saveDir):
            guard !saveDir.isEmpty else { throw RecordIOError.missingSaveDirectory }
            var out = Incoming()
            for folder in accountDirs(in: saveDir) {
                let url = records.distributedDownloadURL(accountDir: folder.dir,
                                                         fileName: recordFileName)
                if let record = records.loadDownload(fileURL: url), !record.ids.isEmpty {
                    // 账号可定位：文件夹名就是身份（记录里的 user_id 只是给人看的归属标记）。
                    // 空 user_id 按文件夹兜底，不能让这些 id 无声消失。
                    if record.userId.isEmpty {
                        AppLogger.warn("分布式记录缺少 user_id，按文件夹名兜底", category: "REC", [
                            "file": url.path, "accountId": folder.userId,
                        ])
                    }
                    let userId = record.userId.isEmpty ? folder.userId : record.userId
                    out.downloads[userId, default: []].append(contentsOf: record.ids)
                }
                if let sync = records.loadSync(fileURL: records.distributedSyncURL(accountDir: folder.dir)) {
                    for (userId, entry) in sync.accounts {
                        guard !userId.isEmpty else {
                            out.unlocatable += 1
                            AppLogger.warn("同步记录里有账号为空的条目", category: "REC", [
                                "file": records.distributedSyncURL(accountDir: folder.dir).path,
                            ])
                            continue
                        }
                        out.sync[userId] = mergedEntry(out.sync[userId], entry)
                    }
                }
            }
            // 保存路径根下的共享记录文件（关闭账号子文件夹时的落点，§3 关键性质第 4 条）：
            // 账号取记录里的 user_id（它就是"首个写入者"，是唯一的身份线索）
            let rootURL = URL(fileURLWithPath: saveDir, isDirectory: true)
                .appendingPathComponent(recordFileName)
            if let record = records.loadDownload(fileURL: rootURL), !record.ids.isEmpty {
                if record.userId.isEmpty {
                    // 根下的共享记录没有账号信息 → 无法定位。不静默跳过：告警 + 计数。
                    out.unlocatable += 1
                    AppLogger.warn("共享记录缺少 user_id，账号无法定位", category: "REC", [
                        "file": rootURL.path, "ids": "\(record.ids.count)",
                    ])
                } else {
                    out.downloads[record.userId, default: []].append(contentsOf: record.ids)
                }
            }
            // 名字里没有 [数字id] 的目录：里面有记录文件，账号却无从得知
            // （空作者 id 写过记录时留下的那种目录）。不静默跳过：告警 + 计数。
            for dir in unparsableDirs(in: saveDir) {
                let url = URL(fileURLWithPath: dir, isDirectory: true)
                    .appendingPathComponent(recordFileName)
                if let record = records.loadDownload(fileURL: url), !record.ids.isEmpty {
                    out.unlocatable += 1
                    AppLogger.warn("记录文件所在目录没有数字 id，账号无法定位", category: "REC", [
                        "file": url.path, "ids": "\(record.ids.count)",
                    ])
                }
            }
            out.downloads = out.downloads.mapValues { DownloadRecord.normalizedIds($0) }
            return out

        case .rebuildFromFileNames:
            // 重建的报告形状不同，走 `rebuildFromFileNames(saveDir:into:strategy:)`
            throw RecordIOError.unsupportedSource
        }
    }

    /// 导出包 → `Incoming`：空账号 id 的条目**计入「无法定位」并告警**，不静默丢。
    private static func incoming(fromExport export: RecordsExport) -> Incoming {
        var out = Incoming()
        for (userId, ids) in export.downloads {
            guard !userId.isEmpty else {
                out.unlocatable += 1
                AppLogger.warn("导出包里有账号为空的下载记录", category: "REC", ["ids": "\(ids.count)"])
                continue
            }
            out.downloads[userId] = DownloadRecord.normalizedIds(ids)
        }
        for (userId, entry) in export.sync {
            guard !userId.isEmpty else {
                out.unlocatable += 1
                AppLogger.warn("导出包里有账号为空的同步记录", category: "REC", ["ids": "\(entry.ids.count)"])
                continue
            }
            out.sync[userId] = entry
        }
        return out
    }

    /// 同步条目合并（契约 §7：anchor 取较晚者 + ids 并集）
    private static func mergedEntry(_ lhs: SyncAccountRecord?,
                                    _ rhs: SyncAccountRecord) -> SyncAccountRecord {
        guard let lhs else { return rhs }
        return SyncAccountRecord(anchorDay: max(lhs.anchorDay, rhs.anchorDay),
                                 ids: lhs.ids + rhs.ids)
    }

    // MARK: - 读当前形态

    /// 某个形态下当前的记录（导出与"新增"计数都用它）。
    private struct FormState {
        var downloads: [String: DownloadRecord] = [:]
        var sync = SyncRecord()
    }

    /// `collect` 的结果：记录本身 + 无法定位账号的条目数（见 `RecordExportReport`）。
    private struct Collected {
        var state = FormState()
        var unlocatable = 0
    }

    private static func collect(form: RecordForm,
                                saveDir: String,
                                recordFileName: String,
                                records: MediaRecords) throws -> Collected {
        var out = Collected()
        switch form {
        case .centralized:
            out.state.downloads = records.loadAllCentralDownloads()
            out.state.sync = records.loadSync(fileURL: records.centralSyncURL) ?? SyncRecord()

        case .distributed:
            guard !saveDir.isEmpty else { throw RecordIOError.missingSaveDirectory }
            for folder in accountDirs(in: saveDir) {
                let url = records.distributedDownloadURL(accountDir: folder.dir,
                                                         fileName: recordFileName)
                if let record = records.loadDownload(fileURL: url) {
                    // 账号可定位：文件夹名就是身份（记录里的 user_id 只是给人看的归属标记，
                    // 分布式形态下多作者可能共用一个文件夹）。空 user_id 按文件夹兜底，
                    // 不能让这些 id 无声消失。
                    merge(record, fallbackUserId: folder.userId, into: &out.state.downloads)
                }
                if let sync = records.loadSync(fileURL: records.distributedSyncURL(accountDir: folder.dir)) {
                    out.state.sync = SyncRecord.merged(out.state.sync, sync)
                }
            }
            let rootURL = URL(fileURLWithPath: saveDir, isDirectory: true)
                .appendingPathComponent(recordFileName)
            if let record = records.loadDownload(fileURL: rootURL), !record.ids.isEmpty {
                if record.userId.isEmpty {
                    // 根下的共享记录没有账号信息（也没有文件夹名可兜底）→ 无法定位。
                    // 不静默：告警 + 计数。
                    out.unlocatable += 1
                    AppLogger.warn("共享记录缺少 user_id，账号无法定位", category: "REC", [
                        "file": rootURL.path, "ids": "\(record.ids.count)",
                    ])
                } else {
                    merge(record, fallbackUserId: record.userId, into: &out.state.downloads)
                }
            }
            // 名字里没有 [数字id] 的目录：里面有记录文件，账号却无从得知
            // （空作者 id 写过记录时留下的那种目录）。导出时必须计数，不许静默忽略。
            for dir in unparsableDirs(in: saveDir) {
                let url = URL(fileURLWithPath: dir, isDirectory: true)
                    .appendingPathComponent(recordFileName)
                if let record = records.loadDownload(fileURL: url), !record.ids.isEmpty {
                    out.unlocatable += 1
                    AppLogger.warn("记录文件所在目录没有数字 id，账号无法定位", category: "REC", [
                        "file": url.path, "ids": "\(record.ids.count)",
                    ])
                }
            }
        }
        return out
    }

    /// 把一份下载记录并进按账号组织的字典（同一账号多份来源 → id 并集）
    private static func merge(_ record: DownloadRecord,
                              fallbackUserId: String,
                              into downloads: inout [String: DownloadRecord]) {
        let userId = record.userId.isEmpty ? fallbackUserId : record.userId
        guard !userId.isEmpty else { return }
        if var existing = downloads[userId] {
            existing.ids = DownloadRecord.normalizedIds(existing.ids + record.ids)
            downloads[userId] = existing
        } else {
            downloads[userId] = DownloadRecord(userId: userId, ids: record.ids)
        }
    }

    // MARK: - 写回

    /// 把导入内容写回选中的形态；返回报告（含"新增条目数"）。
    private static func apply(_ incoming: Incoming,
                              into form: RecordForm,
                              strategy: RecordImportStrategy,
                              saveDir: String,
                              recordFileName: String,
                              records: MediaRecords) throws -> RecordImportReport {
        let before = try collect(form: form, saveDir: saveDir,
                                 recordFileName: recordFileName, records: records)
        var skippedAccounts = Set<String>()
        var skippedEntries = 0

        switch form {
        case .centralized:
            for (userId, ids) in incoming.downloads {
                guard !userId.isEmpty else { skippedEntries += 1; continue }
                // 追加空集合到记录里没有意义（并集不会变），跳过；
                // **覆盖模式下必须写**：id 为空正是"这个账号一个都没扫到"，
                // 写空才能把记录里的残留清掉（否则残留永久留着）。
                if ids.isEmpty, strategy == .merge { continue }
                let url = records.centralDownloadURL(userId: userId)
                switch strategy {
                case .merge:
                    _ = try records.mergeDownloadIds(ids, userId: userId, fileURL: url)
                case .overwrite:
                    _ = try records.overwriteDownloadIds(ids, userId: userId, fileURL: url)
                }
            }
            for (userId, entry) in incoming.sync {
                guard !userId.isEmpty else { skippedEntries += 1; continue }
                switch strategy {
                case .merge:
                    _ = try records.mergeSync(SyncRecord(accounts: [userId: entry]),
                                              fileURL: records.centralSyncURL)
                case .overwrite:
                    _ = try records.setSyncAccount(userId: userId, anchorDay: entry.anchorDay,
                                                   ids: entry.ids, fileURL: records.centralSyncURL)
                }
            }

        case .distributed:
            guard !saveDir.isEmpty else { throw RecordIOError.missingSaveDirectory }
            let folders = accountDirs(in: saveDir)
            for (userId, ids) in incoming.downloads {
                guard !userId.isEmpty else { skippedEntries += 1; continue }
                guard let dir = distributedTargetDir(userId: userId, saveDir: saveDir,
                                                     folders: folders) else {
                    skippedAccounts.insert(userId)
                    continue
                }
                if ids.isEmpty, strategy == .merge { continue }   // 同上：覆盖模式下要写空清残留
                let url = records.distributedDownloadURL(accountDir: dir, fileName: recordFileName)
                switch strategy {
                case .merge:
                    _ = try records.mergeDownloadIds(ids, userId: userId, fileURL: url)
                case .overwrite:
                    _ = try records.overwriteDownloadIds(ids, userId: userId, fileURL: url)
                }
            }
            for (userId, entry) in incoming.sync {
                guard !userId.isEmpty else { skippedEntries += 1; continue }
                // 同步记录**不回落根目录**：`SyncStore` 一律按账号文件夹写
                // （见 `SyncStore.accountDirectory`），根下的 .synced.json 永远不会被读到
                guard let folder = folders.first(where: { $0.userId == userId }) else {
                    skippedAccounts.insert(userId)
                    continue
                }
                let url = records.distributedSyncURL(accountDir: folder.dir)
                switch strategy {
                case .merge:
                    _ = try records.mergeSync(SyncRecord(accounts: [userId: entry]), fileURL: url)
                case .overwrite:
                    _ = try records.setSyncAccount(userId: userId, anchorDay: entry.anchorDay,
                                                   ids: entry.ids, fileURL: url)
                }
            }
        }

        let after = try collect(form: form, saveDir: saveDir,
                                recordFileName: recordFileName, records: records)
        let added = pairKeys(after.state).subtracting(pairKeys(before.state)).count
        return RecordImportReport(
            recognizedAccounts: max(0, incoming.accountCount - skippedAccounts.count),
            addedEntries: added,
            // 无法定位：账号写不进去的 + 源里账号为空的条目 + 源本身读到的无法定位条目。
            // 后一项来自 `rebuildFromFileNames`（没有 [数字id] 的目录 / 根下空 user_id 的
            // 共享记录）与导出包里的空账号条目——它们不在 skippedAccounts 里，但必须计数。
            unrecognizedEntries: skippedAccounts.count + skippedEntries + incoming.unlocatable)
    }

    /// (账号, 媒体 id) 对，用来算"新增"（下载记录与同步记录一起算）。
    private static func pairKeys(_ state: FormState) -> Set<String> {
        var keys = Set<String>()
        for (userId, record) in state.downloads {
            for id in record.ids { keys.insert("d|\(userId)|\(id)") }
        }
        for (userId, entry) in state.sync.accounts {
            for id in entry.ids { keys.insert("s|\(userId)|\(id)") }
        }
        return keys
    }

    /// 分布式形态下某个账号的记录该写在哪。
    ///
    /// - 该账号的文件夹存在 → 写它（正常情况）；
    /// - 保存路径下**一个账号文件夹都没有** → 写根下（§3 关键性质第 4 条：关闭账号子文件夹时就是这里）；
    /// - 有别的账号文件夹、偏偏没有它的 → nil（写根下不会被判定读到，
    ///   宁可让 UI 报"无法定位"，也不写一份永远不会生效的记录）。
    private static func distributedTargetDir(userId: String,
                                             saveDir: String,
                                             folders: [AccountFolderRef]) -> String? {
        if let match = folders.first(where: { $0.userId == userId }) { return match.dir }
        return folders.isEmpty ? saveDir : nil
    }

    // MARK: - 文件系统

    /// 账号文件夹：保存路径下**直接子目录**里名字带 `[数字id]` 的（§5.1）
    private struct AccountFolderRef {
        let userId: String
        let dir: String
    }

    private static func accountDirs(in saveDir: String) -> [AccountFolderRef] {
        directSubdirectories(in: saveDir).compactMap { entry -> AccountFolderRef? in
            guard let userId = AccountFolder.accountId(fromFolderName: entry.lastPathComponent) else {
                return nil
            }
            return AccountFolderRef(userId: userId, dir: entry.path)
        }.sorted { $0.userId < $1.userId }
    }

    /// 保存路径下**直接子目录**里，名字解析不出 `[数字id]` 的那些。
    ///
    /// 用途：F7 的"账号无法确定不得静默"——空作者 id 写过记录时会留下这种目录，
    /// 以前整棵目录在扫描时被跳过（用户只看到"导入完成 0 条"）。
    /// 隐藏目录整个忽略（记录文件的临时件不会是目录，且 `.*` 是系统目录的习惯）。
    private static func unparsableDirs(in saveDir: String) -> [String] {
        directSubdirectories(in: saveDir)
            .filter { AccountFolder.accountId(fromFolderName: $0.lastPathComponent) == nil }
            .map(\.path)
    }

    /// 保存路径下的直接子目录（跳过隐藏目录）
    ///
    /// **读取失败不再折叠成"空"**：上层导入/重建把"目录里确实没有东西"与"扫描不了"
    /// 当成同一个结果，用户就会看到一个看起来正常的"0 条"。目录不存在是正常的空
    /// （全新安装），只有**存在却读不了**才告警。
    private static func directSubdirectories(in saveDir: String) -> [URL] {
        let url = URL(fileURLWithPath: saveDir, isDirectory: true)
        guard FileManager.default.fileExists(atPath: saveDir) else { return [] }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            AppLogger.warn("读取目录失败,扫描结果不完整", category: "REC", [
                "dir": saveDir, "error": error.localizedDescription,
            ])
            return []
        }
        return entries.filter { entry in
            guard !entry.lastPathComponent.hasPrefix(".") else { return false }
            return (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// 目录下的普通文件（跳过隐藏文件：记录文件与 `.DS_Store` 都以 `.` 开头）
    ///
    /// 同 `directSubdirectories`：目录不存在按空处理，存在却读不了要告警。
    private static func regularFiles(in dir: String) -> [URL] {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir) else { return [] }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isRegularFileKey])
        } catch {
            AppLogger.warn("读取目录失败,扫描结果不完整", category: "REC", [
                "dir": dir, "error": error.localizedDescription,
            ])
            return []
        }
        return entries.filter { entry in
            guard !entry.lastPathComponent.hasPrefix(".") else { return false }
            return (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    // MARK: - 文件名 → 媒体 id（契约 §8）

    /// 从文件名里取**最后一个** `[<15~25 位纯 ASCII 数字>]` 组。
    ///
    /// # 为什么是方括号 + "取最后一个"
    ///
    /// 媒体 id 由命名规则包在方括号里（`… 2098843535730725124[2098843532463411200].jpg`），
    /// 但**模板变量自身可能带方括号**，所以不能简单地"取第一个/取任意一个"：
    /// - `%USER_NAME%`（昵称）：X 昵称几乎允许任意字符，`Tesla [Fan]` 很常见；
    /// - `%CONTENT%`（正文截断）：推文里出现 `[cool]` 之类毫不稀奇；
    /// - `%USER_SCREEN_NAME%`（用户名）反而不可能（字符集只允许 `[A-Za-z0-9_]`）。
    /// 而 `UnicodeFilename.filenamify` 的转义集是 `<>:"/\|?*` 与控制字符，**不含方括号**，
    /// 所以昵称/正文里的括号会原样进文件名。
    ///
    /// 唯一标识总是追加在**最后**（扩展名之前），因此"取最后一个满足条件的方括号组"是稳的：
    /// 前面那些括号要么内容不是纯数字，要么位数不对，自然被跳过。
    ///
    /// 两条约束一起用：**内容全是 ASCII 数字**（全角 `１２３`、圈号 `①`、`½` 都不认）
    /// 且**长度 15~25**（X 的 snowflake id 量级；年份 `[2026]`、序号 `[1]` 因此不会误认）。
    /// 位数窗口在这里只是第二道保险——主要依据是"它是最后一个方括号组"。
    ///
    /// 断点/临时文件（`….jpg.part.http`）由调用方用 `isEnginePartial` 整类跳过，不走这里。
    static func mediaId(fromFileName fileName: String) -> String? {
        var result: String?
        var searchStart = fileName.startIndex
        while let open = fileName[searchStart...].firstIndex(of: "["),
              let close = fileName[open...].firstIndex(of: "]") {
            let inner = fileName[fileName.index(after: open)..<close]
            if !inner.isEmpty,
               inner.allSatisfy(isASCIIDigit),
               (15...25).contains(inner.count) {
                result = String(inner)   // 持续覆盖 → 天然取最后一个
            }
            guard close < fileName.endIndex else { break }
            searchStart = fileName.index(after: close)
        }
        return result
    }
    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}

/// 记录导入导出可预期的失败（**明确报错，不静默返回空结果**——
/// 空结果会让 UI 显示"导入成功 0 条"，比报错更难查）。
enum RecordIOError: LocalizedError, Equatable {
    /// 保存路径为空（分布式形态无法定位账号文件夹）
    case missingSaveDirectory
    /// 导出文件读不出来（不存在 / 无权限）
    case unreadableFile(String)
    /// 不是有效的导出包（kind / version 不符，或根本不是 JSON）
    case invalidExportFile
    /// `importRecords` 收到了只适用于 `rebuildFromFileNames` 的来源
    case unsupportedSource

    var errorDescription: String? {
        switch self {
        case .missingSaveDirectory: return L("保存路径为空，无法定位记录文件")
        case .unreadableFile(let name): return L("文件读不出来：") + name
        case .invalidExportFile: return L("不是有效的记录导出文件")
        case .unsupportedSource: return L("该来源请走「按文件名重建记录」入口")
        }
    }
}
