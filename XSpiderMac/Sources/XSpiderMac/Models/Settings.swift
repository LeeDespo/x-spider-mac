import Foundation

struct ProxySettings: Codable, Sendable {
    var enable: Bool = true
    var url: String = "http://127.0.0.1:7890"
    var useSystem: Bool = true
}

/// 下载引擎
enum DownloadEngine: String, Codable, CaseIterable, Sendable {
    case builtIn
    case aria2

    var displayName: String {
        switch self {
        case .builtIn: return L("内置引擎")
        case .aria2: return "aria2"
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
    init() { autoSyncOnLaunch = false }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoSyncOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoSyncOnLaunch) ?? false
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
}

struct Settings: Codable, Sendable {
    var proxy: ProxySettings = ProxySettings()
    var download: DownloadSettings = DownloadSettings()
    var app: AppSettings = AppSettings()
    var sync: SyncSettings = SyncSettings()

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
    /// 有效字号
    var fontSizeValue: Double {
        get { app.fontSize ?? 14 }
        set { app.fontSize = min(18, max(12, newValue)) }
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
