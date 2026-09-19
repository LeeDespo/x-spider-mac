import SwiftUI

/// 上游 Homepage.tsx + PostListGridView.tsx + DownloadController.tsx 的移植。
/// 关键修复：全部状态来自 HomepageStore（切换页面不丢失）。
struct HomeView: View {
    @State private var store = HomepageStore.shared
    @State private var appStore = AppStore.shared
    @State private var creationStore = CreationTaskStore.shared
    /// 选择性下载模式（媒体卡缩小变暗表示"后退",点击选中恢复）
    @State private var selectiveMode = false
    /// 媒体选择（勾选 = 要下载）。
    ///
    /// 用 `MediaSelection` 而非裸 `Set`：**全选必须是"全部"**，而"全部"里的
    /// 未加载部分只能靠爬虫补齐，所以全选态用**排除法**表示
    /// （见 `MediaSelection` 的文档）。用裸集合的话"全选"只能表示"已加载的那些"，
    /// 用户就不清楚自己到底选了什么——这正是本次要修的问题。
    @State private var selection = MediaSelection()

    /// 时间范围：改动先存 pending，点「确定」才提交并刷新（避免拖日期就连发请求）
    @State private var pendingDateStart: Date = Date(timeIntervalSince1970: 0)
    @State private var pendingDateEnd: Date = Date()
    @State private var hasPendingDateChange = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .animation(.spring(duration: 0.28), value: store.userInfo != nil || store.tweetSearchMode)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if !appStore.cookieString.isEmpty {
                if store.userInfoLoading {
                    loadingView
                } else if let user = store.userInfo {
                    userInfoCard(user)
                    filterBar
                    // 切换用户/数据源后同步 pending 时间范围（否则沿用上一个用户的值，
                    // 看起来「确定」按钮是启用的却提交了不相干的日期）
                    .onChange(of: store.filter.dateRange?.start) { _, v in
                        if let v { pendingDateStart = v; hasPendingDateChange = false }
                    }
                    .onChange(of: store.filter.dateRange?.end) { _, v in
                        if let v { pendingDateEnd = v; hasPendingDateChange = false }
                    }
                    // 「自动加载媒体」关闭时，只显示用户卡 + 下载配置 + 手动加载按钮
                    // （内容左上顶置布局，Spacer 占位，避免整页居中错乱）
                    if store.postList.isEmpty && !store.postListLoading && !SettingsStore.shared.settings.autoLoadMediaEnabled {
                        HStack {
                            Button {
                                Task { await store.loadMediaNow() }
                            } label: {
                                Label(L("加载媒体"), systemImage: "photo.stack")
                            }
                            .compatGlassButton()
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        Spacer()
                    } else {
                        postListGrid
                    }
                } else {
                    HomeTimelineView { screenName in
                        Task { await store.loadUser(screenName: screenName) }
                    }
                }
            } else {
                loginPrompt
            }
        }
        .navigationTitle(L("主页"))
        .onReceive(NotificationCenter.default.publisher(for: .homeSearchUser)) { note in
            if let sn = note.object as? String {
                Task { await store.loadUser(screenName: sn) }
            }
        }
        .frame(minWidth: 600)
        .overlay(alignment: .bottom) {
            if selectiveMode {
                // 选择模式操作条：撤销 / 全选 / 反选 / 全不选 / 下载所选
                HStack(spacing: 12) {
                    selectionCountText

                    Button(L("撤销")) {
                        selectiveMode = false
                        selection.reset()
                    }
                    .compatGlassButton()

                    Button(L("全选")) {
                        withAnimation(.easeOut(duration: 0.15)) { selection.selectAll() }
                    }
                    .compatGlassButton()
                    Button(L("反选")) {
                        withAnimation(.easeOut(duration: 0.15)) { selection.invert() }
                    }
                    .compatGlassButton()
                    Button(L("全不选")) {
                        withAnimation(.easeOut(duration: 0.15)) { selection.selectNone() }
                    }
                    .compatGlassButton()

                    // 「全选」+「下载所选」= 原来的「下载全部」（含未加载部分，走爬虫）
                    Button(L("下载所选")) { downloadSelected() }
                        .compatGlassProminentButton()
                        .disabled(isSelectionEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: selectiveMode)
        .onChange(of: store.filter.source) { _, _ in
            // 切换数据源自动退出选择模式(推文时间线不支持逐媒体选择)
            if selectiveMode {
                selectiveMode = false
                selection.reset()
            }
        }
    }

    /// 已选数量文案。
    ///
    /// 需求：**不知道总数时不要显示「已选 n/m」**。
    /// 列表还没加载完（服务端 cursor 非 nil）时分母未知，只显示「已选 n」；
    /// 到底了才显示完整的 `n/m`，那时 m 才是真实总数。
    @ViewBuilder
    private var selectionCountText: some View {
        let total = store.postListCursor == nil ? store.flatMediaList.count : nil
        if selection.isAllSelected {
            // 全选态：除排除项外全部。未加载完时总数含未加载部分，无法给出准确数字
            if let total {
                Text(L("已全选（共 %@）").replacingOccurrences(of: "%@", with: "\(total)"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("已全选"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let count = selection.selectedCount(knownTotal: total) {
            if let total {
                Text(L("已选 %@ / %@")
                    .replacingOccurrences(of: "%@", with: "\(count)")
                    .replacingOccurrences(of: "%@", with: "\(total)"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // 分母未知：不显示 n/m
                Text(L("已选 %@").replacingOccurrences(of: "%@", with: "\(count)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 是否一个都没选（下载所选按钮的禁用条件）
    private var isSelectionEmpty: Bool {
        selection.selectedCount(knownTotal: store.flatMediaList.count) == 0
    }

    /// 打开媒体查看窗口：切换范围 = 传入列表的全部媒体（网格/瀑布流已加载的部分）。
    /// `mediaId` 决定从哪一张开始看。
    private func openViewer(mediaId: String?,
                            in list: [(post: TwitterPost, media: TwitterMedia, index: Int)]) {
        let medias = list.map(\.media)
        guard !medias.isEmpty else { return }
        let start = medias.firstIndex { $0.id == mediaId } ?? 0
        let post = list.indices.contains(start) ? list[start].post : nil
        MediaViewerCenter.shared.open(medias: medias, index: start, post: post, origin: .userGrid)
    }

    /// 下载所选的媒体。
    ///
    /// **两种情形分开处理**（这是"全选即全部"的落地点）：
    ///
    /// 1. **全选态（`exclude`）**：语义是"除排除项外全部"，含**未加载部分**——
    ///    前端没有那些媒体，只能交给**爬虫**（`CreationTaskStore`）去翻页补齐，
    ///    并把排除项交给它跳过。若在这里只用已加载列表建任务，
    ///    全选就退化成了"全选已加载的"，正是要修的问题。
    /// 2. **逐项勾选态（`include`）**：用户明确点了几个，直接用眼前这些建任务
    ///    （零请求）。这些项可能还没加载出来（比如他先搜了再滚），所以仍走爬虫，
    ///    但爬虫会在收齐后就停（见 `remainingIncluded`）。
    private func downloadSelected() {
        guard let user = store.userInfo else { return }
        Task {
            // 两种情形都交给爬虫：唯一区别是爬虫拿到的选择集不同。
            // 这样"跳过已下载"的判定（DownloadStore.isDuplicate）两条路径完全一致。
            creationStore.createCreationTask(user: user, filter: store.filter, selection: selection)
            selectiveMode = false
            selection.reset()
        }
    }

    /// 搜索分流：推文链接/ID → 直接弹出推文详情卡（不切换页面）；否则按用户 screen_name
    private func submitSearch(keyword: String? = nil) {
        let text = (keyword ?? store.keyword).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let tweetID = HomepageStore.extractTweetID(from: text) {
            Task {
                if let post = await store.fetchTweet(tweetID: tweetID) {
                    // 统一走全窗浮层（与主页时间线/媒体网格同一路径，外观与关闭行为一致）
                    DetailOverlayCenter.shared.open(post, mediaIndex: 0)
                }
            }
        } else {
            loadUserPushingHistory(text)
        }
    }

    /// 搜索用户，并把"当前主页状态"记入导航历史。
    ///
    /// 这样用户在结果页点返回会回到上一个界面（主页时间线，或上一次的搜索结果），
    /// 而不是被困在搜索结果里——用户明确要求"点击返回也应该返回上一个界面"。
    private func loadUserPushingHistory(_ screenName: String) {
        NavigationHistory.shared.push(NavigationHistory.currentHomeEntry())
        Task { await store.loadUser(screenName: screenName) }
    }

    /// 搜索框左侧的返回箭头：优先回退导航历史（回到上一个搜索/主页状态），
    /// 历史为空时退回主页时间线。
    private func clearSearchPushingHistory() {
        if !NavigationHistory.shared.back() {
            store.clearSearch()
        }
    }

    // MARK: - 搜索栏（上游 Space.Compact：输入 + 搜索按钮 + 历史下拉）

    @State private var showSearchHistory = false
    @FocusState private var searchFieldFocused: Bool

    private var searchBar: some View {
        HStack(spacing: 8) {
            // 搜索态:返回时间线(替换放大镜图标,退出搜索后还原)
            if store.userInfo != nil || store.tweetSearchMode {
                Button {
                    clearSearchPushingHistory()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlass(interactive: true, cornerRadius: 13)
                .help(L("返回时间线"))
                .transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            TextField(L("输入用户 ID 或推文链接"), text: Binding(
                get: { store.keyword },
                set: { store.keyword = $0 }
            ))
            .focused($searchFieldFocused)
            .onSubmit { submitSearch() }
            // 输入框自身不画边框与焦点环：
            // 1) 原生焦点环由 AppKit 单独绘制，层级会**浮在**推文详情浮层之上
            //    （用户反馈"篮框会浮现推文详情上"），SwiftUI 的 zIndex 管不到它；
            // 2) 带上 roundedBorder 时，聚焦/失焦会切换背景色，表现为输入框"变色一闪一闪"。
            // 视觉容器交给外层已有的玻璃条，输入框只负责文字与光标。
            .textFieldStyle(.plain)
            .focusEffectDisabled()

            if !appStore.searchHistory.isEmpty {
                Button {
                    showSearchHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showSearchHistory, arrowEdge: .bottom) {
                    SearchHistoryPopover(appStore: appStore) { keyword in
                        showSearchHistory = false
                        store.keyword = keyword
                        submitSearch(keyword: keyword)
                    }
                }
            }

            Button { submitSearch() } label: {
                if store.userInfoLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L("搜索"))
                }
            }
            .compatGlassProminentButton()
            .disabled(store.keyword.trimmingCharacters(in: .whitespaces).isEmpty || store.userInfoLoading)
        }
        .padding(10)
        .liquidGlass(interactive: true, cornerRadius: 16)
        .onReceive(NotificationCenter.default.publisher(for: .homeFocusSearch)) { _ in
            searchFieldFocused = true
        }
        // 打开推文详情时主动交出焦点：即便有原生焦点环也先消失，不会留在浮层上方
        .onReceive(NotificationCenter.default.publisher(for: .homeResignSearchFocus)) { _ in
            searchFieldFocused = false
        }
    }

    // MARK: - 用户信息卡（上游 PageHeader 下方的用户行：头像+昵称+screen_name+媒体数+链接）

    private func userInfoCard(_ user: TwitterUser) -> some View {
        HStack(spacing: 12) {
            CachedAvatarView(urlString: user.avatar, size: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text("@\(user.screenName)")
                        .foregroundStyle(.secondary)
                    if let mediaCount = user.mediaCount {
                        Text("\(mediaCount) " + L("媒体"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            Spacer()

            if let registerTime = user.registerTime {
                Text(L("注册于") + " \(registerTime.formatted(.dateTime.year()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://x.com/\(user.screenName)")!) {
                Label(L("打开主页"), systemImage: "safari")
            }
            .compatGlassButton()
        }
        .padding(12)
        .liquidGlass(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 筛选栏（左：数据源分段 + 时间范围 + 确定；右：媒体类型 + 选择下载）

    /// 筛选栏取代了原先的「下载配置」卡片。
    ///
    /// 布局按需求：**左**为数据源分段控制器与时间范围（紧接账号卡片下方），
    /// **右**为媒体类型筛选与「选择下载」——后两者只在数据源 = 媒体时出现
    /// （推文时间线渲染推文卡，没有逐媒体勾选语义）。
    ///
    /// 时间范围不即时生效：改动只更新 pending 值，点「确定」才提交并刷新，
    /// 避免用户每拖一次日期就触发一次请求（RequestGate 与 429 都很敏感）。
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                // —— 左：数据源 + 时间范围 + 确定 ——
                Picker(L("数据源"), selection: Binding(
                    get: { store.filter.source },
                    set: { store.setFilter(store.filter.withSource($0)) }
                )) {
                    Text(L("推文")).tag(DownloadFilter.Source.tweets)
                    Text(L("媒体")).tag(DownloadFilter.Source.medias)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)

                DatePicker("", selection: Binding(
                    get: { pendingDateStart },
                    set: { pendingDateStart = $0; hasPendingDateChange = true }
                ), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Text("–").foregroundStyle(.secondary)
                DatePicker("", selection: Binding(
                    get: { pendingDateEnd },
                    set: { pendingDateEnd = $0; hasPendingDateChange = true }
                ), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)

                Button(L("确定")) { applyDateRange() }
                    .compatGlassButton()
                    .disabled(!hasPendingDateChange)
                    .help(L("按所选时间范围重新加载"))

                Spacer()

                // —— 右：媒体类型 + 选择下载（仅媒体数据源）——
                if store.filter.source == .medias {
                    ForEach([MediaType.photo, .video, .gif], id: \.self) { type in
                        Toggle(isOn: Binding(
                            get: { store.filter.mediaTypes?.contains(type) ?? false },
                            set: { store.setFilter(store.filter.togglingMediaType(type, on: $0)) }
                        )) {
                            Text(type.displayName)
                        }
                        .toggleStyle(.checkbox)
                    }

                    Button(L("选择下载")) {
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { selectiveMode = true }
                    }
                    .compatGlassButton()
                }
            }

            // 全量下载入口已移除：它由「选择下载 → 全选 → 下载所选」承担
            // （用户明确要求"全选"要表示全部，而不是"已加载的那些"）。
            // 爬虫仍为那条路径服务，见 CreationTaskStore。
            if let blocked = creationStore.creationBlockedReason {
                Text(blocked).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// 提交时间范围并刷新列表。
    /// 只改范围、立即重新加载首页数据（用户要求"点击确定后要根据时间范围刷新页面"）。
    private func applyDateRange() {
        store.setFilter(store.filter.withDateStart(pendingDateStart).withDateEnd(pendingDateEnd))
        hasPendingDateChange = false
        Task { await store.reloadWithCurrentFilter() }
    }

    /// 无限滚动底栏(媒体网格/推文列表共用)
    private var bottomLoader: some View {
        Group {
            if store.postListLoading {
                HStack { ProgressView().controlSize(.small); Text(L("加载中…")).font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity)
            } else if let error = store.postListError {
                // 失败后停在可见的重试入口;不再自动重触发(避免限流风暴)
                VStack(spacing: 6) {
                    Text(L("加载中断") + "：\(error)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L("重试")) {
                        store.retryFill()
                    }
                    .compatGlassButton()
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else if store.postListCursor != nil {
                // 哨兵：上报自身在滚动坐标系中的位置,由 store 按上游几何条件决定是否续拉。
                // 不用 .task(id:) —— 其 id 会随翻页自身变化而取消重启任务(曾导致每页自杀)。
                BottomSentinel(store: store)
                    .frame(height: 40)
            } else if !store.postList.isEmpty {
                Text(L("已加载全部"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(nil, value: store.postListLoading)
    }

    // MARK: - 媒体网格（上游 PostListGridView：LazyVGrid + hover 操作 + 无限滚动）

    private var postListGrid: some View {
        Group {
            if store.postList.isEmpty && !store.postListLoading {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(store.filter.source == .tweets ? L("该用户没有推文") : L("该用户没有媒体内容"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.filter.source == .tweets {
                // 推文时间线:推文卡列表(没有媒体的推文也显示),点击开详情
                ScrollReportingContainer(store: store) {
                    LazyVStack(spacing: 12) {
                        ForEach(store.postList) { post in
                            TimelinePostCard(post: post) {
                                DetailOverlayCenter.shared.open(post)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    bottomLoader
                    .padding(.bottom, 24)
                }
            } else {
                ScrollReportingContainer(store: store) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)], spacing: 12) {
                        ForEach(store.flatMediaList, id: \.media.id) { item in
                            MediaGridItem(post: item.post, media: item.media, index: item.index,
                                          selectionMode: selectiveMode,
                                          isSelected: selection.isSelected(MediaSelectionKey.make(post: item.post, media: item.media)),
                                          onToggleSelect: {
                                              withAnimation(.easeOut(duration: 0.12)) {
                                                  selection.toggle(MediaSelectionKey.make(post: item.post, media: item.media))
                                              }
                                          },
                                          onDoubleClick: {
                                              DetailOverlayCenter.shared.open(item.post, mediaIndex: item.index - 1)
                                          },
                                          onOpenViewer: {
                                              openViewer(mediaId: item.media.id, in: store.flatMediaList)
                                          })
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    bottomLoader
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - 状态视图

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(store.tweetSearchMode ? L("正在加载推文…") : L("正在加载用户…"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(store.lastError ?? L("输入用户 screen_name 开始浏览媒体"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loginPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(L("请先登录"))
                .font(.title2)
            Text(L("点击左侧账户卡导入 Cookie 后再搜索用户"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 滚动几何上报（复刻上游 InfiniteScroll 的 threshold 语义，macOS 14 兼容）

/// 滚动坐标空间名（文件级常量，避免引用泛型类型成员导致推断失败）
private let homeScrollSpace = "homeScroll"

/// 底部哨兵：把自身在滚动坐标系中的 maxY 上报给 store。
/// `maxY` 就是上游的 `scrollHeight - scrollTop`（视口顶 → 内容底的距离），
/// 滚动时它变小，降到两屏以内即触发补拉。
private struct BottomSentinel: View {
    let store: HomepageStore

    var body: some View {
        GeometryReader { geo in
            let anchor = geo.frame(in: .named(homeScrollSpace)).maxY
            Color.clear
                .onChange(of: anchor) { _, maxY in
                    store.reportBottomSentinel(y: maxY)
                }
                .onAppear {
                    store.reportBottomSentinel(y: anchor)
                }
        }
    }
}

/// 滚动容器：上报视口高度，并为哨兵提供命名坐标空间
private struct ScrollReportingContainer<Content: View>: View {
    let store: HomepageStore
    let content: () -> Content

    init(store: HomepageStore, @ViewBuilder content: @escaping () -> Content) {
        self.store = store
        self.content = content
    }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                content()
            }
            .coordinateSpace(name: homeScrollSpace)
            .onAppear { store.reportViewport(height: outer.size.height) }
            .onChange(of: outer.size.height) { _, h in store.reportViewport(height: h) }
        }
    }
}

// MARK: - 单个媒体格（上游 GridViewItemActions：hover 显示下载/打开推文按钮）

struct MediaGridItem: View {
    let post: TwitterPost
    let media: TwitterMedia
    let index: Int
    /// 选择性下载模式:true=卡片缩小变暗(后退感),点击=勾选(恢复正常大小)
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    /// 单击 → 推文详情弹窗（HomeView 层弹出;hover 按钮在上层不受影响）
    var onDoubleClick: (() -> Void)? = nil
    /// 点击放大镜 → 打开媒体查看窗口（切换范围为当前网格已加载的全部媒体）
    var onOpenViewer: (() -> Void)? = nil
    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            // 1:1 收纳框：底色仅在缩略图未加载时作为占位，加载后隐藏（避免可见方框）
            if thumbnail == nil {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.4))
            }

            if let thumbnail {
                GeometryReader { geo in
                    // 1:1 收纳框内 contain-fit：不裁切、不交错，长边对齐框、短边留白（框本身透明不可见）
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                Image(systemName: media.type == .photo ? "photo" : "video.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }

            // 视频时长角标（上游 dayjs 毫秒格式化）
            if media.type == .video || media.type == .gif {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if let duration = media.videoInfo?.duration {
                            Text(durationMsToClock(Int(duration)))
                                .font(.caption2)
                                .padding(4)
                                .background(.black.opacity(0.6))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .padding(6)
            }

            // hover 操作：下载/已下载 + 详细查看（共用于瀑布流，见 MediaCardActions）
            if isHovering {
                MediaCardActions(post: post, media: media) {
                    // 切换范围 = 当前列表（搜索用户网格里已加载的全部媒体）
                    onOpenViewer?()
                }
            }
        }
        .scaleEffect(selectionMode && !isSelected ? 0.86 : 1.0)
        .opacity(selectionMode && !isSelected ? 0.45 : 1.0)
        .task(id: media.id) {
            // 走 ImageCache 管线:后台下载+降采样解码,磁盘/内存双缓存,
            // LazyVGrid 视图重建滚回时命中缓存零开销(旧实现裸 URLSession + @State 随视图销毁丢失)
            guard thumbnail == nil, let urlString = thumbnailURL else { return }
            thumbnail = await ImageCache.shared.image(for: urlString, category: .mediaThumbnails, maxPixelSize: 600)
        }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: selectionMode)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: isSelected)
        .aspectRatio(4/5, contentMode: .fit)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if selectionMode { onToggleSelect?() }
            else { onDoubleClick?() }
        }
        .overlay(alignment: .topTrailing) {
            if selectionMode && isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green, .white)
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// 缩略图 URL：pbs.twimg.com 图片 URL 加 name=small（实际约 680px 宽）省流量；
    /// 降采样解码由 ImageCache 完成。视频封面路径不带 /media/，不加 query
    private var thumbnailURL: String? {
        guard let urlString = media.url, let url = URL(string: urlString) else { return nil }
        guard url.path.contains("/media/") else { return urlString }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return urlString }
        var items = comps.queryItems?.filter { $0.name != "name" } ?? []
        items.append(URLQueryItem(name: "name", value: "small"))
        comps.queryItems = items
        return comps.url?.absoluteString ?? urlString
    }

    private func durationMsToClock(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension TwitterPost: Identifiable {}

// MARK: - DownloadFilter 便捷操作

extension DownloadFilter {
    func withDateStart(_ date: Date) -> DownloadFilter {
        var copy = self
        let end = dateRange?.end ?? Date()
        copy.dateRange = DownloadFilter.DateRange(start: date, end: end)
        return copy
    }

    func withDateEnd(_ date: Date) -> DownloadFilter {
        var copy = self
        let start = dateRange?.start ?? Date(timeIntervalSince1970: 0)
        copy.dateRange = DownloadFilter.DateRange(start: start, end: date)
        return copy
    }

    func togglingMediaType(_ type: MediaType, on: Bool) -> DownloadFilter {
        var copy = self
        var types = copy.mediaTypes ?? []
        if on {
            if !types.contains(type) { types.append(type) }
        } else {
            types.removeAll { $0 == type }
        }
        copy.mediaTypes = types
        return copy
    }

    func withSource(_ source: Source) -> DownloadFilter {
        var copy = self
        copy.source = source
        return copy
    }
}

extension MediaType {
    var displayName: String {
        switch self {
        case .photo: return L("图片")
        case .video: return L("视频")
        case .gif: return "GIF"
        }
    }
}
