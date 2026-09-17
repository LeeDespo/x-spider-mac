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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if store.posts.isEmpty && store.loading {
                ProgressView(L("加载中…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.visiblePosts) { post in
                            TimelinePostCard(post: post, onTap: {
                                DetailOverlayCenter.shared.open(post)
                            }, onAvatar: {
                                onAvatarTap?(post.user.screenName)
                            }, showFollowButton: true)
                            .onAppear {
                                if post.id == store.visiblePosts.last?.id {
                                    Task { await store.loadMore() }
                                }
                            }
                        }
                        if store.loadingMore {
                            ProgressView().padding(10)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        .task {
            if store.posts.isEmpty { await store.initialLoad() }
        }
        // 数据源变化（切推荐/关注、切热门/最新、重新加载）→ 分批计数从头开始，
        // 否则切换后仍停在旧的展开进度，甚至超过新数据量
        .onChange(of: store.flatMediaSignature) { _, _ in
            waterfallVisibleCount = 40
        }
    }

    /// 媒体瀑布流：按窗口宽度自适应列数；单元高度由媒体宽高比决定（不裁切、不 letterbox）。
    /// 不强调媒体先后顺序，因此用最短列优先的瀑布流而非等宽等高网格。
    ///
    /// 分批渲染很关键：`WaterfallLayout` 是 `Layout`（非 lazy），会测量**全部**子视图，
    /// 每个单元还会触发缩略图请求。若一次塞入上百条，切换形态时要等布局+首批图片完成，
    /// 表现为"切换要等很久"。这里只渲染前 `waterfallVisibleCount` 条，滚到底再追加一批。
    @State private var waterfallVisibleCount = 40

    private var homeMediaWaterfall: some View {
        GeometryReader { geo in
            // 目标列宽约 220pt，随窗口自适应（2–6 列）
            let columns = min(6, max(2, Int((geo.size.width - 32) / 220)))
            ScrollView {
                // 分批渲染：只渲染已展开的部分
                WaterfallLayout(columnCount: columns, spacing: 10) {
                    ForEach(store.flatMedia.prefix(waterfallVisibleCount), id: \.media.id) { item in
                        WaterfallMediaCell(media: item.media) {
                            DetailOverlayCenter.shared.open(item.post, mediaIndex: item.index - 1)
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
        let renderedCount = min(waterfallVisibleCount, store.flatMedia.count)
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
        // 哨兵底边进入视口下沿（含半屏提前量）才算"滚到底"
        guard sentinelMaxY <= viewportHeight else { return }
        if !allRendered {
            waterfallVisibleCount += 40
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
                Text(text)
                    .font(.callout)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
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
