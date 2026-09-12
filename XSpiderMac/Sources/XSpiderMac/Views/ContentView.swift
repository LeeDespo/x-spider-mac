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
            // 全出血铺满整窗（含滚动条轨道与底缘）：不留缝隙，避免露出透明窗口底。
            // 折射由玻璃层在全窗口表面呈现；滑块只调材质浓度
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


