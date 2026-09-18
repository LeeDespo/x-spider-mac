import Foundation
import SwiftUI

/// 翻译状态与协调器。
///
/// **为什么用系统翻译而不是抓 X 的翻译端点**：
/// 1. **不消耗 X API 配额** —— 项目一直在对抗 429，这是决定性的；
/// 2. 不需要获取并维护 X 私有的 queryId（会随官网改版失效）；
/// 3. 语言包下载后可离线翻译。
///
/// 交互模型：每个可翻译文本用「文本身份 key」登记译文与显示状态；
/// 视图按 key 读取，点击按钮在原文/译文间切换。
/// 标 `@MainActor`：状态供视图直接读取，改动都发生在主线程。
///
/// **注意**：`TranslationSession` 非 Sendable，因此**不能**把 session 传进本类的方法
/// （编译期报数据竞争）。翻译调用留在视图的 `translationTask` 闭包内，
/// 本类只接收"开始/结果/显示"三件事，且都经 `MainActor.run` 调用。
@MainActor
@Observable
final class TranslationStore {
    static let shared = TranslationStore()

    /// 译文缓存：key → 译文。key 用「推文 ID」即可（同一推文正文只翻一次）
    private(set) var translations: [String: String] = [:]
    /// 正在翻译的 key（用于按钮转圈）
    private(set) var translating: Set<String> = []
    /// 正在显示译文的 key；不在集合里 = 显示原文
    private(set) var showingTranslation: Set<String> = []
    /// 翻译失败原因：key → 文案
    private(set) var errors: [String: String] = [:]

    private init() {}

    // MARK: - 视图查询

    func translation(for key: String) -> String? { translations[key] }
    func isTranslating(_ key: String) -> Bool { translating.contains(key) }
    func isShowingTranslation(_ key: String) -> Bool { showingTranslation.contains(key) }
    func error(for key: String) -> String? { errors[key] }

    /// 某条内容当前应显示的文本（译文或原文）
    func displayText(for key: String, original: String) -> String {
        guard showingTranslation.contains(key), let t = translations[key] else { return original }
        return t
    }

    /// 是否应显示「翻译」按钮：已有译文（可来回切）或原文非空
    func canTranslate(_ key: String, text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 显示状态

    /// 切到译文
    func showTranslation(for key: String) {
        guard translations[key] != nil else { return }
        showingTranslation.insert(key)
    }

    /// 原文 ↔ 译文切换（已有译文时用，不触发翻译）
    func toggleDisplay(for key: String) {
        if showingTranslation.contains(key) {
            showingTranslation.remove(key)
        } else if translations[key] != nil {
            showingTranslation.insert(key)
        }
    }

    // MARK: - 执行
    //
    // `TranslationSession` **不是 Sendable**，不能作为参数跨 actor 传进本类
    // （会报 "sending 'session' risks causing data races"）。
    // 因此翻译调用留在视图侧的 `translationTask` 闭包内完成，
    // 本类只提供"开始/结束/结果"三个状态写入入口。

    /// 标记开始翻译（返回 false 表示已有译文或正在翻译，调用方可跳过）
    func beginTranslating(_ key: String) -> Bool {
        guard translations[key] == nil, !translating.contains(key) else { return false }
        translating.insert(key)
        return true
    }

    /// 写入翻译结果
    func finishTranslating(_ key: String, result: Result<String, Error>) {
        translating.remove(key)
        switch result {
        case .success(let text):
            translations[key] = text
            errors[key] = nil
        case .failure(let error):
            errors[key] = error.localizedDescription
            AppLogger.warn("翻译失败", category: "APP", ["key": key, "error": error.localizedDescription])
        }
    }

    // MARK: - 自动翻译

    /// 是否应对该条自动翻译。
    ///
    /// 判据（按用户决策：**只翻译检测到非目标语言的推文**）：
    /// 1. 设置里开启了自动翻译；
    /// 2. 推文**语言已知**（`lang != nil`）——未知时不猜，交给用户手点；
    /// 3. 语言 ≠ 目标语言（且不是目标语言的方言/同语种变体）。
    ///
    /// `lang` 来自 GraphQL 的 `legacy.lang`，**无需额外请求**。
    ///
    /// 标 `@MainActor`：需要读 `SettingsStore`（MainActor 隔离）。
    /// 视图在 `.onAppear`（主线程）调用，无额外成本。
    @MainActor
    static func shouldAutoTranslate(lang: String?) -> Bool {
        let settings = SettingsStore.shared.settings
        guard settings.autoTranslateEnabled else { return false }
        guard let lang, !lang.isEmpty else { return false }
        let target = settings.translateTargetLanguage
        return !isSameLanguage(lang, target)
    }

    /// 语言代码比对：X 给的是 BCP-47 短码（如 "ja"、"zh"、"en"），
    /// 目标是 `Locale.Language`。只比较主语言子标签，忽略地区变体
    /// （zh-Hans 与 zh 视为同语言）。
    static func isSameLanguage(_ a: String, _ b: Locale.Language) -> Bool {
        let mainA = a.split(separator: "-").first.map(String.init)?.lowercased() ?? a.lowercased()
        let mainB = (b.languageCode?.identifier ?? "").lowercased()
        return !mainA.isEmpty && mainA == mainB
    }

    /// 清空缓存（设置里换目标语言后必须调用：旧译文对应旧目标语言）
    func clearAll() {
        translations.removeAll()
        showingTranslation.removeAll()
        errors.removeAll()
    }
}
