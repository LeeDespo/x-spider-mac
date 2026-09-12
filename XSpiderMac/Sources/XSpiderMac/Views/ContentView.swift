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
            // 应用背景玻璃层：玻璃开启时用官方 glassEffect + blur 滑块调节；否则纯色
            if GlassCompat.supportsLiquidGlass && settingsStore.settings.liquidGlassEnabled {
                LiquidGlassBackground(blur: Double(settingsStore.settings.glassBlur) / 100)
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


/// 应用背景玻璃层（macOS 26+）：glassEffect 的容器 + blur 滑块映射的透明度
struct LiquidGlassBackground: View {
    var blur: Double

    var body: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect)
                .opacity(0.25 + blur * 0.5)
        } else {
            EmptyView()
        }
    }
}
