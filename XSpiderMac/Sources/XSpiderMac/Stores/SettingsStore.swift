import Foundation

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    var settings: Settings = Settings() {
        didSet { save() }
    }

    /// 需要重启才能完全生效的修改提示（设置页弹窗）
    var pendingRestartNotice: String?

    /// UI 字号（进 settings 持久化；12–18）
    var fontSize: Double {
        get { settings.fontSizeValue }
        set {
            settings.fontSizeValue = newValue
            restartNoticePendingFonts = true
        }
    }

    /// 字号修改后是否需要重启提示（视图层读取后清除）
    var restartNoticePendingFonts = false

    private let storage = UserDefaults.standard
    private let key = "settings.v2"

    init() {
        if let data = storage.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        }
        // 迁移：旧版字号存 UserDefaults，搬进 settings
        if settings.app.fontSize == nil,
           let legacy = UserDefaults.standard.object(forKey: "app.fontSize") as? Double {
            settings.fontSizeValue = legacy
        }
        // 默认保存路径：~/Downloads（仅当从未设置过）
        if settings.download.saveDirBase.isEmpty {
            if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                settings.download.saveDirBase = downloads.path
            }
        }
        AppLogger.fileLoggingEnabled = settings.app.writeLogs
        SleepPreventer.shared.enabled = settings.app.preventSleepDuringDownload
        applyLanguage()
    }

    private var savedSettings: Settings?

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            storage.set(data, forKey: key)
        }
        AppLogger.fileLoggingEnabled = settings.app.writeLogs
        SleepPreventer.shared.enabled = settings.app.preventSleepDuringDownload
        applyLanguage()
    }

    /// 应用语言（应用内字符串表即时生效 + UserDefaults AppleLanguages 供系统级组件）
    private func applyLanguage() {
        let raw = settings.app.language
        let lang = Settings.Language(rawValue: raw) ?? .zhHans
        // 应用内字符串表（即时生效）
        L10n.language = lang
        // 系统级（WebView/格式化等），重启后生效
        if raw != "system" {
            UserDefaults.standard.set([raw], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    var language: Settings.Language {
        get { Settings.Language(rawValue: settings.app.language) ?? .zhHans }
        set { settings.app.language = newValue.rawValue }
    }
}
