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
    /// 按账号建子目录：昵称-@用户名（如 ~/Download/abc-@123）
    var accountSubfolder: Bool?
    /// 主页搜索后是否自动加载媒体时间线（关闭省流量，只显示用户卡与下载配置）
    var autoLoadMedia: Bool?
    /// 下载引擎：aria2 / 内置 URLSession
    var engine: DownloadEngine?
    /// 同时并发下载文件数（1–20，默认 5）
    var maxConcurrent: Int?

    init() {
        accountSubfolder = true
        autoLoadMedia = true
        engine = .aria2
        maxConcurrent = 5
    }

    // 自定义解码：新字段缺失时用新默认值而不是整体 decode 失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saveDirBase = try c.decodeIfPresent(String.self, forKey: .saveDirBase) ?? ""
        dirTemplate = try c.decodeIfPresent(String.self, forKey: .dirTemplate) ?? ""
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%"
        sameFileSkip = try c.decodeIfPresent(Bool.self, forKey: .sameFileSkip) ?? true
        accountSubfolder = try c.decodeIfPresent(Bool.self, forKey: .accountSubfolder) ?? true
        autoLoadMedia = try c.decodeIfPresent(Bool.self, forKey: .autoLoadMedia) ?? true
        engine = try c.decodeIfPresent(DownloadEngine.self, forKey: .engine) ?? .aria2
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 5
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
}

struct Settings: Codable, Sendable {
    var proxy: ProxySettings = ProxySettings()
    var download: DownloadSettings = DownloadSettings()
    var app: AppSettings = AppSettings()

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
