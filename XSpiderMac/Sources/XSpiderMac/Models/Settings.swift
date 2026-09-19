import Foundation

struct ProxySettings: Codable, Sendable {
    var enable: Bool = true
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
    var fileNameTemplate: String = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID% %EXT%"
    var sameFileSkip: Bool = true
    /// 跳过相同文件的判定依据：fileName / recordFile
    var sameFileCheckMode: String?
    /// 下载记录文件名（recordFile 模式下创建在每个用户文件夹里）
    var recordFileName: String?
    /// 按账号建子目录：昵称-@用户名（如 ~/Download/abc-@123）
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
        sameFileCheckMode = "fileName"
        recordFileName = ".downloaded.json"
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
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saveDirBase = try c.decodeIfPresent(String.self, forKey: .saveDirBase) ?? ""
        dirTemplate = try c.decodeIfPresent(String.self, forKey: .dirTemplate) ?? ""
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? "%POST_TIME% %USER_SCREEN_NAME% %POST_ID% %EXT%"
        sameFileSkip = try c.decodeIfPresent(Bool.self, forKey: .sameFileSkip) ?? true
        sameFileCheckMode = try c.decodeIfPresent(String.self, forKey: .sameFileCheckMode)
        recordFileName = try c.decodeIfPresent(String.self, forKey: .recordFileName)
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
}

struct SyncSettings: Codable, Sendable {
    /// 打开应用自动开始同步
    var autoSyncOnLaunch: Bool?
    /// 同步完成且无失败后自动退出应用
    var quitOnSyncComplete: Bool?
    /// 同步页布局：dock（仿 Dock）/ honeycomb（蜂窝）
    var layout: String?
    /// 同步判定依据：fileName / syncRecordFile（默认同步记录文件）
    var syncCheckMode: String?
    init() {
        autoSyncOnLaunch = false
        quitOnSyncComplete = false
        layout = "dock"
        syncCheckMode = "syncRecordFile"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoSyncOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoSyncOnLaunch) ?? false
        quitOnSyncComplete = try c.decodeIfPresent(Bool.self, forKey: .quitOnSyncComplete) ?? false
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? "dock"
        syncCheckMode = try c.decodeIfPresent(String.self, forKey: .syncCheckMode) ?? "syncRecordFile"
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
    /// 图片缓存上限 MB（50–500）
    var cacheLimitMB: Int?
    /// 液态玻璃模糊强度（0–100，仅 macOS 26+ 有效）
    var glassBlur: Int?
    /// 限流缓解设置
    var rateLimit: RateLimitSettings?
    /// 翻译目标语言（BCP-47，空 = 跟随系统）
    var translateTargetLanguage: String?
    /// 自动翻译（仅翻译语言与目标语言不同的推文）
    var autoTranslate: Bool?
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
    var proxy: ProxySettings = ProxySettings()
    var download: DownloadSettings = DownloadSettings()
    var app: AppSettings = AppSettings()
    var sync: SyncSettings = SyncSettings()
    /// 同步判定依据
    var syncCheckModeValue: SyncCheckMode {
        get { SyncCheckMode(rawValue: sync.syncCheckMode ?? "") ?? .syncRecordFile }
        set { sync.syncCheckMode = newValue.rawValue }
    }

    static let currentVersion = 3

    /// 有效的账号子目录开关（nil 安全）
    var accountSubfolderEnabled: Bool { download.accountSubfolder ?? true }
    /// 有效的媒体自动加载开关
    var autoLoadMediaEnabled: Bool { download.autoLoadMedia ?? true }
    /// 有效的隐私开关（默认关）
    var autoClearDownloadHistoryEnabled: Bool { app.autoClearDownloadHistory ?? false }
    var autoClearSearchHistoryEnabled: Bool { app.autoClearSearchHistory ?? false }
    /// 加快搜索页加载（默认**开**；nil = 开）
    var fastSearchLoadingEnabled: Bool { app.fastSearchLoading ?? true }
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
    /// 跳过相同文件判定依据（默认按文件名）
    var sameFileCheckModeValue: SameFileCheckMode {
        SameFileCheckMode(rawValue: download.sameFileCheckMode ?? "") ?? .fileName
    }
    /// 下载记录文件名（默认 .downloaded.json）
    var recordFileNameValue: String { download.recordFileName ?? ".downloaded.json" }
    /// 图片缓存开关（默认开）
    var cachingEnabled: Bool { app.cachingEnabled ?? true }
    /// 缓存上限 MB（默认 200，钳制 50–500）
    var cacheLimitMB: Int { min(500, max(50, app.cacheLimitMB ?? 200)) }
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
    var translateTargetLanguage: Locale.Language {
        if let raw = app.translateTargetLanguage, !raw.isEmpty {
            return Locale.Language(identifier: raw)
        }
        return Locale.current.language
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


/// 跳过相同文件的判定依据
enum SameFileCheckMode: String, CaseIterable, Sendable {
    case fileName
    case recordFile

    var displayName: String {
        switch self {
        case .fileName: return L("按文件名")
        case .recordFile: return L("按下载记录文件")
        }
    }
}

/// 同步判定依据（同步页跳过已下载媒体用；与下载判定相互独立）
enum SyncCheckMode: String, CaseIterable, Sendable {
    case fileName       // 与下载判定依据的"按文件名"一致
    case syncRecordFile // .synced.json：每用户最新媒体日期 + 当天全部媒体 ID(加速同步)

    var displayName: String {
        switch self {
        case .fileName: return L("按文件名")
        case .syncRecordFile: return L("按同步记录文件")
        }
    }
}
