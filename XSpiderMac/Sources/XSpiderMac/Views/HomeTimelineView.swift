import SwiftUI

/// 主页时间线(X 式):推荐 / 关注 分段;关注下可切热门/最新。
/// 每帖 = 聚合推文(正文) + 媒体行的卡片;点击卡片进入推文详情弹窗。
struct HomeTimelineView: View {
    /// 点击头像 → 搜索该用户(HomeView 注入)
    var onAvatarTap: ((String) -> Void)? = nil
    @State private var store = HomeTimelineStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // 分段控制器(左上,搜索框下方由 HomeView 布局保证)
            HStack {
                Picker(L("时间线"), selection: Binding(
                    get: { store.mode },
                    set: { store.setMode($0) }
                )) {
                    Text(L("推荐")).tag(HomeTimelineMode.forYou)
                    Text(L("关注")).tag(HomeTimelineMode.following)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                if store.mode == .following {
                    Picker(L("排序"), selection: Binding(
                        get: { store.followingSort },
                        set: { store.setFollowingSort($0) }
                    )) {
                        Text(L("热门")).tag(FollowingSort.hot)
                        Text(L("最新")).tag(FollowingSort.latest)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                // 展示形态：推文卡片 / 纯媒体瀑布流。
                // 数据源同一条主页时间线（只含有媒体的推文），切换形态不产生任何新请求。
                Picker(L("形态"), selection: Binding(
                    get: { store.contentType },
                    set: { store.contentType = $0 }
                )) {
                    Text(L("推文")).tag(HomeTimelineContentType.tweets)
                    Text(L("媒体")).tag(HomeTimelineContentType.media)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                Spacer()

                // 刷新：显式重新加载（放在最右，与分段控制器同栏）
                Button {
                    Task { await store.refreshExplicitly() }
                } label: {
                    if store.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.loading)
                .help(L("刷新：重新加载当前时间线"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if store.posts.isEmpty && store.loading {
                ProgressView(L("加载中…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.loadError, store.posts.isEmpty {
                // 加载失败要可见（此前只写日志 → 用户看到无限转圈，以为还在加载）
                loadFailureView(error)
            } else if store.posts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "newspaper")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(L("时间线为空，下拉或稍后重试"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.contentType == .media {
                homeMediaWaterfall
                    // 形态切换时淡入淡出，避免内容"跳"一下
                    .transition(.opacity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.visiblePosts) { post in
                                TimelinePostCard(post: post, onTap: {
                                    DetailOverlayCenter.shared.open(post)
                                }, onAvatar: {
                                    onAvatarTap?(post.user.screenName)
                                }, showFollowButton: true)
                                // 预取一屏：倒数第 3 条出现时就拉下一页，而不是等最后一条。
                                // 与瀑布流阈值语义一致（提前约一屏），用户滚到底时数据已就绪。
                                // LazyVStack 会销毁滚出视口的卡片，故 onAppear 可重复触发。
                                .onAppear {
                                    let posts = store.visiblePosts
                                    guard let idx = posts.firstIndex(where: { $0.id == post.id }) else { return }
                                    // LazyVStack 的 onAppear 可靠（滚动中会销毁/重建），
                                    // 正好可用来记录浏览位置
                                    store.reportScrollAnchor(post.id, for: .tweets)
                                    if idx >= posts.count - 3 {
                                        Task { await store.loadMore() }
                                    }
                                }
                            }
                            if store.loadingMore {
                                ProgressView().padding(10)
                            } else if let error = store.loadError {
                                // 翻页失败：底部给出重试入口（不再静默卡住）
                                footerRetry(error)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    .onAppear { restoreAnchor(proxy: proxy, type: .tweets) }
                }
                .transition(.opacity)
            }
        }
        // 分段切换的动画：三个分段（推荐/关注、热门/最新、推文/媒体）任一变化都做内容过渡，
        // 让切换"立刻可见"且不生硬。用 easeOut 短时过渡——内容整体替换，弹簧会显得晃。
        .animation(.easeOut(duration: 0.18), value: store.mode)
        .animation(.easeOut(duration: 0.18), value: store.contentType)
        .animation(.easeOut(duration: 0.18), value: store.followingSort)
        .task {
            if store.posts.isEmpty { await store.initialLoad() }
        }
        // 注意：**不要**在这里按数据变化重置 waterfallVisibleCount。
        // 曾用 onChange(of: flatMediaSignature) 做重置，而指纹含 flatMedia.count，
        // 于是"加载下一页"必然触发重置 → 已渲染条目骤减 → 视觉上跳回前 40 条
        // （用户反馈的"滚到底加载新内容会退回前面，位置固定"）。
        // 数据源切换不需要重置：prefix() 天然按实际数量截断，计数器只增不减是安全的。
    }

    /// 整页加载失败：说明原因 + 重试
    private func loadFailureView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(L("加载失败"))
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await store.retry() }
            } label: {
                Label(L("重试"), systemImage: "arrow.clockwise")
            }
            .compatGlassProminentButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 翻页失败：底部一行 + 重试
    private func footerRetry(_ error: String) -> some View {
        VStack(spacing: 6) {
            Text(L("加载中断") + "：" + error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("重试")) {
                Task { await store.retry() }
            }
            .compatGlassButton()
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// 媒体瀑布流：按窗口宽度自适应列数；单元高度由媒体宽高比决定（不裁切、不 letterbox）。
    /// 不强调媒体先后顺序，因此用最短列优先的瀑布流而非等宽等高网格。
    ///
    /// 分批渲染很关键：`WaterfallLayout` 是 `Layout`（非 lazy），会测量**全部**子视图，
    /// 每个单元还会触发缩略图请求。若一次塞入上百条，切换形态时要等布局+首批图片完成，
    /// 表现为"切换要等很久"。只渲染前 `store.mediaRenderedCount` 条，滚到底再追加一批。
    /// 计数存 store（视图会被 `.id(selection)` 重建，@State 会归零丢失进度）。

    private var homeMediaWaterfall: some View {
        GeometryReader { geo in
            // 目标列宽约 220pt，随窗口自适应（2–6 列）
            let columns = min(6, max(2, Int((geo.size.width - 32) / 220)))
            ScrollViewReader { proxy in
                ScrollView {
                    // 分批渲染：只渲染已展开的部分
                    WaterfallLayout(columnCount: columns, spacing: 10) {
                        ForEach(Array(store.flatMedia.prefix(store.mediaRenderedCount).enumerated()), id: \.element.media.id) { index, item in
                            WaterfallMediaCell(media: item.media) {
                                DetailOverlayCenter.shared.open(item.post, mediaIndex: item.index - 1)
                            }
                            // 供 ScrollViewReader 定位（restoreAnchor 用它滚回上次位置）
                            .id(item.media.id)
                            // 稀疏位置锚点：每 20 条一个 1px 探针，用于记住浏览位置。
                            // 不能给每个格子挂 GeometryReader —— 瀑布流非 lazy，
                            // 上百个 reader 的持续重算代价过高；稀疏后开销降到 1/20。
                            .background(alignment: .top) {
                                if index % Self.anchorStride == 0, let mid = item.media.id {
                                    scrollAnchorProbe(id: mid)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    // 触底哨兵：必须先展开本地未渲染的批次，再向服务端翻页
                    mediaLoader(viewportHeight: geo.size.height)
                        .padding(.vertical, 12)
                }
                .padding(.bottom, 20)
                .coordinateSpace(name: homeTimelineScrollSpace)
                // 恢复浏览位置：视图被 `.id(selection)` 重建后回到上次锚点
                .onAppear { restoreAnchor(proxy: proxy, type: .media) }
            }
        }
    }

    /// 每多少条插一个位置锚点（越小越精确、开销越大）
    private static let anchorStride = 20

    /// 位置锚点：滚到视口顶或更上时，把自己上报为"当前浏览位置"
    private func scrollAnchorProbe(id: String) -> some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(homeTimelineScrollSpace)).minY
            Color.clear
                .onChange(of: minY) { _, y in
                    if y <= 1 { store.reportScrollAnchor(id, for: store.contentType) }
                }
                .onAppear {
                    if minY <= 1 { store.reportScrollAnchor(id, for: store.contentType) }
                }
        }
        .frame(height: 1)
    }

    /// 把滚动位置恢复到上次锚点。
    /// 只在 store 记有锚点、且该锚点确实还在已渲染范围内时才滚——
    /// 否则保持顶部（首次访问的正常行为）。
    private func restoreAnchor(proxy: ScrollViewProxy, type: HomeTimelineContentType) {
        guard let anchor = store.scrollAnchor(for: type) else { return }
        let exists = type == .media
            ? store.flatMedia.prefix(store.mediaRenderedCount).contains { $0.media.id == anchor }
            : store.displayPosts.contains { $0.id == anchor }
        guard exists else { return }
        // 延后一拍：等布局确定目标位置，否则刚 onAppear 时滚动会被忽略
        DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    /// 触底加载：先展开已下载的下一批，全部展开后再请求下一页。
    ///
    /// 哨兵必须由**真实可见性**驱动，这里沿用 `HomeView` 已验证的坐标空间方案：
    /// 读取哨兵在滚动容器坐标系里的 maxY，与视口高度比较。
    ///
    /// 两个曾经的坑：
    /// 1) `ProgressView().onAppear` 只在首次挂载触发 → 滚到底不出下一页，
    ///    必须切回推文再切回来（重建视图）才加载；
    /// 2) `WaterfallLayout` 是 `Layout`（非 lazy），所有子视图始终在层级中，
    ///    所以 `.task` 会在挂载时立即触发、与滚动位置无关 → 自动连翻（429 风暴）。
    private func mediaLoader(viewportHeight: CGFloat) -> some View {
        let renderedCount = min(store.mediaRenderedCount, store.flatMedia.count)
        let allRendered = renderedCount >= store.flatMedia.count
        let canPage = store.hasMore
        return Group {
            if allRendered && !canPage {
                Text(L("已加载全部"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            } else if store.loadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                GeometryReader { proxy in
                    let maxY = proxy.frame(in: .named(homeTimelineScrollSpace)).maxY
                    Color.clear
                        // 哨兵进入视口（不足半屏）才推进；再次滚到底会因 maxY 变化重新求值
                        .onChange(of: maxY) { _, y in
                            advanceIfVisible(y, viewportHeight: viewportHeight,
                                             renderedCount: renderedCount, allRendered: allRendered, canPage: canPage)
                        }
                        .onAppear {
                            advanceIfVisible(maxY, viewportHeight: viewportHeight,
                                             renderedCount: renderedCount, allRendered: allRendered, canPage: canPage)
                        }
                }
                .frame(height: 1)
            }
        }
    }

    private func advanceIfVisible(_ sentinelMaxY: CGFloat, viewportHeight: CGFloat, renderedCount: Int, allRendered: Bool, canPage: Bool) {
        guard !store.loadingMore, viewportHeight > 0 else { return }
        // **预取一屏**：哨兵距视口下沿还有一屏时就推进，而不是等它真正进入视口。
        // 这就是上游 `InfiniteScroll` 的语义（threshold 默认取 clientHeight：
        // `scrollHeight - scrollTop <= clientHeight + threshold`），
        // 效果是用户滚到底时下一批已经就绪 —— 视觉上无缝。
        // 提前量**必须**只有一屏：无节制连拉会触发 429（见 AGENTS.md 大坑 3）。
        let prefetchLine = viewportHeight * 2
        guard sentinelMaxY <= prefetchLine else { return }
        if !allRendered {
            store.mediaRenderedCount += 40
        } else if canPage {
            Task { await store.loadMore() }
        }
    }
}

/// 瀑布流滚动的命名坐标空间（与 HomeView 的 BottomSentinel 同理，macOS 14 兼容）
private let homeTimelineScrollSpace = "homeTimelineScroll"

/// 单张时间线卡片:聚合推文(上) + 媒体(下)
struct TimelinePostCard: View {
    let post: TwitterPost
    let onTap: () -> Void
    /// 点击头像 → 跳转搜索该用户(可空)
    var onAvatar: (() -> Void)? = nil
    /// 关注按钮(可空:主页时间线卡片显示)
    var showFollowButton: Bool = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 转推标签：「某某 转推」。主体是原作者的正文，本行说明由谁转发
            // （与 X 网页端一致；由 extractPostsFromTweetEntries 展平时填充）
            if let by = post.retweetedBy {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.caption2.weight(.semibold))
                    // 用占位符而非字符串插值：插值会让整串成为查表 key，永远命中不到翻译表
                    Text(L("%@ 转推").replacingOccurrences(of: "%@", with: by.name))
                        .font(.caption2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture { onAvatar?() }   // 点标签同样可跳到转发者
            }

            // 作者行 + 正文
            HStack(spacing: 10) {
                CachedAvatarView(urlString: post.user.avatar, size: 38)
                    .contentShape(Circle())
                    .onTapGesture { onAvatar?() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.user.name).font(.subheadline.weight(.semibold))
                    Text("@\(post.user.screenName)").font(.caption).foregroundStyle(.secondary)
                }
                if showFollowButton {
                    FollowButton(screenName: post.user.screenName)
                }
                Spacer()
                if let created = post.createdAt {
                    Text(created.postDisplayText)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let text = post.fullText, !text.isEmpty {
                // 长文可展开（原先 lineLimit(6) 静默截断且无展开入口）
                ExpandableText(text: text, collapsedLines: 6)
            }

            // 引用推文：缩小内嵌在正文下方。点击打开**被引用推文**的详情，
            // 与点击卡片其余部分（打开主推文）区分——内层手势优先，无需额外处理。
            if let quoted = post.quotedPost?.value {
                QuotedPostCard(post: quoted, onOpen: {
                    DetailOverlayCenter.shared.open(quoted)
                }, onAvatar: onAvatar)
            }

            if let tags = post.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            // 媒体行(最多 4 张,1:1 收纳)
            if let medias = post.medias, !medias.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(medias.prefix(4).enumerated()), id: \.offset) { _, media in
                        CachedMediaThumbView(urlString: media.url, width: 120, height: 120, cornerRadius: 10)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            // 互动计数行
            HStack(spacing: 18) {
                Label("\(post.replyCount ?? 0)", systemImage: "bubble.left")
                Label("\(post.retweetCount ?? 0)", systemImage: "arrow.2.squarepath")
                Label("\(post.favoriteCount ?? 0)", systemImage: "heart")
                if let views = post.views {
                    Label(views > 9999 ? String(format: "%.1f万", Double(views) / 10000) : "\(views)", systemImage: "chart.bar")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .liquidGlass(interactive: true, cornerRadius: 16)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.005 : 1)
        .onTapGesture { onTap() }
    }
}
