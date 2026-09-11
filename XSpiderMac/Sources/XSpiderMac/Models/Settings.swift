import Foundation

struct ProxySettings: Codable, Sendable {
    var enable: Bool = true
    var url: String = "http://127.0.0.1:7890"
    var useSystem: Bool = true
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

    init() {
        accountSubfolder = true
        autoLoadMedia = true
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
    }
}

struct AppSettings: Codable, Sendable {
    var writeLogs: Bool = false
    var language: String = "zh-Hans"
    var preventSleepDuringDownload: Bool = true
    /// 界面字号（12–18），进可观察状态以即时生效
    var fontSize: Double?
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
