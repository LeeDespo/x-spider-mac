import SwiftUI

struct ContentView: View {
    @State private var selection: NavigationItem? = .home
    @State private var appStore = AppStore.shared

    @State private var settingsStore = SettingsStore.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            detailView(for: selection ?? .home)
                .background(.clear)
                .overlay(alignment: .bottomTrailing) {
                    FloatingDownloadBar()
                        .padding(20)
                }
        }
        .background {
            // 应用背景层：blur 滑块全模式统一控制。0 = 完全透明
            if GlassCompat.supportsLiquidGlass && settingsStore.settings.liquidGlassEnabled {
                LiquidGlassBackground(blur: Double(settingsStore.settings.glassBlur) / 100)
                    .ignoresSafeArea()
            } else {
                AdaptiveMaterialBackground(level: settingsStore.settings.glassBlur)
                    .ignoresSafeArea()
            }
        }
        .task {
            // 上游 App.tsx useMount：恢复会话（有 cookie 则静默重新验证）
            await appStore.restoreSession()
        }
        .onChange(of: selection) { oldItem, newItem in
            // 隐私开关：离开页面时自动清空对应历史（仅记录，不删文件）
            if oldItem != newItem {
                if oldItem == .home { appStore.clearSearchHistoryIfEnabled() }
                if oldItem == .downloads { DownloadStore.shared.clearHistoryIfEnabled() }
            }
        }
    }

    @ViewBuilder
    private func detailView(for item: NavigationItem) -> some View {
        switch item {
        case .home: HomeView()
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        case .about: AboutView()
        }
    }
}

#Preview {
    ContentView()
}


/// 应用背景玻璃层（macOS 26+）：glassEffect 容器 + blur 滑块映射的透明度（0 = 完全透明）
struct LiquidGlassBackground: View {
    var blur: Double

    var body: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect)
                .opacity(blur * 0.8)
        } else {
            EmptyView()
        }
    }
}

/// 材质背景（玻璃关闭/低版本系统）：滑块连续映射材质透明度，0 = 完全透明
struct AdaptiveMaterialBackground: View {
    /// 0–100
    var level: Int

    var body: some View {
        let t = Double(min(100, max(0, level))) / 100
        Rectangle()
            .fill(.clear)
            .background {
                // 材质本身不含透明度调节，用白色/黑色叠加近似"透明度"的视觉
                MaterialRect(t: t)
            }
            .opacity(t == 0 ? 0 : 0.35 + t * 0.65)
    }
}

private struct MaterialRect: View {
    var t: Double
    var body: some View {
        if t < 0.34 {
            Rectangle().fill(.ultraThinMaterial)
        } else if t < 0.67 {
            Rectangle().fill(.regularMaterial)
        } else {
            Rectangle().fill(.thickMaterial)
        }
    }
}
