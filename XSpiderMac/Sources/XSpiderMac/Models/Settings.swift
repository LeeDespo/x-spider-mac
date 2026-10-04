import Foundation

struct ProxySettings: Codable, Sendable {
    /// 代理总开关（默认**关**：新装用户先直连，需要时再自行开启）
    var enable: Bool = false
    var url: String = "http://127.0.0.1:7890"
    var useSystem: Bool = true
    /// 代理身份验证（可选）
    var username: String?
    var password: String?
}

/// 下载引擎
enum DownloadEngine: String, Codable, CaseIterable, Sendable {
    case builtIn
    case aria2
    /// 自动：按文件大小决定（小于阈值用内置，大文件用 aria2）
    case auto

    var displayName: String {
        switch self {
        case .builtIn: return L("内置引擎")
        case .aria2: return "aria2Next"
        case .auto: return L("自动")
        }
    }
}

/// aria2 RPC 监听端口策略
enum Aria2PortMode: String, Codable, CaseIterable, Sendable {
    /// 固定端口（默认 6801）
    case fixed
    /// 每次启动随机可用端口（避免与其它 aria2 软件冲突）
    case random

    var displayName: String {
        switch self {
        case .fixed: return L("固定端口")
        case .random: return L("随机端口")
        }
    }
}

struct DownloadSettings: Codable, Sendable {
    var saveDirBase: String = ""
    /// 已废弃（保留解码兼容），目录规则改用 accountSubfolder 开关
    var dirTemplate: String = ""
    /// 文件名模板（默认含时间/用户名/推文 id；不要写 `%MEDIA_ID%`，见 §5.3）
    var fileNameTemplate: String = DownloadSettings.defaultFileNameTemplate
    var sameFileSkip: Bool = true
    /// 下载判定依据：fileName / distributed / centralized（契约 `MEDIA_RECORDS.md` §6.1）。
    /// **默认 `centralized`**（本轮用户拍板，理由见 `Settings.currentSchemaVersion`）。
    var sameFileCheckMode: String?
    /// 记录文件名（**仅分布式**形态创建在每个账号文件夹里，见 §9）
    var recordFileName: String?
    /// 文件名追加唯一标识（媒体 id 后缀，见 §5.2）。
    /// nil 视为**打开**（默认打开）；任一判定选「按文件名」时派生值强制为 true
    /// （见 `Settings.appendUniqueIdEnabled` 与 §6.2 联动规则）。
    var appendUniqueId: Bool?
    /// 导入 / 导出 / 按文件名重建记录使用的形态（契约 §7/§8）。
    ///
    /// **与「判定依据」无关**：判定决定"怎么算已下载"，这里决定那三个入口读写哪一份记录。
    /// 此前界面从下载判定推断形态，于是判定选「按文件名」时一律按分布式走——
    /// 集中式记录（在应用数据目录）既导不出、也写不回。
    /// **默认 `centralized`**（本轮用户拍板，理由见 `Settings.currentSchemaVersion`）。
    var recordsForm: String?
    /// 按账号建子目录：`昵称-用户名[数字id]`（契约 §5.1，如 `<保存路径>/Tesla-Tesla[13298072]`）
    var accountSubfolder: Bool?
    /// 主页搜索后是否自动加载媒体时间线（关闭省流量，只显示用户卡与下载配置）
    var autoLoadMedia: Bool?
    /// 下载引擎：aria2 / 内置 URLSession
    var engine: DownloadEngine?
    /// 同时并发下载文件数（1–20，默认 5）
    var maxConcurrent: Int?
    // aria2 参数
    /// 单文件最大连接数（aria2Next 的 `stream-max-connections`，范围 1–256，默认 6）。
    ///
    /// 旧字段名 aria2Split 沿用（避免配置迁移），但语义已对齐 aria2Next：
    /// 旧的 `--split` / `--max-connection-per-server` 在 aria2Next 中已退役，
    /// 会被"近似映射"到本选项。
    var aria2Split: Int?
    /// aria2 文件分配方式：none / prealloc / falloc
    var aria2FileAllocation: String?
    /// 自动引擎模式下，超过此大小（MB）改用 aria2Next（默认 5）
    var aria2SizeThresholdMB: Int?
    /// aria2 RPC 监听端口（fixed 模式使用，默认 6801）
    var aria2Port: Int?
    /// 端口策略：fixed / random（默认 fixed 6801）
    var aria2PortMode: String?

    init() {
        sameFileCheckMode = SameFileCheckMode.centralized.rawValue
        recordFileName = MediaRecords.defaultDownloadRecordName
        appendUniqueId = true
        recordsForm = RecordForm.centralized.rawValue
        accountSubfolder = true
        autoLoadMedia = true
        engine = .aria2
        maxConcurrent = 5
        aria2Split = 6
        aria2FileAllocation = "none"
        aria2SizeThresholdMB = 5
        aria2Port = 6801
        aria2PortMode = "fixed"
    }

    // 自定义解码：新字段缺失时用新默认值而不是整体 decode 失败
    //
    // **注意事项：这里不做任何旧值映射**（旧值 `recordFile` / `syncRecordFile` 会被
    // 一次性覆盖成新默认值，见 `Settings.currentSchemaVersion` 与
    // `SettingsStore.applySchemaDefaultsOnce`）。解码只负责"把键读出来"，
    // 认不出来的取值原样保留、由上层按 `SameFileCheckMode(rawValue:)` 兜底；
    // 把映射写在这里会让"用户选了 centralized 却重启回退"这类问题重新出现。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saveDirBase = try c.decodeIfPresent(String.self, forKey: .saveDirBase) ?? ""
        dirTemplate = try c.decodeIfPresent(String.self, forKey: .dirTemplate) ?? ""
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate).map {
            DownloadSettings.cleaningLegacyTemplate($0)
        } ?? DownloadSettings.defaultFileNameTemplate
        sameFileSkip = try c.decodeIfPresent(Bool.self, forKey: .sameFileSkip) ?? true
        sameFileCheckMode = try c.decodeIfPresent(String.self, forKey: .sameFileCheckMode)
        recordFileName = try c.decodeIfPresent(String.self, forKey: .recordFileName)
        appendUniqueId = try c.decodeIfPresent(Bool.self, forKey: .appendUniqueId)
        recordsForm = try c.decodeIfPresent(String.self, forKey: .recordsForm)
        accountSubfolder = try c.decodeIfPresent(Bool.self, forKey: .accountSubfolder) ?? true
        autoLoadMedia = try c.decodeIfPresent(Bool.self, forKey: .autoLoadMedia) ?? true
        engine = try c.decodeIfPresent(DownloadEngine.self, forKey: .engine) ?? .aria2
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 5
        aria2Split = try c.decodeIfPresent(Int.self, forKey: .aria2Split) ?? 6
        aria2FileAllocation = try c.decodeIfPresent(String.self, forKey: .aria2FileAllocation) ?? "none"
        aria2SizeThresholdMB = try c.decodeIfPresent(Int.self, forKey: .aria2SizeThresholdMB) ?? 5
        aria2Port = try c.decodeIfPresent(Int.self, forKey: .aria2Port) ?? 6801
        aria2PortMode = try c.decodeIfPresent(String.self, forKey: .aria2PortMode) ?? "fixed"
    }

    // MARK: - 默认值与模板清理

    /// 默认文件名模板（与旧默认一致）。
    static let defaultFileNameTemplate = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%"

    /// 加载设置时清理模板里的 `%MEDIA_ID%`（契约 §5.3：只做这一处清理）。
    ///
    /// 变量已从 `FileNameTemplate.variables` 删去，留着它只会解析成一串原样文本
    /// （或让用户误以为还能用）。顺带把由此产生的一个多余空格收掉
    /// （`… %MEDIA_ID% %EXT%` → `… %EXT%`），其余空格不动。
    static func cleaningLegacyTemplate(_ template: String) -> String {
        guard template.contains("%MEDIA_ID%") else { return template }
        var cleaned = template.replacingOccurrences(of: "%MEDIA_ID%", with: "")
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// 记录文件名的历史默认值：`.downloaded.json`。
    ///
    /// 与契约 §10「不读旧数据」冲突的只有这一处：老用户存储里全是这个默认值，
    /// 若原样沿用，就会**继续读写旧文件**。因此把它视为"未设置"，改用新默认。
    /// 用户自定义过的名字（非此值）原样保留。
    static let legacyDefaultRecordFileName = ".downloaded.json"
}

struct SyncSettings: Codable, Sendable {
    /// 打开应用自动开始同步
    var autoSyncOnLaunch: Bool?
    /// 同步完成且无失败后自动退出应用
    var quitOnSyncComplete: Bool?
    /// 同步页布局：dock（仿 Dock）/ honeycomb（蜂窝）
    var layout: String?
    /// 同步判定依据：fileName / distributed / centralized
    /// **默认 `centralized`**（本轮用户拍板，理由见 `Settings.currentSchemaVersion`）
    var syncCheckMode: String?
    init() {
        autoSyncOnLaunch = false
        quitOnSyncComplete = false
        layout = "dock"
        syncCheckMode = SyncCheckMode.centralized.rawValue
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoSyncOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoSyncOnLaunch) ?? false
        quitOnSyncComplete = try c.decodeIfPresent(Bool.self, forKey: .quitOnSyncComplete) ?? false
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? "dock"
        // 不做旧值映射（旧值由一次性覆盖处理，见 Settings.currentSchemaVersion）
        syncCheckMode = try c.decodeIfPresent(String.self, forKey: .syncCheckMode)
    }
}

/// 同步页布局模式
enum SyncLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case dock
    case honeycomb

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dock: return L("仿 Dock 布局")
        case .honeycomb: return L("蜂窝布局")
        }
    }
}

/// 限流缓解（可选字段：旧的已存配置缺这些键时按默认值兜底，不整体解码失败）
///
/// 注意区分两类限流：**GraphQL API**（x.com/i/api，受账号配额约束，管翻页/爬虫）
/// 与 **媒体 CDN**（pbs.twimg.com / video.twimg.com，管图片视频下载）。二者是不同的域、
/// 不同的配额，因此各自独立配置。
struct RateLimitSettings: Codable, Sendable {
    // ── GraphQL（API）──
    /// 请求闸门开关：按端点分类排队 + 令牌桶限速
    var gateEnabled: Bool?
    /// 时间窗内允许的请求数（令牌桶容量）
    var requestsPerWindow: Int?
    /// 时间窗秒数
    var windowSeconds: Int?
    /// 同一端点串行（前一请求完成前不发下一个）
    var serializePerEndpoint: Bool?
    /// 429 熔断开关：触发后暂停该类端点，避免越限越试
    var breakerEnabled: Bool?
    /// 熔断冷却秒数
    var cooldownSeconds: Int?

    // ── 媒体 CDN（下载）──
    /// CDN 限流时自动降低下载并发（默认开）
    var cdnThrottleEnabled: Bool?
    /// CDN 限流时允许的下载并发上限（默认 1，钳制 1–10）
    var cdnMaxConcurrent: Int?
    /// CDN 限流后的暂停秒数（默认 120，钳制 10–3600）
    var cdnCooldownSeconds: Int?

    init() {
        gateEnabled = true
        requestsPerWindow = 100
        windowSeconds = 10
        serializePerEndpoint = true
        breakerEnabled = true
        cooldownSeconds = 300
        cdnThrottleEnabled = true
        cdnMaxConcurrent = 1
        cdnCooldownSeconds = 120
    }
}

struct AppSettings: Codable, Sendable {
    var writeLogs: Bool = false
    var language: String = "zh-Hans"
    var preventSleepDuringDownload: Bool = true
    /// 界面字号（12–18），进可观察状态以即时生效
    var fontSize: Double?
    /// 退出/切换页面时自动清空下载历史记录（仅记录，不删文件）
    var autoClearDownloadHistory: Bool?
    /// 退出/切换页面时自动清空搜索历史
    var autoClearSearchHistory: Bool?
    /// 液态玻璃外观（macOS 26+；低版本强制关闭）
    var liquidGlass: Bool?
    /// 图片缓存总开关（分类开关在 ImageCache.Category）
    var cachingEnabled: Bool?
    /// 图片缓存上限 MB（最低 100；`Settings.unlimitedCacheLimitMB` = 无上限）
    var cacheLimitMB: Int?
    /// 缓存**超限回收目标**：占上限的百分比（默认 60，钳制 0–90）。
    ///
    /// 语义：占用**超过上限**时，从最旧的文件开始删，直到占用降到
    /// `上限 × 这个百分比` 为止。例：上限 1 GB、此项 60%，占用涨到 2 GB 时
    /// 会删到只剩 600 MB。留出这段余量，是为了让后续写入长时间不再触发清理
    /// （只降到刚好低于上限的话，缓存稍涨一点就要重新扫描全目录再清一次）。
    /// `0` = 超限后全部清空。
    var cacheReclaimTargetPercent: Int?
    /// 液态玻璃模糊强度（0–100，仅 macOS 26+ 有效）
    var glassBlur: Int?
    /// 限流缓解设置
    var rateLimit: RateLimitSettings?
    /// 翻译目标语言（BCP-47，空 = 跟随系统）
    var translateTargetLanguage: String?
    /// 自动翻译（仅翻译语言与目标语言不同的推文）
    var autoTranslate: Bool?
    /// 自动翻译的**语言白名单**（BCP-47 主语言码，如 "ja"、"ko"）。
    ///
    /// 语义：**只有检测到这些语言的推文才自动翻译**。
    /// 空数组 = 不自动翻译任何条目（比"全部语言都翻"更安全——
    /// 后者会让时间线里每条外语都触发翻译，既费电又刷屏）。
    ///
    /// 用数组而非 Set：`Codable` 序列化稳定、顺序对用户可见（清单按加入顺序展示）。
    var autoTranslateLanguages: [String]?
    /// 加快搜索页加载：设置时间范围后改用 X 的**搜索端点**（服务端按时间过滤），
    /// 而不是"拉时间线 + 本地剪裁"。默认 **开**（nil 视为开）。
    /// 关闭则回退到时间线方案（内有空窗期兜底，见 §14.3）。
    var fastSearchLoading: Bool?
    /// 主动状态检测（默认**开**，nil 视为开）：按间隔探测与 X 的连通性。
    var activeStatusProbe: Bool?
    /// 主动检测间隔秒数（默认 30，最低 5）
    var activeStatusProbeInterval: Int?
    /// 下载提示框（右下浮条）是否显示（默认**开**，nil 视为开）
    var showDownloadTip: Bool?
}

struct Settings: Codable, Sendable {
    /// 持久化设置的**模式版本**（顶层键，`decodeIfPresent` → 缺省 nil）。
    ///
    /// 用途只有一个：标记"本轮新默认值已经落过盘"，让 `SettingsStore` 能对老配置做
    /// **一次性覆盖**而不是每次启动都强行改写用户的选择。见 `currentSchemaVersion`。
    var settingsSchemaVersion: Int?
    var proxy: ProxySettings = ProxySettings()
    var download: DownloadSettings = DownloadSettings()
    var app: AppSettings = AppSettings()
    var sync: SyncSettings = SyncSettings()
    /// 同步判定依据（三值）
    var syncCheckModeValue: SyncCheckMode {
        get { SyncCheckMode(rawValue: sync.syncCheckMode ?? "") ?? .centralized }
        set { sync.syncCheckMode = newValue.rawValue }
    }

    static let currentVersion = 4

    /// 当前持久化模式版本。**改动下面这 4 个默认值时必须 +1**，否则老用户不会拿到新默认值。
    ///
    /// 版本 2（2026-10-02，用户拍板）把 4 个键的默认值定为：
    /// 1. 下载判定依据 → `centralized`
    /// 2. 同步判定依据 → `centralized`
    /// 3. 文件名追加唯一标识 → 打开（`appendUniqueId = true`）
    /// 4. 导入 / 导出 / 重建使用的形态 → `centralized`（`download.recordsForm`）
    ///
    /// **为什么默认集中式**：集中式把判定与「保存路径」解耦——用户此前正是因为保存路径
    /// 漂移导致整库判定失效（见 `MEDIA_RECORDS.md` §1.1）；集中式按账号分文件
    /// （`records/downloads/<user id>.json`），读取速度也可控（用户明确要求）。
    ///
    /// 老配置（标记缺失或 < 2）由 `SettingsStore` 把这 4 个键直接写成上述值并打标记；
    /// **旧值不做语义映射**（上一轮为 `recordFile` / `syncRecordFile` 写的映射已删除）——
    /// 旧设置的失联与被覆盖是预期结果。此后完全尊重用户的选择。
    static let currentSchemaVersion = 2

    /// 一次性覆盖：标记缺失或 < 2 时，把本轮拍板的 4 个键写成新默认值并打标记。
    ///
    /// **只碰这 4 个键**（外加版本标记本身），其余设置一个字节都不动——
    /// 返回 `false` 表示"无需覆盖"（已经打过标记），调用方据此决定要不要写回。
    ///
    /// 设计成纯函数（不读 UserDefaults、不碰单例）是为了能直接断言
    /// "老配置 → 4 键被覆盖 / 已打标记 → 用户值原样保留"这两条路径。
    mutating func applySchemaDefaultsOnce() -> Bool {
        guard (settingsSchemaVersion ?? 0) < Self.currentSchemaVersion else { return false }
        // 1) 下载判定依据 → 集中式
        download.sameFileCheckMode = SameFileCheckMode.centralized.rawValue
        // 2) 同步判定依据 → 集中式
        sync.syncCheckMode = SyncCheckMode.centralized.rawValue
        // 3) 文件名追加唯一标识 → 打开
        download.appendUniqueId = true
        // 4) 导入 / 导出 / 重建使用的形态 → 集中式
        download.recordsForm = RecordForm.centralized.rawValue
        settingsSchemaVersion = Self.currentSchemaVersion
        return true
    }

    /// 缓存上限取此值时表示**无上限**（不做容量控制）。
    ///
    /// 用 `0` 而不是 `Int.max`：越界判断、乘法都不会溢出，缺陷面最小。
    static let unlimitedCacheLimitMB = 0
    /// 缓存超限回收目标的钳制区间（设置界面、容量清理共用同一区间）
    static let cacheReclaimTargetRange = 0...90

    /// 有效的账号子目录开关（nil 安全）
    var accountSubfolderEnabled: Bool { download.accountSubfolder ?? true }
    /// 有效的媒体自动加载开关
    var autoLoadMediaEnabled: Bool { download.autoLoadMedia ?? true }
    /// 有效的隐私开关（默认关）
    var autoClearDownloadHistoryEnabled: Bool { app.autoClearDownloadHistory ?? false }
    var autoClearSearchHistoryEnabled: Bool { app.autoClearSearchHistory ?? false }
    /// 加快搜索页加载（默认**开**；nil = 开）
    var fastSearchLoadingEnabled: Bool { app.fastSearchLoading ?? true }
    /// 自动翻译的语言白名单（主语言码，小写）。空 = 不自动翻译任何条目。
    var autoTranslateLanguageList: [String] { app.autoTranslateLanguages ?? [] }
    /// 主动状态检测（默认**开**；nil = 开）
    var activeStatusProbeEnabled: Bool { app.activeStatusProbe ?? true }
    /// 主动检测间隔秒（默认 30，**最低 5**——更短会被 X 视为异常流量，反而加剧限流）
    var activeStatusProbeIntervalSeconds: Int { max(5, app.activeStatusProbeInterval ?? 30) }
    /// 下载提示框显示（默认**开**；nil = 开）
    var showDownloadTipEnabled: Bool { app.showDownloadTip ?? true }
    /// 下载引擎（默认 aria2）
    var engine: DownloadEngine { download.engine ?? .aria2 }
    /// 并发下载数（默认 5，1–20 钳制）
    var maxConcurrentDownloads: Int { min(20, max(1, download.maxConcurrent ?? 5)) }
    /// aria2Next 单文件最大连接数（1–256 钳制，默认 6）。
    /// 上限取自 aria2Next 手册对 `stream-max-connections` 的定义。
    var aria2Split: Int { min(256, max(1, download.aria2Split ?? 6)) }
    /// aria2 文件分配方式
    var aria2FileAllocation: String { download.aria2FileAllocation ?? "none" }
    /// 自动引擎模式的大小阈值 MB（默认 5，钳制 1–2048）
    var aria2SizeThresholdMB: Int { min(2048, max(1, download.aria2SizeThresholdMB ?? 5)) }
    /// aria2 RPC 端口（默认 6801，钳制 1024–65535）
    var aria2Port: Int { min(65535, max(1024, download.aria2Port ?? 6801)) }
    /// 端口策略
    var aria2PortMode: Aria2PortMode {
        get { Aria2PortMode(rawValue: download.aria2PortMode ?? "fixed") ?? .fixed }
        set { download.aria2PortMode = newValue.rawValue }
    }
    /// 液态玻璃开关（默认开；仅在 macOS 26+ 有效）
    var liquidGlassEnabled: Bool { app.liquidGlass ?? true }
    /// 下载判定依据（三值；默认**集中式**，见 `Settings.currentSchemaVersion`）
    var sameFileCheckModeValue: SameFileCheckMode {
        get { SameFileCheckMode(rawValue: download.sameFileCheckMode ?? "") ?? .centralized }
        set { download.sameFileCheckMode = newValue.rawValue }
    }

    /// 导入 / 导出 / 按文件名重建记录使用的形态（默认**集中式**）。
    ///
    /// **独立于判定依据**：三个入口读写哪份记录，由这个键显式决定，不再从下载判定推断
    /// （此前推断的后果：判定选「按文件名」时集中式记录既导不出也写不回）。
    var recordsFormValue: RecordForm {
        get { RecordForm(rawValue: download.recordsForm ?? "") ?? .centralized }
        set { download.recordsForm = newValue.rawValue }
    }

    /// 下载记录文件名（**仅分布式形态使用**）。
    ///
    /// 历史默认值 `.downloaded.json` 视为"未设置"（否则老用户会继续读写旧文件，
    /// 与契约「不读旧数据」冲突）；用户自定义过的名字原样保留。
    var recordFileNameValue: String {
        let raw = download.recordFileName ?? ""
        if raw.isEmpty || raw == DownloadSettings.legacyDefaultRecordFileName {
            return MediaRecords.defaultDownloadRecordName
        }
        return raw
    }

    /// 记录文件名的存储原值（设置页编辑用；默认写回新默认名）
    var recordFileNameRaw: String {
        get { recordFileNameValue }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            download.recordFileName = trimmed.isEmpty
                ? MediaRecords.defaultDownloadRecordName : trimmed
        }
    }

    /// 「文件名追加唯一标识」的用户开关（默认**打开**；nil 视为开）。
    var appendUniqueIdUserEnabled: Bool {
        get { download.appendUniqueId ?? true }
        set { download.appendUniqueId = newValue }
    }

    /// 「文件名追加唯一标识」的**有效值**（契约 §6.2 联动）。
    ///
    /// 下载判定或同步判定**任一**选「按文件名」→ 强制打开：
    /// 该模式下文件名就是判据，没有唯一标识必然出现"同推文多张媒体解析成同名 →
    /// 只认第一张"的误判。其余情况尊重用户开关。
    var appendUniqueIdEnabled: Bool {
        if sameFileCheckModeValue == .fileName || syncCheckModeValue == .fileName { return true }
        return appendUniqueIdUserEnabled
    }

    /// 开关是否被联动锁定（UI 不可改）
    var appendUniqueIdLocked: Bool {
        sameFileCheckModeValue == .fileName || syncCheckModeValue == .fileName
    }
    /// 图片缓存开关（默认开）
    var cachingEnabled: Bool { app.cachingEnabled ?? true }
    /// 缓存上限 MB（默认 200，**最低 100**；`unlimitedCacheLimitMB` = 无上限）
    var cacheLimitMB: Int {
        let raw = app.cacheLimitMB ?? 200
        return raw == Self.unlimitedCacheLimitMB ? raw : max(100, raw)
    }
    /// 缓存上限的字节数（`nil` = 无上限，不做容量控制）。
    ///
    /// **单位必须与 UI 显示一致**：设置项写的是 "200 MB"，用户用 `ByteCountFormatter`
    /// 的 `.file` 风格（**十进制**，1 MB = 1_000_000 字节）看实际占用。
    /// 曾用 `1_048_576`（MiB），于是"设 200MB 却显示 209.7MB"，用户以为上限没生效。
    var cacheLimitBytes: Int64? {
        let mb = cacheLimitMB
        guard mb != Self.unlimitedCacheLimitMB else { return nil }
        return Int64(mb) * 1_000_000
    }
    /// 缓存超限回收目标（占上限的**百分比**，默认 60，钳制 0–90）。
    ///
    /// 超限后从最旧的文件删到「上限 × 这个百分比」为止；`0` = 全部清空。
    var cacheReclaimTargetPercent: Int {
        let r = Self.cacheReclaimTargetRange
        return min(r.upperBound, max(r.lowerBound, app.cacheReclaimTargetPercent ?? 60))
    }
    /// 玻璃模糊强度（0–100，默认 60）
    var glassBlur: Int { min(100, max(20, app.glassBlur ?? 60)) }
    /// 打开应用自动同步（默认关）
    var autoSyncOnLaunchEnabled: Bool { sync.autoSyncOnLaunch ?? false }
    /// 同步完成无失败后自动退出（默认关）
    var quitOnSyncCompleteEnabled: Bool { sync.quitOnSyncComplete ?? false }
    /// 同步页布局（默认仿 Dock）
    var syncLayout: SyncLayoutMode {
        get { SyncLayoutMode(rawValue: sync.layout ?? "dock") ?? .dock }
        set { sync.layout = newValue.rawValue }
    }
    /// 有效字号
    var fontSizeValue: Double {
        get { app.fontSize ?? 14 }
        set { app.fontSize = min(18, max(12, newValue)) }
    }

    // MARK: - 限流缓解（nil 安全 + 范围钳制）

    /// 请求闸门开关（默认开）
    var gateEnabled: Bool { app.rateLimit?.gateEnabled ?? true }
    /// 时间窗内请求数上限（默认 100，钳制 1–600）。
    /// 默认值取宽松侧：X 的限流是"短期暴量"触发，靠闸门抹平并发尖峰即可，
    /// 过低的阈值反而会让正常浏览（翻页+头像+关注态查询）排队变慢。
    var gateRequestsPerWindow: Int { min(600, max(1, app.rateLimit?.requestsPerWindow ?? 100)) }
    /// 时间窗秒数（默认 10，钳制 1–300）
    var gateWindowSeconds: Int { min(300, max(1, app.rateLimit?.windowSeconds ?? 10)) }
    /// 同端点串行（默认开）
    var serializePerEndpoint: Bool { app.rateLimit?.serializePerEndpoint ?? true }
    /// 429 熔断开关（默认开）
    var breakerEnabled: Bool { app.rateLimit?.breakerEnabled ?? true }
    /// 熔断冷却秒数（默认 300 = 5 分钟，钳制 30–3600）
    var breakerCooldownSeconds: Int { min(3600, max(30, app.rateLimit?.cooldownSeconds ?? 300)) }

    // ── 媒体 CDN 限流缓解（与 GraphQL 独立）──

    /// CDN 限流时是否自动降并发（默认开）
    var cdnThrottleEnabled: Bool { app.rateLimit?.cdnThrottleEnabled ?? true }
    /// CDN 限流期间的下载并发上限（默认 1，钳制 1–10）
    var cdnMaxConcurrent: Int { min(10, max(1, app.rateLimit?.cdnMaxConcurrent ?? 1)) }
    /// CDN 限流后的暂停秒数（默认 120，钳制 10–3600）
    var cdnCooldownSeconds: Int { min(3600, max(10, app.rateLimit?.cdnCooldownSeconds ?? 120)) }

    // MARK: - 翻译（nil 安全）

    /// 目标语言：空/未设 = 跟随系统语言
    /// 翻译目标语言。
    ///
    /// 显式设置时用它；未设置（"跟随系统"）时取**系统偏好语言**，
    /// 见 `systemPreferredLanguage` 的说明——**不能**用 `Locale.current`。
    var translateTargetLanguage: Locale.Language {
        if let raw = app.translateTargetLanguage, !raw.isEmpty {
            return Locale.Language(identifier: raw)
        }
        return Self.systemPreferredLanguage
    }

    /// 系统**偏好**语言（用户真实意图）。
    ///
    /// ⚠️ **不要用 `Locale.current`**：它受 **app bundle 的本地化声明**影响。
    /// 本 app 只用 `L10n` 自己实现三语（不走 bundle），bundle 里只声明了 en，
    /// 于是系统把 `Locale.current` 降级成开发语言——**实测**：
    /// ```
    /// Locale.current.identifier  == "en_US"        ← 被降级成英语
    /// Locale.preferredLanguages  == ["zh-Hans"]    ← 用户真实语言
    /// Bundle.main.localizations  == ["en"]         ← 原因
    /// ```
    /// 用它当翻译目标会导致"设了跟随系统，却从日语翻到英语"（用户实测反馈）。
    ///
    /// `Locale.preferredLanguages` 读的是系统语言偏好列表，不受 bundle 影响。
    static var systemPreferredLanguage: Locale.Language {
        if let first = Locale.preferredLanguages.first, !first.isEmpty {
            return Locale.Language(identifier: first)
        }
        return Locale.current.language
    }

    /// 展示语言名用的 Locale。
    ///
    /// 与 `systemPreferredLanguage` 同理：`Locale.current` 被 bundle 降级成 en，
    /// 用它 `localizedString(forLanguageCode:)` 会把"日本語"显示成 "Japanese"。
    /// 这里用系统偏好语言构造，保证语言名与用户界面语言一致。
    static var displayLocale: Locale {
        Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    /// 目标语言的存储原值（设置页 Picker 绑定用，空字符串表示跟随系统）
    var translateTargetLanguageRaw: String {
        get { app.translateTargetLanguage ?? "" }
        set { app.translateTargetLanguage = newValue.isEmpty ? nil : newValue }
    }

    /// 自动翻译（默认关：默认开启会在每次浏览时都触发翻译，打扰且耗电）
    var autoTranslateEnabled: Bool { app.autoTranslate ?? false }

    /// 有效引擎（auto 时按阈值分流，见 DownloadStore.engineFor）
    var engineMode: DownloadEngine {
        get { download.engine ?? .aria2 }
        set { download.engine = newValue }
    }

    enum Language: String, CaseIterable, Identifiable {
        case zhHans = "zh-Hans"
        case zhHant = "zh-Hant"
        case en = "en"
        case system = "system"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .zhHans: return "简体中文"
            case .zhHant: return "繁體中文"
            case .en: return "English"
            case .system: return "跟随系统"
            }
        }
    }
}


/// 下载判定依据（契约 `MEDIA_RECORDS.md` §6.1）。
///
/// 三值：按文件名 / 记录文件·分布式 / 记录文件·集中式。
enum SameFileCheckMode: String, CaseIterable, Sendable {
    case fileName
    case distributed
    case centralized

    var displayName: String {
        switch self {
        case .fileName: return L("按文件名")
        case .distributed: return L("记录文件·分布式")
        case .centralized: return L("记录文件·集中式")
        }
    }
}

/// 同步判定依据（契约 §6.3；与下载判定相互独立）。
///
/// 三值：按文件名 / 记录文件·分布式 / 记录文件·集中式。
/// 「按文件名」直接复用下载的同一实现（`MediaJudgement`）。
enum SyncCheckMode: String, CaseIterable, Sendable {
    case fileName
    case distributed
    case centralized

    var displayName: String {
        switch self {
        case .fileName: return L("按文件名")
        case .distributed: return L("记录文件·分布式")
        case .centralized: return L("记录文件·集中式")
        }
    }
}
