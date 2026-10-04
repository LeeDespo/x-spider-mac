import Foundation

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    var settings: Settings = Settings() {
        didSet {
            save()
            // 主动检测的开关/间隔变化要立即生效（不必重启）
            if oldValue.app.activeStatusProbe != settings.app.activeStatusProbe
                || oldValue.app.activeStatusProbeInterval != settings.app.activeStatusProbeInterval {
                AccountStatusStore.shared.restartActiveProbeIfNeeded()
            }
        }
    }

    /// 构造是否已经完成。
    ///
    /// `init` 里 `settings = decoded` 会触发 didSet → `save()`（`@Observable` 宏会把
    /// 属性观察器搬进 setter，实测 init 内赋值同样触发；不带宏的普通类则不会——
    /// 所以这条守卫不能靠"Swift 会在 init 里跳过 didSet"的直觉省掉）。
    /// 此时 `SettingsStore.shared` 还没构造完，触碰 `DownloadStore.shared` 会构成
    /// 单例构造重入（DownloadStore.init 读 SettingsStore.shared）→ SIGTRAP。
    /// 因此判定的自动失效**只在 isLoaded 之后生效**。
    private var isLoaded = false

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

    /// 从持久化字节载入设置：解码 → **一次性覆盖**（见 `Settings.currentSchemaVersion`）。
    ///
    /// 纯函数（不读 UserDefaults、不碰任何单例，`nonisolated` 因此可被测试直接调用），
    /// 可以整体在测试里跑：喂一段"磁盘上的旧配置"字节，断言 4 个键被覆盖成新默认值、
    /// 标记被写上；再喂一段"已打标记且用户选了别的值"的字节，断言用户值原样保留。
    ///
    /// 解码失败（文件损坏 / 形状对不上）→ 用全新默认值，同样走覆盖逻辑（打上标记）。
    /// 这里**不做旧值语义映射**（`recordFile` / `syncRecordFile` 不映射成任何东西）——
    /// 直接由覆盖顶掉，这是本轮用户拍板的预期结果。
    nonisolated static func load(from data: Data?) -> (settings: Settings, didOverride: Bool) {
        var settings = Settings()
        if let data, let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        }
        let didOverride = settings.applySchemaDefaultsOnce()
        return (settings, didOverride)
    }

    init() {
        // 一次性覆盖**发生在写回 UserDefaults 之前**：`settings = ...` 会触发
        // didSet → save()，在局部变量上覆盖再赋值，落盘的第一版就已经是新默认值，
        // 不存在"先写旧值再改"的窗口。
        let (loaded, didOverride) = Self.load(from: storage.data(forKey: key))
        settings = loaded
        if didOverride {
            AppLogger.info("设置已应用本轮新默认值（一次性覆盖）", category: "APP", [
                "schema": "\(Settings.currentSchemaVersion)",
                "sameFileCheckMode": loaded.sameFileCheckModeValue.rawValue,
                "syncCheckMode": loaded.syncCheckModeValue.rawValue,
                "appendUniqueId": loaded.appendUniqueIdUserEnabled ? "1" : "0",
                "recordsForm": loaded.recordsFormValue.rawValue,
            ])
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
        //
        // 判定的基线指纹在这里定死：init 期间 save() 不会（也不能）触碰 DownloadStore.shared，
        // 首次记录层加载由 DownloadStore 自己按需完成（`MediaRecords` 是懒加载的）。
        lastAppliedJudgementFingerprint = currentJudgementFingerprint()
        // 构造完成：此后的设置变更才允许走自动失效（见 `isLoaded` 的说明）
        isLoaded = true
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
        // 判定指纹自动失效：保存后比较指纹，变了就让「已下载」判定立即重算
        // （改判定依据 / 保存路径 / 账号子目录 / 唯一标识任何一项都会改变判定结果）。
        // 两条安全线：
        // 1. 构造期间（!isLoaded）一律不触碰 DownloadStore.shared —— 那会构成单例构造重入
        //    （DownloadStore.init 读 SettingsStore.shared）→ SIGTRAP；基线指纹在 init 末尾定好。
        // 2. 指纹幂等：设置页每次按键都会走 save()，值没变就不重复失效。
        if isLoaded { applyJudgementIfChanged() }
    }

    private func currentJudgementFingerprint() -> String {
        // 三值判定 + 保存路径 + 子目录开关 + 唯一标识开关都要参与：
        // 它们里的任何一个变化都会改变「已下载」判定结果。
        "\(settings.download.sameFileCheckMode ?? "")|\(settings.sync.syncCheckMode ?? "")"
            + "|\(settings.download.saveDirBase)|\(settings.download.accountSubfolder ?? true)"
            + "|\(settings.download.sameFileSkip)|\(settings.download.appendUniqueId.map(String.init) ?? "nil")"
    }

    /// 判定依据（或保存路径）变化 → 让"已下载"判定立即刷新。
    ///
    /// 判定结果由 `hasDownloaded` 即时算出、读的是 static 缓存与文件系统，
    /// 不参与 `@Observable` 依赖追踪；不主动通知的话，媒体卡上的
    /// 下载/已下载按钮状态会停在旧结果。
    ///
    /// **注意：不能在 init 里调用**。本方法会触碰 `DownloadStore.shared`，
    /// 而 `DownloadStore.init` 又要读 `SettingsStore.shared` —— 若在 init 中调用
    /// 就构成单例构造重入，实测直接 SIGTRAP 崩溃。
    /// 因此启动路径由各 store 自行完成首次刷新（DownloadStore.init 里已 loadRecordCaches），
    /// 这里只处理"后续变更"。
    private var lastAppliedJudgementFingerprint: String?
    private func applyJudgementIfChanged() {
        let fp = currentJudgementFingerprint()
        guard fp != lastAppliedJudgementFingerprint else { return }
        lastAppliedJudgementFingerprint = fp
        DownloadStore.shared.invalidateJudgements()
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
        // 限流参数现在推给组件（`net.set_limits`）；组件内部按配额域分桶治理，
        // 外壳只是把用户设的值传下去。
        Task { await TwitterAPI.shared.configure(cookie: AppStore.shared.cookieString, proxy: settings.proxy) }
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
