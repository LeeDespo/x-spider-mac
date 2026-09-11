import SwiftUI

/// 上游 Homepage.tsx + PostListGridView.tsx + DownloadController.tsx 的移植。
/// 关键修复：全部状态来自 HomepageStore（切换页面不丢失）。
struct HomeView: View {
    @State private var store = HomepageStore.shared
    @State private var appStore = AppStore.shared
    @State private var downloadStore = DownloadStore.shared
    @State private var creationStore = CreationTaskStore.shared

    var body: some View {
        VStack(spacing: 0) {
            searchBar
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
                            .buttonStyle(.glass)
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

    // MARK: - 搜索栏（上游 Space.Compact：输入 + 搜索按钮 + 历史下拉）

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("请输入用户 ID，如：shiratamacaron"), text: Binding(
                get: { store.keyword },
                set: { store.keyword = $0 }
            ))
            .onSubmit {
                Task { await store.loadUser(screenName: store.keyword) }
            }

            if !appStore.searchHistory.isEmpty {
                Menu {
                    ForEach(appStore.searchHistory, id: \.self) { history in
                        Button(history) {
                            Task { await store.loadUser(screenName: history) }
                        }
                    }
                    Divider()
                    Button(L("清空历史"), role: .destructive) {
                        appStore.clearSearchHistory()
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }

            Button {
                Task { await store.loadUser(screenName: store.keyword) }
            } label: {
                if store.userInfoLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L("搜索"))
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(store.keyword.trimmingCharacters(in: .whitespaces).isEmpty || store.userInfoLoading)
        }
        .padding(10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }

    // MARK: - 用户信息卡（上游 PageHeader 下方的用户行：头像+昵称+screen_name+媒体数+链接）

    private func userInfoCard(_ user: TwitterUser) -> some View {
        HStack(spacing: 12) {
            AccountAvatarView(urlString: user.avatar, size: 48)

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
            .buttonStyle(.glass)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
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

                Button(L("开始下载")) {
                    if let user = store.userInfo {
                        creationStore.createCreationTask(user: user, filter: store.filter)
                    }
                }
                .buttonStyle(.glassProminent)
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
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
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

                    // 无限滚动：滚动到底自动加载下一页（上游 InfiniteScroll 组件）
                    HStack {
                        if store.postListLoading {
                            ProgressView(L("加载中…"))
                        } else if store.postListCursor != nil {
                            Button(L("加载更多")) {
                                Task { await store.loadMorePostList() }
                            }
                            .buttonStyle(.glass)
                            .onAppear {
                                Task { await store.loadMorePostList() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
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
            Text(L("正在加载用户…"))
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
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .aspectRatio(media.type == .photo ? nil : 16/9, contentMode: .fit)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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

            // hover 操作（上游 GridViewItemActions：下载 + 打开推文）
            if isHovering {
                VStack(spacing: 8) {
                    // 已下载过同一媒体 → 禁用态「已下载」，不可重复下载
                    if DownloadStore.shared.hasDownloaded(media: media) {
                        Label(L("已下载"), systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.secondary)
                            .opacity(0.85)
                    } else {
                        Button {
                            Task { await DownloadStore.shared.createDownloadTask(post: post, media: media) }
                        } label: {
                            Label(L("下载"), systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }

                    if let url = URL(string: "https://x.com/\(post.user.screenName)/status/\(post.id)") {
                        Link(destination: url) {
                            Label(L("打开推文"), systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onHover { isHovering = $0 }
    }

    private func loadThumbnail() async {
        guard let urlString = media.url, let url = URL(string: urlString) else { return }
        // 缩略图优先：pbs.twimg.com 图片 URL 加 name=small（约 120px 宽）省流量；
        // 网格展示用缩略图，下载时才取 name=orig 原图
        var smallURL = url
        if url.path.contains("/media/") {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var items = comps.queryItems?.filter { $0.name != "name" } ?? []
            items.append(URLQueryItem(name: "name", value: "small"))
            comps.queryItems = items
            if let u = comps.url { smallURL = u }
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: smallURL)
            thumbnail = NSImage(data: data)
        } catch {}
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
