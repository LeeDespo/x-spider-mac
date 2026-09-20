import SwiftUI
@preconcurrency import Translation

/// 语言包下载的执行器。
///
/// ## 为什么需要一个"看不见的视图"
///
/// **macOS 15 上 `TranslationSession` 没有公开初始化器**——它只能由 SwiftUI 的
/// `translationTask(configuration:)` 交出（`installedSource:` 那个 init 是 macOS 26+）。
/// 所以"主动下载语言包"只能在视图层做：本视图消费 `pendingDownloads`，
/// 每次为一种语言起一个 configuration，由 `translationTask` 拿到 session 后调
/// `prepareTranslation()`。
///
/// 这与 `TranslatableText` 里的 `TranslationRunner` 是同一套思路，
/// 也遵循同样的 Swift 6 并发约束（见该文件的注释）：
/// 闭包是 `@Sendable`，而 `TranslationSession` 不是 `Sendable`，
/// 因此把值先取成纯局部常量、不捕获视图上下文。
struct TranslationPackDownloader: View {
    @State private var store = TranslationPackStore.shared
    @State private var request: TranslationSession.Configuration?
    @State private var inFlight: String?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background {
                TranslationPackRunner(configuration: request, languageCode: inFlight ?? "")
            }
            .task {
                // 顺序处理待下载队列：一次一种语言，避免系统同时弹多个下载确认
                while !Task.isCancelled {
                    guard let code = store.takeNextDownload() else {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        continue
                    }
                    await run(code)
                }
            }
    }

    private func run(_ code: String) async {
        inFlight = code
        let target = SettingsStore.shared.settings.translateTargetLanguage
        // 必须**新建** Configuration 实例，复用同一实例不会让 translationTask 重新执行
        request = TranslationSession.Configuration(
            source: Locale.Language(identifier: code),
            target: target
        )
        // 等 runner 回调（它会在 prepareTranslation 返回/抛错后调 markDownloadRequested）。
        // 这里只做一个较短的兜底等待——真正的"下载完成"由 store 轮询状态判定，
        // 因为 prepareTranslation 返回 ≠ 下载完成（见 TranslationPackStore 注释）。
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        if inFlight == code { inFlight = nil }
    }
}

/// 只做一件事：把 `translationTask` 挂在不含其它状态的视图上（理由见上方注释）
private struct TranslationPackRunner: View {
    let configuration: TranslationSession.Configuration?
    let languageCode: String

    var body: some View {
        let cfg = configuration
        let code = languageCode
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(cfg) { session in
                guard !code.isEmpty else { return }
                var caught: Error?
                do {
                    // prepareTranslation 会让系统去准备（下载）该语言对的语言包。
                    // ⚠️ 它的返回**不代表下载完成**，只表示系统已接受请求；
                    // 因此这里只上报"已请求"，完成与否由 store 轮询状态判定。
                    try await session.prepareTranslation()
                } catch {
                    caught = error
                }
                await TranslationPackStore.shared.markDownloadRequested(languageCode: code,
                                                                       error: caught)
            }
    }
}
