import SwiftUI

struct ContentView: View {
    @State private var selection: NavigationItem? = .home
    @State private var appStore = AppStore.shared
    @State private var showCookieSheet = false
    @State private var showFeatureIntro = false

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
            // 同步页隐藏浮条（动画淡出,不移除视图——离开同步页后满足条件即动画回来）
            FloatingDownloadBar()
                .opacity(selection == .sync ? 0 : 1)
                .allowsHitTesting(selection != .sync)
                .animation(.spring(duration: 0.35), value: selection == .sync)
                .padding(20)
        }
        .animation(.spring(duration: 0.35), value: selection)
        .overlay {
            // 推文详情全窗浮层:盖住边栏+内容;点击任何非卡区退出;ESC 返回
            if let post = DetailOverlayCenter.shared.post {
                MediaDetailView(
                    post: post,
                    initialMediaIndex: DetailOverlayCenter.shared.initialMediaIndex,
                    onSearchUser: { sn in
                        DetailOverlayCenter.shared.searchUser(sn)
                    },
                    onBack: { DetailOverlayCenter.shared.back() }
                )
                // 按推文 ID 重建身份：**必须**。
                // 浮层内可以换推文（点引用推文、返回上一条），若不加 .id，
                // SwiftUI 会复用同一个视图实例 → `@State`（detail/replies/liked/mediaIndex）
                // 全部保留上一条推文的值，`.task` 也不会重跑 ——
                // 表现为"跳到引用推文后，评论和媒体还是原来那条的"。
                .id(post.id)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(200)
            }
        }
        .animation(.easeOut(duration: 0.18), value: DetailOverlayCenter.shared.post != nil)
        .onChange(of: DetailOverlayCenter.shared.post?.id) { _, newValue in
            // 详情浮层出现即让搜索框交出焦点：原生焦点环会盖在浮层之上，
            // 且输入框聚焦态会持续闪色（见 HomeView.searchBar 的注释）
            if newValue != nil {
                NotificationCenter.default.post(name: .homeResignSearchFocus, object: nil)
            }
        }
        .onAppear {
            DetailOverlayCenter.shared.onSearchUser = { sn in
                selection = .home
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    NotificationCenter.default.post(name: .homeSearchUser, object: sn)
                }
            }
            // 返回导航的重放：历史层不依赖视图，动作在这里注入
            NavigationHistory.shared.replay = { entry in
                switch entry {
                case .detail(let postId):
                    // 还原到该推文详情：从详情缓存取，**零请求**。
                    // 缓存未命中（超过容量被淘汰）则忽略，停在当前界面。
                    selection = .home
                    _ = DetailOverlayCenter.shared.restore(id: postId)
                case .home(let state):
                    // 还原主页状态：有快照走快照（零请求、列表原样），
                    // 无快照（原先是主页时间线）则清空搜索态回到时间线。
                    // 同时收起详情浮层——这条记录代表"回到主页"，
                    // 不收的话用户会停在浮层里，以为返回没生效。
                    // 用 dismissOverlay（不截断历史）：这条记录已由 back() 弹出，
                    // 再截断会把更早的返回记录一起丢掉。
                    DetailOverlayCenter.shared.dismissOverlay()
                    selection = .home
                    if let state {
                        HomepageStore.shared.restoreSearchState(state)
                    } else {
                        HomepageStore.shared.clearSearch()
                    }
                }
            }
        }
        .background {
            // 全出血铺满整窗（含滚动条轨道与底缘）：不留缝隙，避免露出透明窗口底。
            // 折射由玻璃层在全窗口表面呈现；滑块只调材质浓度
            SidebarStyleBackground(level: settingsStore.settings.glassBlur)
                .ignoresSafeArea()
        }
        .transparentWindowBackground()
        .sheet(isPresented: $showCookieSheet) {
            CookieLoginSheet()
        }
        .sheet(isPresented: $showFeatureIntro) {
            FeatureIntroSheet()
        }
        .onAppear {
            // 首次打开应用 → 功能介绍
            if !UserDefaults.standard.bool(forKey: "app.welcomeShown") {
                showFeatureIntro = true
                UserDefaults.standard.set(true, forKey: "app.welcomeShown")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFeatureIntro)) { _ in
            showFeatureIntro = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAboutTab)) { _ in
            selection = .about
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
    /// 主页搜索框**交出焦点**（打开推文详情前广播）：
    /// 原生焦点环由 AppKit 单独绘制，会浮在详情浮层之上，必须先让它消失
    static let homeResignSearchFocus = Notification.Name("home.resignSearchFocus")
    /// 详情卡头像点击 → 主页搜索该用户(payload: screenName)
    static let homeSearchUser = Notification.Name("home.searchUser")
}

#Preview {
    ContentView()
}


