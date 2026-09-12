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
            // 应用背景层：与边栏同一条渲染管线（NSGlassEffectView + sidebar 材质），
            // 滑块控制材质浓度（100 = 与边栏一致），两种玻璃模式统一
            SidebarStyleBackground(level: settingsStore.settings.glassBlur)
                .ignoresSafeArea()
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


