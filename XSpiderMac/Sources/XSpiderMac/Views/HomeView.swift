import SwiftUI

/// 上游 Homepage.tsx + PostListGridView.tsx + DownloadController.tsx 的移植。
/// 关键修复：全部状态来自 HomepageStore（切换页面不丢失）。
struct HomeView: View {
    @State private var store = HomepageStore.shared
    @State private var appStore = AppStore.shared
    @State private var downloadStore = DownloadStore.shared
    @State private var creationStore = CreationTaskStore.shared
    @State private var creationTaskCreated = false
    /// 双击媒体 → 推文详情弹窗
    @State private var detailPost: TwitterPost?
    @State private var detailMediaIndex = 0
    /// 选择性下载模式（媒体卡缩小变暗表示"后退",点击选中恢复）
    @State private var selectiveMode = false
    /// 已勾选待下载的媒体 (post.id, media.id)
    @State private var selectedMediaKeys: Set<String> = []

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
                    downloadController
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
        .sheet(item: $detailPost) { post in
            MediaDetailView(post: post, initialMediaIndex: detailMediaIndex) { screenName in
                detailPost = nil
                Task { await store.loadUser(screenName: screenName) }
            }
        }
        .overlay(alignment: .bottom) {
            if selectiveMode {
                // 选择模式操作条:撤销 + 全部下载(短条居中)
                HStack(spacing: 14) {
                    Button(L("撤销")) {
                        selectiveMode = false
                        selectedMediaKeys = []
                    }
                    .compatGlassButton()
                    Button(L("全部下载")) { downloadSelected() }
                        .compatGlassProminentButton()
                        .disabled(selectedMediaKeys.isEmpty)
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
                selectedMediaKeys.removeAll()
            }
        }
    }

    /// 选择模式键
    private func selectionKey(_ post: TwitterPost, _ media: TwitterMedia) -> String {
        post.id + "/" + (media.id ?? media.url ?? UUID().uuidString)
    }

    /// 下载勾选的媒体
    private func downloadSelected() {
        let items = store.flatMediaList.filter { selectedMediaKeys.contains(selectionKey($0.post, $0.media)) }
        Task {
            for item in items {
                _ = await downloadStore.createDownloadTask(post: item.post, media: item.media)
            }
            selectiveMode = false
            selectedMediaKeys = []
        }
    }

    /// 搜索分流：推文链接/ID → 直接弹出推文详情卡（不切换页面）；否则按用户 screen_name
    private func submitSearch(keyword: String? = nil) {
        let text = (keyword ?? store.keyword).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let tweetID = HomepageStore.extractTweetID(from: text) {
            Task {
                if let post = await store.fetchTweet(tweetID: tweetID) {
                    detailMediaIndex = 0
                    detailPost = post
                }
            }
        } else {
            Task { await store.loadUser(screenName: text) }
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
                    store.clearSearch()
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

    // MARK: - 下载配置（上游 DownloadController：日期范围 + 媒体类型 + 数据源 + 开始下载）

    private var downloadController: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("下载配置"))
                .font(.headline)

            HStack(spacing: 16) {
                // 日期范围（上游 DatePicker.RangePicker）
                DatePicker(
                    L("从"),
                    selection: Binding(
                        get: { store.filter.dateRange?.start ?? Date(timeIntervalSince1970: 0) },
                        set: { store.setFilter(store.filter.withDateStart($0)) }
                    ),
                    displayedComponents: .date
                )
                DatePicker(
                    L("至"),
                    selection: Binding(
                        get: { store.filter.dateRange?.end ?? Date() },
                        set: { store.setFilter(store.filter.withDateEnd($0)) }
                    ),
                    displayedComponents: .date
                )

                Spacer()

                // 两段式：创建后变绿色「已创建」，再点恢复，再点才再次创建（防重复触发）
                if creationTaskCreated {
                    Button {
                        withAnimation(.spring(duration: 0.3, bounce: 0.25)) { creationTaskCreated = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(L("已创建任务"))
                        }
                    }
                    .foregroundStyle(.green)
                    .compatGlassProminentButton()
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else {
                    Button(L("下载全部")) {
                        if let user = store.userInfo {
                            creationStore.createCreationTask(user: user, filter: store.filter)
                            // 仅在真的入队时打勾(重复创建被拒则不打勾)
                            if creationStore.creationBlockedReason == nil {
                                withAnimation(.spring(duration: 0.3, bounce: 0.25)) { creationTaskCreated = true }
                            }
                        }
                    }
                    .compatGlassProminentButton()
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                if let blocked = creationStore.creationBlockedReason {
                    Text(blocked)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                }

                // 选择下载:仅媒体时间线数据源可用(推文时间线渲染推文卡,无逐媒体勾选语义)
                Button(L("选择下载")) {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) { selectiveMode = true }
                }
                .compatGlassButton()
                .disabled(store.filter.source != .medias)
                .opacity(store.filter.source != .medias ? 0.4 : 1)
            }

            HStack(spacing: 16) {
                // 媒体类型（上游 Checkbox ×3）
                ForEach([MediaType.photo, .video, .gif], id: \.self) { type in
                    Toggle(isOn: Binding(
                        get: { store.filter.mediaTypes?.contains(type) ?? false },
                        set: { store.setFilter(store.filter.togglingMediaType(type, on: $0)) }
                    )) {
                        Text(type.displayName)
                    }
                    .toggleStyle(.checkbox)
                }

                Spacer()

                // 数据源（上游 Radio：medias / tweets）
                Picker(L("数据源"), selection: Binding(
                    get: { store.filter.source },
                    set: { store.setFilter(store.filter.withSource($0)) }
                )) {
                    Text(L("媒体时间线")).tag(DownloadFilter.Source.medias)
                    Text(L("推文时间线")).tag(DownloadFilter.Source.tweets)
                }
                .pickerStyle(.radioGroup)
                .infoHint(L("媒体时间线：加载快，直达媒体内容。\n推文时间线：可检索到更久远的媒体，翻页更慢。"))
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
                                detailPost = post
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
                                          isSelected: selectedMediaKeys.contains(selectionKey(item.post, item.media)),
                                          onToggleSelect: {
                                              let k = selectionKey(item.post, item.media)
                                              if selectedMediaKeys.contains(k) { selectedMediaKeys.remove(k) }
                                              else { selectedMediaKeys.insert(k) }
                                          },
                                          onDoubleClick: {
                                              detailPost = item.post
                                              detailMediaIndex = item.index - 1
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

            // hover 操作：无遮罩，中央一排圆形图标按钮（已下载勾 / 下载 / 打开推文）
            if isHovering {
                HStack(spacing: 10) {
                    if DownloadStore.shared.hasDownloaded(media: media, dir: DownloadStore.shared.targetDir(for: post)) {
                        iconBadge("checkmark", color: .green, help: L("该媒体已下载过"))
                    } else {
                        roundIconButton("arrow.down", help: L("下载")) {
                            Task { await DownloadStore.shared.createDownloadTask(post: post, media: media) }
                        }
                    }
                    if let url = URL(string: "https://x.com/\(post.user.screenName)/status/\(post.id)") {
                        roundIconButton("link", help: L("打开推文")) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
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

    /// 圆形玻璃图标按钮（36pt）
    @ViewBuilder
    private func roundIconButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.45), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 已下载徽标（绿色圆 + 白勾，不可点）
    private func iconBadge(_ system: String, color: Color, help: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.85), in: Circle())
            .overlay {
                Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1)
            }
            .help(help)
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
