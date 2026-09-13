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
                // 全屏与窗口化共用同一套沉浸样式（透明底 + fullSizeContentView），
                // 顶栏观感全屏内外一致；进入全屏后系统不再合成白色 titlebar 底
                let center = NotificationCenter.default
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                   object: window, queue: .main) { _ in
                    // 全屏后重新应用：系统切全屏时会重置样式
                    WindowConfigurator.apply(to: window)
                }
                center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                   object: window, queue: .main) { _ in
                    WindowConfigurator.apply(to: window)
                }
                // 亮暗模式切换：刷新 titlebar 合成,避免全屏/窗口化顶栏残留旧模式纯色
                center.addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                   object: nil, queue: .main) { _ in
                    WindowConfigurator.refreshTitlebars()
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

/// 窗口配置工具：常规态(透明底+沉浸 titlebar)与全屏态共用同一套沉浸样式
enum WindowConfigurator {
    static func apply(to window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        // titlebar 融入内容：不再自带一层固定材质，随内容层（滑块）变化
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        // 内容延伸到 titlebar 区域，整窗统一材质
        window.styleMask.insert(.fullSizeContentView)
        // appearance 跟随系统(nil)——亮暗切换时系统自动重算 titlebar 合成;
        // 另配合 AppleInterfaceTheme 变更通知强制刷新(见 TransparentWindowConfig)
        window.appearance = nil
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.titlebarAppearsTransparent = true
        }
    }

    /// 亮暗模式切换后刷新所有窗口的 titlebar 合成（黑条残留的根治）
    static func refreshTitlebars() {
        for window in NSApplication.shared.windows {
            guard window.styleMask.contains(.fullSizeContentView) else { continue }
            let visible = window.titleVisibility
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = visible
        }
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
