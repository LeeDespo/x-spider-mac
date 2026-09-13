import SwiftUI

struct ContentView: View {
    @State private var selection: NavigationItem? = .home
    @State private var appStore = AppStore.shared
    @State private var showCookieSheet = false

    @State private var settingsStore = SettingsStore.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            // 切页过渡：Cubic 回弹位移（系统设置页风格）——旧页缩小淡出，新页从 4% 缩放回弹淡入
            ZStack {
                detailView(for: selection ?? .home)
                    .id(selection)
            }
            .background(.clear)
            .animation(.spring(duration: 0.32, bounce: 0.18), value: selection)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.96, anchor: .center)
                    .combined(with: .opacity)
                    .animation(.spring(duration: 0.32, bounce: 0.18)),
                removal: .scale(scale: 0.98, anchor: .center)
                    .combined(with: .opacity)
                    .animation(.easeOut(duration: 0.14))
            ))
        }
        .overlay(alignment: .bottomTrailing) {
            // 浮条挂在 NavigationSplitView 层级：切页时 detail 内容重建，
            // 但浮条身份保持稳定，不会每次切页都重播出现动画
            // 同步页隐藏浮条（带动画）：蜂窝页面保持纯净
            if selection != .sync {
                FloatingDownloadBar()
                    .padding(20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.35), value: selection)
        .background {
            // 全出血铺满整窗（含滚动条轨道与底缘）：不留缝隙，避免露出透明窗口底。
            // 折射由玻璃层在全窗口表面呈现；滑块只调材质浓度
            SidebarStyleBackground(level: settingsStore.settings.glassBlur)
                .ignoresSafeArea()
        }
        .transparentWindowBackground()
        .sheet(isPresented: $showCookieSheet) {
            CookieImportView(isPresented: $showCookieSheet)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDownloadsTab)) { _ in
            selection = .downloads
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            selection = .home
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: .homeFocusSearch, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCookieImport)) { _ in
            showCookieSheet = true
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
        case .sync: SyncView()
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        case .about: AboutView()
        }
    }
}

extension Notification.Name {
    /// 主页搜索框聚焦（菜单「搜索用户或推文」）
    static let homeFocusSearch = Notification.Name("menu.homeFocusSearch")
}

#Preview {
    ContentView()
}


