import SwiftUI

/// 主页时间线(X 式):推荐 / 关注 分段;关注下可切热门/最新。
/// 每帖 = 聚合推文(正文) + 媒体行的卡片;点击卡片进入推文详情弹窗。
struct HomeTimelineView: View {
    /// 点击头像 → 搜索该用户(HomeView 注入)
    var onAvatarTap: ((String) -> Void)? = nil
    @State private var store = HomeTimelineStore.shared
    @State private var detailPost: TwitterPost?

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
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.visiblePosts) { post in
                            TimelinePostCard(post: post, onTap: {
                                detailPost = post
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
        .sheet(item: $detailPost) { post in
            MediaDetailView(post: post, onSearchUser: { screenName in
                detailPost = nil
                onAvatarTap?(screenName)
            })
        }
        .task {
            if store.posts.isEmpty { await store.initialLoad() }
        }
    }
}

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
                    Text(created.formatted(.dateTime.month().day()))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let text = post.fullText, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
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
