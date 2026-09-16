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

    var displayName: String {
        switch self {
        case .builtIn: return L("内置引擎")
        case .aria2: return "aria2Next"
        }
    }
}

struct DownloadSettings: Codable, Sendable {
    var saveDirBase: String = ""
    /// 已废弃（保留解码兼容），目录规则改用 accountSubfolder 开关
    var dirTemplate: String = ""
    var fileNameTemplate: String = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%"
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
    /// 单文件分块连接数（--split，1–16，默认 8）
    var aria2Split: Int?
    /// 最小分块大小 MB（--min-split-size，1–20，默认 1）
    var aria2MinSplitSize: Int?
    /// aria2 文件分配方式：none / prealloc / falloc
    var aria2FileAllocation: String?

    init() {
        sameFileCheckMode = "fileName"
        recordFileName = ".downloaded.json"
        accountSubfolder = true
        autoLoadMedia = true
        engine = .aria2
        maxConcurrent = 5
        aria2Split = 8
        aria2MinSplitSize = 1
        aria2FileAllocation = "none"
    }

    // 自定义解码：新字段缺失时用新默认值而不是整体 decode 失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saveDirBase = try c.decodeIfPresent(String.self, forKey: .saveDirBase) ?? ""
        dirTemplate = try c.decodeIfPresent(String.self, forKey: .dirTemplate) ?? ""
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%"
        sameFileSkip = try c.decodeIfPresent(Bool.self, forKey: .sameFileSkip) ?? true
        sameFileCheckMode = try c.decodeIfPresent(String.self, forKey: .sameFileCheckMode)
        recordFileName = try c.decodeIfPresent(String.self, forKey: .recordFileName)
        accountSubfolder = try c.decodeIfPresent(Bool.self, forKey: .accountSubfolder) ?? true
        autoLoadMedia = try c.decodeIfPresent(Bool.self, forKey: .autoLoadMedia) ?? true
        engine = try c.decodeIfPresent(DownloadEngine.self, forKey: .engine) ?? .aria2
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 5
        aria2Split = try c.decodeIfPresent(Int.self, forKey: .aria2Split) ?? 8
        aria2MinSplitSize = try c.decodeIfPresent(Int.self, forKey: .aria2MinSplitSize) ?? 1
        aria2FileAllocation = try c.decodeIfPresent(String.self, forKey: .aria2FileAllocation) ?? "none"
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
struct RateLimitSettings: Codable, Sendable {
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

    init() {
        gateEnabled = true
        requestsPerWindow = 100
        windowSeconds = 10
        serializePerEndpoint = true
        breakerEnabled = true
        cooldownSeconds = 300
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
    /// 下载引擎（默认 aria2）
    var engine: DownloadEngine { download.engine ?? .aria2 }
    /// 并发下载数（默认 5，1–20 钳制）
    var maxConcurrentDownloads: Int { min(20, max(1, download.maxConcurrent ?? 5)) }
    /// aria2 单文件连接数（1–16 钳制）
    var aria2Split: Int { min(16, max(1, download.aria2Split ?? 8)) }
    /// aria2 最小分块大小 MB（1–20）
    var aria2MinSplitSize: Int { min(20, max(1, download.aria2MinSplitSize ?? 1)) }
    /// aria2 文件分配方式
    var aria2FileAllocation: String { download.aria2FileAllocation ?? "none" }
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
