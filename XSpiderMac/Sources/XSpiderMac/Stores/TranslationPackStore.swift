import Foundation
import SwiftUI
@preconcurrency import Translation

/// 翻译语言包的管理中心：查询支持/已安装状态、下载语言包、维护"自动翻译语言"清单。
///
/// ## 关于语言包会不会自动下载（用户问的）
///
/// **会**，但是"按需触发"：`translationTask` 的会话在首次 `translate()` 时若缺语言包，
/// 系统会弹窗提示并下载。这在浏览场景下体验不好——时间线里第一次遇到某种语言，
/// 要等系统下载完才能看到译文。
///
/// 所以本类做的事情是**把下载提前并且可管理**：
/// - `status(from:to:)` 查当前三态（已安装 / 可下载 / 不支持）；
/// - `download(from:to:)` 主动触发下载（走系统框架，**不消耗 X 配额**）；
/// - 用户在设置里维护"哪些语言需要自动翻译"，并可逐个预先下载。
///
/// ## 版本要求
///
/// `LanguageAvailability` 与 `TranslationSession.prepareTranslation()` 都是
/// **macOS 15.0+**，与本项目基线一致——**无需版本判断**。
@MainActor
@Observable
final class TranslationPackStore {
    static let shared = TranslationPackStore()

    /// 语言包状态（对应系统的 `LanguageAvailability.Status`，外加两个我们自己的态）
    enum PackStatus: Equatable, Sendable {
        /// 该语言就是翻译目标语言本身——不需要语言包
        case notNeeded
        case installed    // 已安装，可离线翻译
        case supported    // 系统支持但未安装（可下载）
        case unsupported  // 该语言对不支持
        case unknown      // 查询中 / 查询失败

        var isInstalled: Bool { self == .installed || self == .notNeeded }
        var canDownload: Bool { self == .supported }

        var label: String {
            switch self {
            case .notNeeded: return L("无需语言包")
            case .installed: return L("已下载")
            case .supported: return L("可下载")
            case .unsupported: return L("不支持")
            case .unknown: return L("检测中…")
            }
        }
    }

    /// 主语言码 → 该语言到目标语言的语言包状态
    private(set) var statuses: [String: PackStatus] = [:]
    /// 上次错误（供 UI 提示）
    private(set) var lastError: String?

    private let availability = LanguageAvailability()
    private init() {}

    // MARK: - 清单读写（持久化在 Settings）

    /// 当前"自动翻译语言"清单（主语言码）
    var languages: [String] {
        SettingsStore.shared.settings.autoTranslateLanguageList
    }

    /// 加入清单（已存在则忽略）
    func add(_ languageCodes: [String]) {
        var list = languages
        for code in languageCodes.map(Self.normalize) where !code.isEmpty && !list.contains(code) {
            list.append(code)
        }
        SettingsStore.shared.settings.app.autoTranslateLanguages = list
    }

    func remove(_ languageCode: String) {
        let code = Self.normalize(languageCode)
        SettingsStore.shared.settings.app.autoTranslateLanguages = languages.filter { $0 != code }
        statuses.removeValue(forKey: code)
    }

    // MARK: - 状态查询

    /// 查询某语言到当前目标语言的语言包状态。
    ///
    /// **源语言与目标语言相同时不走系统查询**：系统对"en → en"这种同语言对
    /// 返回 `unsupported`，但用户看到的语义应该是"不需要语言包"。
    /// 之前直接用系统结果，导致"目标语言恰好是英语时，英语显示不支持、
    /// 且已下载好的英语包也显示无法下载"（用户实测反馈）。
    ///
    /// - Parameter refresh: true 时忽略缓存重新查询（下载完成后要刷新）。
    func refreshStatus(for languageCode: String, force: Bool = false) async {
        let code = Self.normalize(languageCode)
        guard !code.isEmpty else { return }
        // 缓存有效即返回；但"正在下载"的语言必须绕过缓存——它的状态会变，
        // 不能让旧的"可下载"卡住 UI。
        if !force, statuses[code] != nil, !downloading.contains(code) { return }

        // 与目标语言相同 → 无需语言包（先于系统查询判断）
        let target = SettingsStore.shared.settings.translateTargetLanguage
        if TranslationStore.isSameLanguage(code, target) {
            statuses[code] = .notNeeded
            return
        }

        let source = Locale.Language(identifier: code)
        let status = await availability.status(from: source, to: target)
        statuses[code] = Self.map(status)
    }

    /// 刷新整个清单的状态
    func refreshAll() async {
        for code in languages {
            await refreshStatus(for: code, force: true)
        }
    }

    private static func map(_ s: LanguageAvailability.Status) -> PackStatus {
        switch s {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unknown
        }
    }

    // MARK: - 语言包下载
    //
    // **macOS 15 上 `TranslationSession` 没有公开 init**——它只能由 SwiftUI 的
    // `translationTask(configuration:)` 提供（`installedSource:` 那个 init 是 26.0+）。
    // 因此"主动下载语言包"必须由**视图**挂一个 `translationTask` 来交出 session，
    // 本类只负责记录"要下载哪些语言"并把结果写回状态。
    // 下载请求经 `pendingDownloads` 传给视图，见 `TranslationPackDownloader`。
    //
    // ## 关于"下载进度"（重要，别过度承诺）
    //
    // **系统不暴露任何下载进度 API**（`Translation.framework` 里没有 progress 相关成员，
    // 实测确认）。我们能知道的只有两件事：`prepareTranslation()` 返回了、
    // 以及**稍后状态是否变成 `.installed`**。
    //
    // 而且 `prepareTranslation()` 的返回**不代表下载完成**——它表示"已向系统提出请求"。
    // 之前把它当完成信号，于是下载刚发起就清掉"下载中"，UI 退回"可下载"，
    // 而系统其实还在后台下载（用户实测反馈："一直显示可下载，不显示正在下载"）。
    //
    // 现在的做法：请求发出后把该语言留在 `downloading` 集合里，
    // **轮询状态直到它变成 `.installed`**（或超时），UI 据此显示"下载中"。

    /// 等待下载的语言码（视图的 `translationTask` 消费后清空）
    private(set) var pendingDownloads: [String] = []
    /// 正在进行下载的语言码集合（UI 据此显示"下载中"）
    private(set) var downloading: Set<String> = []
    /// 状态轮询任务（有下载在飞时运行）
    private var pollTask: Task<Void, Never>?

    /// 单次下载的最长等待（超过则放弃并刷新一次状态，避免永久转圈）
    private let downloadTimeout: TimeInterval = 300

    /// 请求下载某语言的语言包（视图会接手执行）
    func requestDownload(languageCode: String) {
        let code = Self.normalize(languageCode)
        guard !code.isEmpty, !pendingDownloads.contains(code), !downloading.contains(code) else { return }
        pendingDownloads.append(code)
        // 立刻标记为"下载中"：从用户点下去那一刻起就该有反馈，
        // 不必等视图的 translationTask 真正跑起来
        downloading.insert(code)
        startPollingIfNeeded()
    }

    /// 视图取走待下载项
    func takeNextDownload() -> String? {
        guard !pendingDownloads.isEmpty else { return nil }
        return pendingDownloads.removeFirst()
    }

    /// 语言包的准备请求已由视图发出（`prepareTranslation()` 已返回）。
    ///
    /// **注意：这不等于下载完成**——只表示系统已接受请求，所以这里**不**清除
    /// `downloading`；真正的完成由状态轮询发现 `.installed` 后判定。
    func markDownloadRequested(languageCode: String, error: Error?) async {
        let code = Self.normalize(languageCode)
        if let error {
            lastError = error.localizedDescription
            downloading.remove(code)
            AppLogger.warn("翻译语言包下载失败", category: "APP", [
                "lang": code, "error": error.localizedDescription,
            ])
        } else {
            lastError = nil
            AppLogger.info("翻译语言包下载已请求（等待系统完成）", category: "APP", ["lang": code])
        }
        await refreshStatus(for: code, force: true)
    }

    /// 轮询：把状态刷成 `.installed` 后，才把语言从"下载中"移除。
    ///
    /// 没有进度可查（系统不暴露），所以只能轮询状态；间隔取 2s——
    /// 语言包通常是几十 MB，轮询开销可忽略。
    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(self?.downloadTimeout ?? 300)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if self.downloading.isEmpty { break }
                if Date() > deadline {
                    // 超时：不再转圈，刷新一次状态把真实结果呈现出来
                    AppLogger.warn("翻译语言包下载等待超时", category: "APP", [
                        "langs": self.downloading.joined(separator: ","),
                    ])
                    self.downloading.removeAll()
                    await self.refreshAll()
                    break
                }
                for code in self.downloading {
                    await self.refreshStatus(for: code, force: true)
                    // 状态变已安装 → 该语言下载完成，移出"下载中"
                    if self.statuses[code]?.isInstalled == true {
                        self.downloading.remove(code)
                    }
                }
            }
            self?.pollTask = nil
        }
    }

    /// 批量请求下载（"添加所选"后询问"是否立即下载"）
    func requestDownloadAll(_ languageCodes: [String]) {
        for code in languageCodes { requestDownload(languageCode: code) }
    }

    // MARK: - 全部支持的语言（供选择窗口）

    /// 系统支持的全部语言，按**当前界面语言**排序并给出本地化名称。
    ///
    /// `supportedLanguages` 是**异步属性**（macOS 15 起），因此这里是 async。
    /// 用系统给的权威清单，不自己维护常量表（自维护会随系统更新而过期）。
    func allSupportedLanguages() async -> [SupportedLanguage] {
        await availability.supportedLanguages
            .map { SupportedLanguage(language: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - 工具

    /// 归一化：X 给的是 BCP-47（"ja"、"zh-Hans"），清单里统一存**主语言码小写**
    /// （与 `TranslationStore.isSameLanguage` 的比对口径一致）。
    static func normalize(_ code: String) -> String {
        (code.split(separator: "-").first.map(String.init) ?? code).lowercased()
    }
}

/// 一个可选语言（用于选择窗口的列表）
struct SupportedLanguage: Identifiable, Hashable {
    let code: String
    let displayName: String
    var id: String { code }

    init(language: Locale.Language) {
        self.code = Self.normalize(language)
        // 用系统本地化的语言名（用户看得懂），拿不到就退回标识符
        if let main = language.languageCode?.identifier,
           let name = Settings.displayLocale.localizedString(forLanguageCode: main) {
            self.displayName = name
        } else {
            self.displayName = language.maximalIdentifier
        }
    }

    private static func normalize(_ l: Locale.Language) -> String {
        (l.languageCode?.identifier ?? l.minimalIdentifier).lowercased()
    }

    static func == (lhs: SupportedLanguage, rhs: SupportedLanguage) -> Bool { lhs.code == rhs.code }
    func hash(into hasher: inout Hasher) { hasher.combine(code) }
}
