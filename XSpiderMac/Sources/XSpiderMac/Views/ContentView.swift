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
        .background(alignment: .topLeading) {
            // 内容区专用背景层（不垫在边栏下面，避免与边栏材质叠加导致更浑）：
            // NSGlassEffectView(sidebar 材质) 浮动面板，圆角+留边 → 有边缘才有折射
            SidebarStyleBackground(level: settingsStore.settings.glassBlur)
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .transparentWindowBackground()
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


