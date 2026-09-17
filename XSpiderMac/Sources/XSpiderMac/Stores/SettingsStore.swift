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
        // 限流缓解设置必须非 nil——视图绑定写的是 `settings.app.rateLimit?.x = $0`，
        // 可选链对 nil 是静默 no-op（表现为"点击有反馈但值不变"）。老配置与全新安装都在此补默认值。
        if settings.app.rateLimit == nil {
            settings.app.rateLimit = RateLimitSettings()
        }
        migrateRateLimitDefaultsOnce()
        AppLogger.fileLoggingEnabled = settings.app.writeLogs
        SleepPreventer.shared.enabled = settings.app.preventSleepDuringDownload
        applyLanguage()
        applyRateLimit()
        // 启动时不在这里 configure：SettingsStore 是第一个构造的 store，
        // 其 init 内触碰 AppStore 会形成构造重入。
        // 启动路径已由 AppStore.cookieString.didSet（restoreSession → login 内的赋值）覆盖。
    }

    /// 一次性迁移：早期默认值过于保守（每窗口 10 请求 / 熔断暂停 900 秒），
    /// 会让正常浏览排队明显变慢。只替换**恰好等于旧默认值**的项（用户自己调过的值不动），
    /// 且只执行一次——否则用户以后主动调回 10 又会被再次顶掉。
    private func migrateRateLimitDefaultsOnce() {
        let flagKey = "settings.rateLimitDefaultsMigrated.v2"
        guard !storage.bool(forKey: flagKey) else { return }
        storage.set(true, forKey: flagKey)

        if settings.app.rateLimit?.requestsPerWindow == 10 {
            settings.app.rateLimit?.requestsPerWindow = 100
        }
        if settings.app.rateLimit?.cooldownSeconds == 900 {
            settings.app.rateLimit?.cooldownSeconds = 300
        }
    }

    private var savedSettings: Settings?

    /// 模板等连续输入时每次按键都会触发 save——JSON 全量编码+写盘造成卡顿。
    /// 写盘防抖 300ms 合并；语言/日志等旁路立即生效。
    private var saveDebounceTask: Task<Void, Never>?
    private func save() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [settings] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(settings) {
                self.storage.set(data, forKey: self.key)
            }
        }
        AppLogger.fileLoggingEnabled = settings.app.writeLogs
        SleepPreventer.shared.enabled = settings.app.preventSleepDuringDownload
        applyLanguage()
        applyRateLimit()
        applyProxyIfChanged()
    }

    /// 代理设置变更 → 重建网络客户端（**无需重启**）。
    ///
    /// 此前 `TwitterAPI.configure` 只由 `AppStore.cookieString.didSet` 触发，
    /// 在设置里改代理地址/开关**完全不会**影响已运行的 URLSession ——
    /// 表现为"代理换了却还在走旧配置""重设代理也没用，除非重启应用"。
    ///
    /// 用指纹做幂等：设置页每次键入都会走 save()，不能每次都重建连接池。
    private var lastAppliedProxyFingerprint: String?
    private func applyProxyIfChanged() {
        let p = settings.proxy
        let fingerprint = "\(p.enable)|\(p.useSystem)|\(p.url)|\(p.username ?? "")|\(p.password ?? "")"
        guard fingerprint != lastAppliedProxyFingerprint else { return }
        lastAppliedProxyFingerprint = fingerprint
        // 先取 cookie（避免在 Task 内首次触发 AppStore 构造，与自身初始化形成重入）
        let cookie = AppStore.shared.cookieString
        Task { [settings] in
            await TwitterAPI.shared.configure(cookie: cookie, proxy: settings.proxy)
            AppLogger.info("代理设置已应用,网络客户端已重建", category: "NET", [
                "enable": settings.proxy.enable ? "1" : "0",
                "useSystem": settings.proxy.useSystem ? "1" : "0",
                "url": settings.proxy.url,
            ])
        }
    }

    /// 限流缓解设置 → 请求闸门（设置改动即时生效）
    private func applyRateLimit() {
        Task { await NetworkClient.syncGateConfig(settings) }
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
