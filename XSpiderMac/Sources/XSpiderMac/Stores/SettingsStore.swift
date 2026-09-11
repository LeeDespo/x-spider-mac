import Foundation

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    var settings: Settings = Settings() {
        didSet { save() }
    }

    /// UI 字体大小（12–18pt，默认 14）
    var fontSize: Double {
        get { UserDefaults.standard.object(forKey: "app.fontSize") as? Double ?? 14 }
        set {
            UserDefaults.standard.set(newValue, forKey: "app.fontSize")
            applyLanguage()
        }
    }

    private let storage = UserDefaults.standard
    private let key = "settings.v2"

    init() {
        if let data = storage.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        }
        AppLogger.fileLoggingEnabled = settings.app.writeLogs
        SleepPreventer.shared.enabled = settings.app.preventSleepDuringDownload
        applyLanguage()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            storage.set(data, forKey: key)
        }
        AppLogger.fileLoggingEnabled = settings.app.writeLogs
        SleepPreventer.shared.enabled = settings.app.preventSleepDuringDownload
        applyLanguage()
    }

    /// 应用语言（UserDefaults AppleLanguages + 立即生效需要重启视图层）
    private func applyLanguage() {
        let raw = settings.app.language
        let code = raw == "system" ? nil : raw
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    var language: Settings.Language {
        get { Settings.Language(rawValue: settings.app.language) ?? .zhHans }
        set { settings.app.language = newValue.rawValue }
    }
}
