import SwiftUI

/// 上游 Homepage.tsx + PostListGridView.tsx + DownloadController.tsx 的移植。
/// 关键修复：全部状态来自 HomepageStore（切换页面不丢失）。
struct HomeView: View {
    @State private var autoLoadAttempted = false
    @State private var store = HomepageStore.shared
    // cursor 变化（成功翻页）后允许下一次自动加载
    private var cursorKey: String { store.postListCursor ?? "" }
    @State private var appStore = AppStore.shared
    @State private var downloadStore = DownloadStore.shared
    @State private var creationStore = CreationTaskStore.shared
    @State private var creationTaskCreated = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if !appStore.cookieString.isEmpty {
                if store.tweetSearchMode {
                    tweetResultView
                } else if store.userInfoLoading {
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
                    emptyState
                }
            } else {
                loginPrompt
            }
        }
        .navigationTitle(L("主页"))
        .frame(minWidth: 600)
    }

    /// 搜索分流：推文链接/ID → 推文模式；否则按用户 screen_name
    private func submitSearch(keyword: String? = nil) {
        let text = (keyword ?? store.keyword).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let tweetID = HomepageStore.extractTweetID(from: text) {
            Task { await store.loadTweet(tweetID: tweetID) }
        } else {
            Task { await store.loadUser(screenName: text) }
        }
    }

    /// 推文搜索结果（独立布局：单卡网格，无用户信息卡/下载配置）
    private var tweetResultView: some View {
        VStack(spacing: 0) {
            if store.postListLoading {
                loadingView
            } else if let post = store.postList.first {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)], spacing: 12) {
                        ForEach(Array((post.medias ?? []).enumerated()), id: \.element.id) { idx, media in
                            MediaGridItem(post: post, media: media, index: idx + 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            } else {
                emptyState
            }
        }
    }

    // MARK: - 搜索栏（上游 Space.Compact：输入 + 搜索按钮 + 历史下拉）

    @State private var showSearchHistory = false
    @FocusState private var searchFieldFocused: Bool

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
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
                    Button(L("开始下载")) {
                        if let user = store.userInfo {
                            creationStore.createCreationTask(user: user, filter: store.filter)
                        }
                        withAnimation(.spring(duration: 0.3, bounce: 0.25)) { creationTaskCreated = true }
                    }
                    .compatGlassProminentButton()
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
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
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 媒体网格（上游 PostListGridView：LazyVGrid + hover 操作 + 无限滚动）

    private var postListGrid: some View {
        Group {
            if store.postList.isEmpty && !store.postListLoading {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(L("该用户没有媒体内容"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)], spacing: 12) {
                        ForEach(store.flatMediaList, id: \.media.id) { item in
                            MediaGridItem(post: item.post, media: item.media, index: item.index)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // 无限滚动：固定高度的底部区，避免 loading↔按钮切换时视图抖动闪烁
                    HStack {
                        if store.postListLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else if store.postListCursor != nil, !autoLoadAttempted {
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    autoLoadAttempted = true
                                    Task { await store.loadMorePostList() }
                                }
                        } else if !store.postList.isEmpty {
                            Text(L("已加载全部"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)  // 固定高度：分支切换不改变布局
                    .animation(nil, value: store.postListLoading)  // 分支切换不做动画，消除闪烁
                    .onChange(of: cursorKey) { _, _ in autoLoadAttempted = false }
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

// MARK: - 单个媒体格（上游 GridViewItemActions：hover 显示下载/打开推文按钮）

struct MediaGridItem: View {
    let post: TwitterPost
    let media: TwitterMedia
    let index: Int
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
                    .task { await loadThumbnail() }
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
        .aspectRatio(4/5, contentMode: .fit)
        .onHover { isHovering = $0 }
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

    private func loadThumbnail() async {
        guard let urlString = media.url, let url = URL(string: urlString) else {
            AppLogger.debug("媒体缺缩略图 URL", category: "HOME", ["mediaId": media.id ?? "?", "type": media.type.rawValue])
            return
        }
        // 缩略图优先：pbs.twimg.com 图片 URL 加 name=small（约 120px 宽）省流量；
        // 网格展示用缩略图，下载时才取 name=orig 原图。视频封面路径不带 /media/，不加 query
        var smallURL = url
        if url.path.contains("/media/") {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var items = comps.queryItems?.filter { $0.name != "name" } ?? []
            items.append(URLQueryItem(name: "name", value: "small"))
            comps.queryItems = items
            if let u = comps.url { smallURL = u }
        }
        do {
            let (data, resp) = try await URLSession.shared.data(from: smallURL)
            if let img = NSImage(data: data) {
                thumbnail = img
            } else {
                AppLogger.debug("缩略图解码失败", category: "HOME", [
                    "mediaId": media.id ?? "?",
                    "bytes": "\(data.count)",
                    "status": "\((resp as? HTTPURLResponse)?.statusCode ?? 0)",
                ])
            }
        } catch {
            AppLogger.warn("缩略图加载失败", category: "HOME", [
                "mediaId": media.id ?? "?", "url": smallURL.path, "error": error.localizedDescription,
            ])
        }
    }

    private func durationMsToClock(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

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
