import Foundation

// MARK: - 数据形状（v1）
//
// 契约见仓库根目录 `MEDIA_RECORDS.md`（§4 数据形状、§11 实现落点）。
// 一句话：记录只记「资源 id」这类最小信息；账号一律用数字 id；
// 两种形态（分布式 = 账号文件夹里一份 / 集中式 = 应用数据目录里）。

/// 下载记录（媒体去重用）。一个账号一份。
///
/// JSON（v1）：
/// ```json
/// { "version": 1, "kind": "xspider.download-record",
///   "user_id": "13298072", "ids": ["2098843532463411200"] }
/// ```
///
/// `user_id` 是**媒体作者**的数字 id（分布式形态下、多个作者共用一个文件夹时，
/// 取首个写入的账号，之后不再改写——它只是给人看的归属标记，判定只看 `ids`）。
struct DownloadRecord: Codable, Equatable, Sendable {
    static let kindName = "xspider.download-record"
    static let currentVersion = 1

    var version: Int
    var kind: String
    /// 账号的数字 id（媒体作者）
    var userId: String
    /// 已下载媒体的资源 id 集合（写入时按字典序排序，输出稳定便于 diff）
    var ids: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case kind
        case userId = "user_id"
        case ids
    }

    init(userId: String, ids: [String]) {
        self.version = Self.currentVersion
        self.kind = Self.kindName
        self.userId = userId
        self.ids = Self.normalizedIds(ids)
    }

    /// kind / version 校验：不合法整份丢弃（按"没有记录"处理，不迁移）。
    var isValid: Bool {
        version == Self.currentVersion && kind == Self.kindName
    }

    /// id 并集 + 字典序（相同的 id 合并成一份）。
    static func normalizedIds(_ ids: [String]) -> [String] {
        Array(Set(ids.filter { !$0.isEmpty })).sorted()
    }

    /// 解码并校验；文件损坏 / 版本不符 / kind 不符 → nil（不抛错，调用方按无记录处理）。
    static func decode(from data: Data) -> DownloadRecord? {
        guard let record = try? JSONDecoder().decode(DownloadRecord.self, from: data),
              record.isValid else { return nil }
        return record
    }
}

/// 同步记录里一个账号的条目。
struct SyncAccountRecord: Codable, Equatable, Sendable {
    /// 本轮见到的最新媒体日期（本地日历 `yyyy-MM-dd`）
    var anchorDay: String
    /// 同步窗口内已确认存在的全部媒体 id（含本轮跳过的）
    var ids: [String]

    enum CodingKeys: String, CodingKey {
        case anchorDay = "anchor_day"
        case ids
    }

    init(anchorDay: String, ids: [String]) {
        self.anchorDay = anchorDay
        self.ids = DownloadRecord.normalizedIds(ids)
    }
}

/// 同步记录（整份文件）。集中式一份装所有账号；分布式每个账号文件夹一份。
///
/// JSON（v1）：
/// ```json
/// { "version": 1, "kind": "xspider.sync-record",
///   "accounts": { "13298072": { "anchor_day": "2026-09-29", "ids": ["…"] } } }
/// ```
struct SyncRecord: Codable, Equatable, Sendable {
    static let kindName = "xspider.sync-record"
    static let currentVersion = 1

    var version: Int
    var kind: String
    /// 账号数字 id → 条目
    var accounts: [String: SyncAccountRecord]

    init(accounts: [String: SyncAccountRecord] = [:]) {
        self.version = Self.currentVersion
        self.kind = Self.kindName
        self.accounts = accounts
    }

    var isValid: Bool {
        version == Self.currentVersion && kind == Self.kindName
    }

    static func decode(from data: Data) -> SyncRecord? {
        guard let record = try? JSONDecoder().decode(SyncRecord.self, from: data),
              record.isValid else { return nil }
        return record
    }

    /// 合并（导入「追加」语义）：`anchor_day` 取较晚者 + ids 并集。
    ///
    /// 字符串比较即日期比较——`yyyy-MM-dd` 是定宽补零格式，字典序与时间序一致；
    /// 空串（无锚点）视为最早，任何有效日期都会顶掉它。
    static func merged(_ lhs: SyncRecord, _ rhs: SyncRecord) -> SyncRecord {
        var out = lhs
        for (userId, incoming) in rhs.accounts {
            if let existing = out.accounts[userId] {
                out.accounts[userId] = SyncAccountRecord(
                    anchorDay: max(existing.anchorDay, incoming.anchorDay),
                    ids: existing.ids + incoming.ids
                )
            } else {
                out.accounts[userId] = SyncAccountRecord(
                    anchorDay: incoming.anchorDay,
                    ids: incoming.ids
                )
            }
        }
        return out
    }
}

/// 导出包（v1）。导入/导出是第 2 阶段（`Services/RecordsIO.swift`）的落点，
/// 这里只钉住形状，保证导出/导入两侧用的是同一个类型。
///
/// JSON（v1）：
/// ```json
/// { "version": 1, "kind": "xspider.records-export",
///   "downloads": { "13298072": ["2098843532463411200"] },
///   "sync": { "13298072": { "anchor_day": "2026-09-29", "ids": ["…"] } } }
/// ```
struct RecordsExport: Codable, Equatable, Sendable {
    static let kindName = "xspider.records-export"
    static let currentVersion = 1

    var version: Int
    var kind: String
    /// 账号数字 id → 媒体 id 列表
    var downloads: [String: [String]]
    /// 账号数字 id → 同步条目
    var sync: [String: SyncAccountRecord]

    init(downloads: [String: [String]] = [:], sync: [String: SyncAccountRecord] = [:]) {
        self.version = Self.currentVersion
        self.kind = Self.kindName
        self.downloads = downloads.mapValues { DownloadRecord.normalizedIds($0) }
        self.sync = sync
    }

    var isValid: Bool {
        version == Self.currentVersion && kind == Self.kindName
    }

    static func decode(from data: Data) -> RecordsExport? {
        guard let record = try? JSONDecoder().decode(RecordsExport.self, from: data),
              record.isValid else { return nil }
        return record
    }
}

/// 记录的两种形态（判定依据里的「记录文件·分布式 / 记录文件·集中式」）。
enum RecordForm: String, CaseIterable, Sendable {
    /// 分布式：`<保存路径>/<账号文件夹>/.downloadedrecord.json`（跟随保存路径）
    case distributed
    /// 集中式：`~/Library/Application Support/XSpiderMac/records/`（与媒体文件分离）
    case centralized
}

/// 记录层错误。
enum MediaRecordError: LocalizedError {
    /// 分布式形态需要一个账号文件夹路径，但调用方没给
    case missingAccountDirectory
    /// 账号 id 为空（无法定位集中式文件）
    case invalidAccountId
    /// 序列化失败（理论上不会发生：记录都是 UTF-8 字符串与整数）
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAccountDirectory: return "缺少账号文件夹路径（分布式记录无法定位）"
        case .invalidAccountId: return "账号 id 为空（集中式记录无法定位）"
        case .encodingFailed: return "记录序列化失败"
        }
    }
}

// MARK: - JSON 编码与原子写

/// 能给出规范 JSON 文本的记录结构（`MEDIA_RECORDS.md` §4 的三种形状）。
///
/// 键序就是实现里的书写顺序——契约把键序写进了规范，所以键序是**被钉住的一部分**，
/// 不能再交给 `JSONEncoder` 的 `.sortedKeys`（那是字典序，与规范不符）。
protocol RecordJSONRepresentable {
    /// 该结构的完整 JSON 文本（含末尾换行，空数组写单行 `[]`）。
    func recordJSONRepresentation() -> String
}

/// 确定性 JSON 序列化：记录文件的字节与 `MEDIA_RECORDS.md` §4 逐字一致。
///
/// 为什么不直接用 `JSONEncoder`（实测三处不一致）：
/// 1. `.prettyPrinted` 的空数组输出是 `[` 与 `]` 之间夹一个空行，规范要求单行 `[]`；
/// 2. `.prettyPrinted` 末尾没有换行，规范要求一个换行；
/// 3. `.sortedKeys` 是字典序（`ids` 会排在 `kind` 前面），规范钉的是
///    `version, kind, user_id, ids`（同步记录 `version, kind, accounts`）。
///
/// 这三种结构形状固定且很小，所以**手写序列化**——不去正则修补 `JSONEncoder` 的输出
/// （修补会被"缩进宽度 / 空数组 / 键序"三件事同时放大，且改一处漏一处）。
enum RecordJSONWriter {

    // MARK: 顶层

    static func text(_ value: DownloadRecord) -> String {
        object([
            ("version", "\(value.version)"),
            ("kind", quoted(value.kind)),
            ("user_id", quoted(value.userId)),
            ("ids", array(value.ids, indent: 2)),
        ], indent: 0)
    }

    static func text(_ value: SyncRecord) -> String {
        object([
            ("version", "\(value.version)"),
            ("kind", quoted(value.kind)),
            ("accounts", accountsObject(value.accounts, indent: 2)),
        ], indent: 0)
    }

    static func text(_ value: RecordsExport) -> String {
        object([
            ("version", "\(value.version)"),
            ("kind", quoted(value.kind)),
            ("downloads", downloadsObject(value.downloads, indent: 2)),
            ("sync", accountsObject(value.sync, indent: 2)),
        ], indent: 0)
    }

    // MARK: 块

    /// `{ "key": value, … }`（`indent` = 本对象所在行的缩进）。
    private static func object(_ fields: [(String, String)], indent: Int) -> String {
        guard !fields.isEmpty else { return "{}" }
        let pad = String(repeating: " ", count: indent + 2)
        let closePad = String(repeating: " ", count: indent)
        let body = fields.map { "\(pad)\(quoted($0.0)): \($0.1)" }.joined(separator: ",\n")
        return "{\n\(body)\n\(closePad)}"
    }

    /// 字符串数组：空集合写单行 `[]`，否则每项一行（`indent` = 键所在行的缩进）。
    private static func array(_ values: [String], indent: Int) -> String {
        guard !values.isEmpty else { return "[]" }
        let pad = String(repeating: " ", count: indent + 2)
        let closePad = String(repeating: " ", count: indent)
        let body = values.map { "\(pad)\(quoted($0))" }.joined(separator: ",\n")
        return "[\n\(body)\n\(closePad)]"
    }

    /// 同步条目：`{ "anchor_day": …, "ids": […] }`
    private static func accountObject(_ entry: SyncAccountRecord, indent: Int) -> String {
        object([
            ("anchor_day", quoted(entry.anchorDay)),
            ("ids", array(entry.ids, indent: indent + 2)),
        ], indent: indent)
    }

    /// 账号字典：键按字典序（`accounts` / 导出包的 `sync`）。
    private static func accountsObject(_ accounts: [String: SyncAccountRecord], indent: Int) -> String {
        guard !accounts.isEmpty else { return "{}" }
        let fields = accounts.keys.sorted().map { ($0, accountObject(accounts[$0]!, indent: indent + 2)) }
        return object(fields, indent: indent)
    }

    /// 导出包的下载字典：键按字典序，值用与记录文件相同的数组形状。
    private static func downloadsObject(_ downloads: [String: [String]], indent: Int) -> String {
        guard !downloads.isEmpty else { return "{}" }
        let fields = downloads.keys.sorted().map { ($0, array(downloads[$0]!, indent: indent + 2)) }
        return object(fields, indent: indent)
    }

    // MARK: 标量

    /// JSON 字符串字面量（UTF-8 原样，仅转义 JSON 规定的字符）。
    private static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

extension DownloadRecord: RecordJSONRepresentable {
    /// 规范 §4：`version, kind, user_id, ids`，2 空格缩进，末尾一个换行。
    func recordJSONRepresentation() -> String {
        RecordJSONWriter.text(self) + "\n"
    }
}

extension SyncRecord: RecordJSONRepresentable {
    /// 规范 §4.2：`version, kind, accounts`，2 空格缩进，末尾一个换行。
    func recordJSONRepresentation() -> String {
        RecordJSONWriter.text(self) + "\n"
    }
}

extension RecordsExport: RecordJSONRepresentable {
    /// 规范 §4.3：`version, kind, downloads, sync`，2 空格缩进，末尾一个换行。
    func recordJSONRepresentation() -> String {
        RecordJSONWriter.text(self) + "\n"
    }
}

enum MediaRecordJSON {
    /// 统一编码：**确定性序列化**（键序 / 2 空格缩进 / 末尾换行 / 空数组 `[]`，见
    /// `RecordJSONWriter`），字节与 `MEDIA_RECORDS.md` §4 逐字一致。
    ///
    /// `ids` 的排序由 `normalizedIds` 保证；这里只负责形状。
    static func encode<T: RecordJSONRepresentable>(_ value: T) throws -> Data {
        guard let data = value.recordJSONRepresentation().data(using: .utf8) else {
            throw MediaRecordError.encodingFailed
        }
        return data
    }

    /// 原子落盘：同目录临时文件写入完整内容后 rename 覆盖目标。
    ///
    /// 为什么必须原子：记录文件是"重启后能不能对账"的唯一依据，
    /// 半截 JSON（写完之前断电 / 进程被杀）会让整份记录作废。
    /// 临时文件与目标同目录，保证 rename 在同一文件系统上（跨卷 rename 不原子）。
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}

// MARK: - 记录层

/// 媒体记录层：下载记录 + 同步记录，分布式 / 集中式两种形态。
///
/// 三条纪律（契约 `MEDIA_RECORDS.md` §3/§4/§11.3）：
/// 1. **集中式的下载记录一账号一文件**（`records/downloads/<user id>.json`）：
///    用到才加载、只回写该账号那一份——一个账号的记录损坏不带走整个库；
/// 2. **缓存按需加载**：读过的文件进内存缓存（`invalidate()` 清空），
///    避免 `hasDownloaded` 这类高频判定每次都读盘；
/// 3. **写入一律原子**（`MediaRecordJSON.writeAtomically`）。
///
/// 线程安全：内部 `NSLock` 保护缓存；文件读写同步完成（记录文件都很小）。
/// 集中式根目录可注入（测试用临时目录），默认 `AppDirectories.recordsRoot`。
final class MediaRecords: @unchecked Sendable {
    static let shared = MediaRecords()

    /// 分布式下载记录的默认文件名（设置项可改）
    static let defaultDownloadRecordName = ".downloadedrecord.json"
    /// 分布式同步记录的文件名（固定，不可改）
    static let defaultSyncRecordName = ".synced.json"

    /// 集中式根目录：`~/Library/Application Support/XSpiderMac/records`
    static var defaultCentralRoot: URL { AppDirectories.recordsRoot }

    let centralRoot: URL

    private let fm = FileManager.default
    private let lock = NSLock()
    private var downloadCache: [String: DownloadRecord] = [:]
    private var syncCache: [String: SyncRecord] = [:]
    /// 记录文件路径 → 其中的 id 集合。
    ///
    /// 为什么单独缓存：判定是 `ids.contains(mediaId)`，而 `ids` 是数组——
    /// 一个账号几千个媒体就是几千次字符串比较，批量建任务时逐媒体都要判定一次
    /// （实测这条在批量创建时是主线程热点之一）。Set 把它降到 O(1)。
    private var downloadIdSets: [String: Set<String>] = [:]

    init(centralRoot: URL = MediaRecords.defaultCentralRoot) {
        self.centralRoot = centralRoot
    }

    // MARK: - 路径

    /// 集中式下载记录：`<root>/downloads/<user id>.json`
    func centralDownloadURL(userId: String) -> URL {
        centralRoot
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent("\(userId).json")
    }

    /// 集中式同步记录：`<root>/sync.json`（所有账号一个文件，不拆）
    var centralSyncURL: URL {
        centralRoot.appendingPathComponent("sync.json")
    }

    /// 分布式下载记录：`<账号文件夹>/<记录文件名>`
    func distributedDownloadURL(accountDir: String,
                                fileName: String = MediaRecords.defaultDownloadRecordName) -> URL {
        URL(fileURLWithPath: accountDir, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 分布式同步记录：`<账号文件夹>/.synced.json`
    func distributedSyncURL(accountDir: String) -> URL {
        URL(fileURLWithPath: accountDir, isDirectory: true)
            .appendingPathComponent(Self.defaultSyncRecordName)
    }

    /// 按形态解析同步记录文件；分布式缺账号文件夹 / 集中式条目按账号取 → nil。
    func syncURL(form: RecordForm, accountDir: String?) -> URL? {
        switch form {
        case .distributed:
            guard let accountDir, !accountDir.isEmpty else { return nil }
            return distributedSyncURL(accountDir: accountDir)
        case .centralized:
            return centralSyncURL
        }
    }

    // MARK: - 下载记录 · 读

    /// 读一份下载记录（带缓存；文件缺失 / 不合法 → nil）。
    func loadDownload(fileURL: URL) -> DownloadRecord? {
        if let cached = lock.withLock({ downloadCache[fileURL.path] }) { return cached }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let record = DownloadRecord.decode(from: data) else {
            AppLogger.warn("下载记录不合法,已忽略", category: "DL", ["file": fileURL.path])
            return nil
        }
        let idSet = Set(record.ids)
        lock.withLock {
            downloadCache[fileURL.path] = record
            downloadIdSets[fileURL.path] = idSet
        }
        return record
    }

    /// 记录文件路径 → 其中的 id 集合（顺带把记录读进缓存）。
    private func downloadIdSet(fileURL: URL) -> Set<String>? {
        if let cached = lock.withLock({ downloadIdSets[fileURL.path] }) { return cached }
        guard loadDownload(fileURL: fileURL) != nil else { return nil }
        return lock.withLock { downloadIdSets[fileURL.path] }
    }

    /// 读集中式下载记录；文件里的 `user_id` 与文件名不符 → 视为损坏（忽略并告警）。
    func loadCentralDownload(userId: String) -> DownloadRecord? {
        guard !userId.isEmpty else { return nil }
        guard let record = loadDownload(fileURL: centralDownloadURL(userId: userId)) else { return nil }
        guard record.userId.isEmpty || record.userId == userId else {
            AppLogger.warn("下载记录的 user_id 与文件名不符,已忽略", category: "DL", [
                "file": centralDownloadURL(userId: userId).path, "user_id": record.userId,
            ])
            return nil
        }
        return record
    }

    /// 媒体 id 是否在某份记录里（判定只信记录、不回查文件）。
    func isDownloaded(mediaId: String, fileURL: URL) -> Bool {
        guard !mediaId.isEmpty else { return false }
        return downloadIdSet(fileURL: fileURL)?.contains(mediaId) ?? false
    }

    /// 媒体 id 是否在集中式记录里。
    func isDownloaded(mediaId: String, userId: String) -> Bool {
        guard !mediaId.isEmpty, !userId.isEmpty else { return false }
        return downloadIdSet(fileURL: centralDownloadURL(userId: userId))?.contains(mediaId) ?? false
    }

    /// 扫集中式 `downloads/` 目录，读出全部账号的下载记录（导出 / 对账用）。
    func loadAllCentralDownloads() -> [String: DownloadRecord] {
        var out: [String: DownloadRecord] = [:]
        let dir = centralRoot.appendingPathComponent("downloads", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return out
        }
        for url in entries where url.pathExtension == "json" {
            let userId = url.deletingPathExtension().lastPathComponent
            if let record = loadCentralDownload(userId: userId) { out[userId] = record }
        }
        return out
    }

    // MARK: - 下载记录 · 写

    /// 覆盖写一份下载记录（原子），并同步更新缓存。
    @discardableResult
    func writeDownload(_ record: DownloadRecord, fileURL: URL) throws -> DownloadRecord {
        let data = try MediaRecordJSON.encode(record)
        try MediaRecordJSON.writeAtomically(data, to: fileURL)
        lock.withLock {
            downloadCache[fileURL.path] = record
            downloadIdSets[fileURL.path] = Set(record.ids)
        }
        return record
    }

    /// 追加一个媒体 id（读-改-写，幂等）。
    ///
    /// - Returns: `true` = 这次真的写入了（此前不在记录里）；
    ///   `false` = 已存在（无操作）或写入失败（已告警）。
    @discardableResult
    func appendDownloadId(_ mediaId: String, userId: String, fileURL: URL) -> Bool {
        guard !mediaId.isEmpty else { return false }
        var record = loadDownload(fileURL: fileURL) ?? DownloadRecord(userId: userId, ids: [])
        guard !record.ids.contains(mediaId) else { return false }
        // 首个写入者定下 user_id；之后不再改写（多作者共用一个文件夹时只作标记）
        if record.userId.isEmpty { record.userId = userId }
        record.ids.append(mediaId)
        record.ids = DownloadRecord.normalizedIds(record.ids)
        do {
            try writeDownload(record, fileURL: fileURL)
            return true
        } catch {
            AppLogger.warn("下载记录写入失败", category: "DL", [
                "file": fileURL.path, "error": error.localizedDescription,
            ])
            return false
        }
    }

    /// 追加到集中式下载记录（一账号一文件，只回写该账号那一份）。
    @discardableResult
    func appendCentralDownloadId(_ mediaId: String, userId: String) -> Bool {
        guard !userId.isEmpty, !mediaId.isEmpty else { return false }
        return appendDownloadId(mediaId, userId: userId, fileURL: centralDownloadURL(userId: userId))
    }

    /// 合并（id 并集，导入「追加」语义）。
    @discardableResult
    func mergeDownloadIds(_ ids: [String], userId: String, fileURL: URL) throws -> DownloadRecord {
        var record = loadDownload(fileURL: fileURL) ?? DownloadRecord(userId: userId, ids: [])
        if record.userId.isEmpty { record.userId = userId }
        record.ids = DownloadRecord.normalizedIds(record.ids + ids)
        return try writeDownload(record, fileURL: fileURL)
    }

    /// 覆盖（导入「覆盖」语义）。
    @discardableResult
    func overwriteDownloadIds(_ ids: [String], userId: String, fileURL: URL) throws -> DownloadRecord {
        try writeDownload(DownloadRecord(userId: userId, ids: ids), fileURL: fileURL)
    }

    // MARK: - 同步记录

    /// 读一份同步记录（带缓存）。
    func loadSync(fileURL: URL) -> SyncRecord? {
        if let cached = lock.withLock({ syncCache[fileURL.path] }) { return cached }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let record = SyncRecord.decode(from: data) else {
            AppLogger.warn("同步记录不合法,已忽略", category: "SYNC", ["file": fileURL.path])
            return nil
        }
        lock.withLock { syncCache[fileURL.path] = record }
        return record
    }

    /// 按形态读同步记录（分布式缺账号文件夹 → nil）。
    func loadSync(form: RecordForm, accountDir: String?) -> SyncRecord? {
        guard let url = syncURL(form: form, accountDir: accountDir) else { return nil }
        return loadSync(fileURL: url)
    }

    /// 某账号的同步条目。
    func syncAccount(userId: String, fileURL: URL) -> SyncAccountRecord? {
        loadSync(fileURL: fileURL)?.accounts[userId]
    }

    /// 覆盖写一份同步记录（原子）。
    @discardableResult
    func writeSync(_ record: SyncRecord, fileURL: URL) throws -> SyncRecord {
        let data = try MediaRecordJSON.encode(record)
        try MediaRecordJSON.writeAtomically(data, to: fileURL)
        lock.withLock { syncCache[fileURL.path] = record }
        return record
    }

    /// 写入某账号的同步条目（替换该账号那一份，其他账号不动）。
    ///
    /// 窗口语义（anchor_day / ids 怎么算）由调用方决定，见 `MEDIA_RECORDS.md` §6.3。
    @discardableResult
    func setSyncAccount(userId: String, anchorDay: String, ids: [String],
                        fileURL: URL) throws -> SyncRecord {
        guard !userId.isEmpty else { throw MediaRecordError.invalidAccountId }
        var record = loadSync(fileURL: fileURL) ?? SyncRecord()
        record.accounts[userId] = SyncAccountRecord(anchorDay: anchorDay, ids: ids)
        return try writeSync(record, fileURL: fileURL)
    }

    /// 合并一份同步记录（导入「追加」语义：anchor 取较晚 + ids 并集）。
    @discardableResult
    func mergeSync(_ incoming: SyncRecord, fileURL: URL) throws -> SyncRecord {
        let existing = loadSync(fileURL: fileURL) ?? SyncRecord()
        return try writeSync(SyncRecord.merged(existing, incoming), fileURL: fileURL)
    }

    // MARK: - 缓存

    /// 失效全部缓存（设置变更 / 外部改动记录文件后调用），下次按需从磁盘重读。
    func invalidate() {
        lock.withLock {
            downloadCache.removeAll()
            downloadIdSets.removeAll()
            syncCache.removeAll()
        }
    }
}
