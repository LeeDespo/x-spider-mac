import SwiftUI
import AppKit

/// 把当前 NSWindow 配置为透明底（isOpaque=false + clear background + 透明 titlebar），
/// 让窗口内容层（玻璃/材质背景）直接决定整体透明度——拉到最低时窗口完全透明。
/// 挂在窗口内容根部，onAppear 时生效一次。
struct TransparentWindowConfig: ViewModifier {
    @State private var settingsStore = SettingsStore.shared

    func body(content: Content) -> some View {
        content.background(
            WindowAccessor { window in
                guard let window else { return }
                WindowConfigurator.apply(to: window)
                // 全屏时撤掉透明底/fullSizeContentView：否则系统在 titlebar 区域
                // 合成纯白底（全屏白顶栏 bug），并观察全屏切换实时响应
                let center = NotificationCenter.default
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification,
                                   object: window, queue: .main) { _ in
                    WindowConfigurator.exitImmersive(from: window)
                }
                center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                   object: window, queue: .main) { _ in
                    WindowConfigurator.apply(to: window)
                }
            }
        )
        .onChange(of: settingsStore.settings.glassBlur) { _, _ in
            // 滑块变化时确保窗口仍处于透明底状态（系统偶尔会重置）
            WindowAccessor.applyToKeyWindow { window in
                window.isOpaque = false
                window.backgroundColor = .clear
                window.titlebarAppearsTransparent = true
            }
        }
    }
}

/// 窗口配置工具：常规态(透明底+沉浸 titlebar)与全屏态(标准 titlebar)共用
enum WindowConfigurator {
    static func apply(to window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        // titlebar 融入内容：不再自带一层固定材质，随内容层（滑块）变化
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        // 内容延伸到 titlebar 区域，整窗统一材质
        window.styleMask.insert(.fullSizeContentView)
        window.appearance = nil
    }

    /// 全屏态：恢复不透明标准窗口（防全屏白顶栏）——退出全屏后 apply() 恢复沉浸外观
    static func exitImmersive(from window: NSWindow) {
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
    }
}

/// 拿到宿主 NSWindow
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            callback(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 对 key window 应用配置（供 onChange 等外部触发）
    static func applyToKeyWindow(_ apply: @escaping (NSWindow) -> Void) {
        DispatchQueue.main.async {
            if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
                apply(window)
            }
        }
    }
}

extension View {
    /// 窗口透明底配置（见 TransparentWindowConfig）
    func transparentWindowBackground() -> some View {
        modifier(TransparentWindowConfig())
    }
}
