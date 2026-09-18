import SwiftUI
// 用 @preconcurrency 导入：`TranslationSession` 未标 Sendable，而它的
// `translate` 是 nonisolated 方法。在 Swift 6 严格并发下从主 actor 调用它，
// 编译器会判定 session 被送出隔离域而报错。这是**框架本身的标注缺口**，
// `@preconcurrency` 正是为这类尚未适配严格并发的系统框架提供的官方退路。
@preconcurrency import Translation

/// 可翻译正文：在原文/译文间切换，并提供「翻译 / 显示原文」按钮。
///
/// 采用系统 `Translation` 框架（macOS 15+），**不消耗 X API 配额**——理由见 `TranslationStore`。
///
/// ## 为什么把 translationTask 单独封成一个零尺寸子视图
///
/// `translationTask` 的闭包是 `@Sendable`，而 `TranslationSession` **不是 `Sendable`**。
/// 若承载它的 View 自身还有 `@State` / `@ViewBuilder` 闭包，Swift 6 的严格并发检查
/// 会把「闭包捕获了非 Sendable 的视图上下文」与「调用了非 Sendable 的 session」
/// 连起来判定，报 `sending 'session' risks causing data races`。
/// 把 translationTask 挪到一个**只持有 configuration/text/key 三个值**的子视图上，
/// 闭包不再捕获视图状态，检查即通过——这是该框架在 Swift 6 下的实用解法。
struct TranslatableText: View {
    /// 原文
    let text: String
    /// 翻译缓存键（推文 ID）
    let translationKey: String
    /// 该条语言（来自 `TwitterPost.lang`，可空）——自动翻译判据
    var lang: String?
    var font: Font = .callout
    /// 折叠行数（nil = 不折叠）
    var collapsedLines: Int?

    @State private var store = TranslationStore.shared
    @State private var request: TranslationSession.Configuration?

    var body: some View {
        let shown = store.displayText(for: translationKey, original: text)
        return VStack(alignment: .leading, spacing: 4) {
            if let collapsedLines {
                ExpandableText(text: shown, collapsedLines: collapsedLines, font: font)
            } else {
                Text(shown)
                    .font(font)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                control
                if let error = store.error(for: translationKey) {
                    Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .background {
            TranslationRunner(configuration: request, text: text, translationKey: translationKey)
        }
        .onAppear {
            // 自动翻译：仅当语言已知且 ≠ 目标语言（判据见 TranslationStore）
            if TranslationStore.shouldAutoTranslate(lang: lang),
               store.translation(for: translationKey) == nil {
                requestTranslation()
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if store.isTranslating(translationKey) {
            ProgressView().controlSize(.mini)
        } else if store.canTranslate(translationKey, text: text) {
            Button {
                if store.translation(for: translationKey) != nil {
                    store.toggleDisplay(for: translationKey)
                } else {
                    requestTranslation()
                }
            } label: {
                Text(store.isShowingTranslation(translationKey) ? L("显示原文") : L("翻译"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(L("使用系统翻译翻译这条内容（不消耗 X 配额）"))
        }
    }

    /// 触发会话：**必须新建 Configuration 实例**，复用同一实例不会让
    /// `translationTask` 重新执行。
    private func requestTranslation() {
        request = TranslationSession.Configuration(
            source: lang.map { Locale.Language(identifier: $0) },
            target: SettingsStore.shared.settings.translateTargetLanguage
        )
    }
}

/// 只做一件事：把 `translationTask` 挂在不含其他状态的视图上。
/// 拆出来的原因见 `TranslatableText` 的文档注释。
private struct TranslationRunner: View {
    let configuration: TranslationSession.Configuration?
    let text: String
    let translationKey: String

    var body: some View {
        // 先把需要跨闭包使用的值取成**纯局部常量**：闭包是 @Sendable，
        // 若在闭包内访问 self 的属性（哪怕只是 let 属性），会捕获整个 View 上下文，
        // 与同样位于作用域内的非 Sendable `session` 一起被判定为跨隔离域发送。
        let cfg = configuration
        let source = text
        let key = translationKey

        return Color.clear
            .frame(width: 0, height: 0)   // 纯逻辑载体，不参与布局
            .translationTask(cfg) { session in
                // 闭包内只使用 session 与上面的局部常量，不触碰 self
                let outcome = await Self.perform(session: session, text: source)
                await MainActor.run { Self.apply(outcome, key: key) }
            }
    }

    /// **不要**标 `nonisolated`：closure 本身运行在主 actor 上，
    /// 调用 nonisolated（即 @concurrent）方法会把主 actor 隔离的 `session`
    /// 送出去，编译期报 "sending 'session' risks causing data races"。
    /// 保持在主 actor 上调用，session 全程不跨隔离域。
    static func perform(session: TranslationSession,
                        text: String) async -> Result<String, Error> {
        do { return .success(try await session.translate(text).targetText) }
        catch { return .failure(error) }
    }

    static func apply(_ outcome: Result<String, Error>, key: String) {
        let store = TranslationStore.shared
        store.finishTranslating(key, result: outcome)
        if case .success = outcome { store.showTranslation(for: key) }
    }
}
