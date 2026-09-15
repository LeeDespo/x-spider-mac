import SwiftUI
import AVKit

/// 推文详情弹窗（主页点击媒体触发；点击卡片外区域退出）：
/// - 左：媒体卡（高清图/视频，自适应尺寸，左右滑手势切换多媒体）
///   媒体下方悬浮：下载当前媒体 / 下载本推文全部媒体（不遮挡内容）
/// - 右上：推文卡（头像/昵称/正文/时间/互动行：点赞·转推·书签·分享）
/// - 右下：评论卡（TweetDetail 会话时间线懒加载 + 评论输入框占位）
/// 液态玻璃：跟随设置；不支持系统自动退化普通材质。
struct MediaDetailView: View {
    @State private var store = DownloadStore.shared
    let post: TwitterPost
    @State private var mediaIndex: Int
    @State private var detail: TwitterPost?
    @State private var replies: [TwitterPost] = []
    @State private var loadingReplies = false
    @State private var liked = false
    @State private var retweeted = false
    @State private var bookmarked = false
    @State private var actionMessage: String?
    @State private var repliesError: String?
    @Environment(\.dismiss) private var dismiss

    init(post: TwitterPost, initialMediaIndex: Int = 0) {
        self.post = post
        _mediaIndex = State(initialValue: initialMediaIndex)
    }

    private var medias: [TwitterMedia] { (detail?.medias ?? post.medias) ?? [] }
    private var current: TwitterMedia? { medias.indices.contains(mediaIndex) ? medias[mediaIndex] : medias.first }

    var body: some View {
        ZStack {
            // 暗色遮罩:可点击退出(卡片会挡住点击,不会穿透)
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            HStack(spacing: 18) {
                // 左:媒体卡(独立卡片)
                mediaCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 右:推文卡 + 评论卡(两张独立卡)
                VStack(spacing: 18) {
                    tweetCard
                        .frame(height: 250)
                    repliesCard
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 400)
            }
            .padding(20)
            // 下载胶囊:独立悬浮在整个布局底部中央(不属于任何卡片,绝不遮挡媒体)
            .overlay(alignment: .bottom) {
                downloadCapsule
                    .padding(.bottom, 4)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        // sheet 底透明:三卡浮在暗色遮罩上,视觉上完全分离
        .presentationBackground(.clear)
        .background(
            WindowAccessor { window in
                guard let window else { return }
                window.isOpaque = false
                window.backgroundColor = .clear
            }
        )
        .task {
            await loadReplies()
        }
    }

    /// 悬浮下载胶囊(独立于卡片之外)
    private var downloadCapsule: some View {
        HStack(spacing: 12) {
            if let media = current {
                Button {
                    Task { await store.createDownloadTask(post: detail ?? post, media: media) }
                } label: {
                    Label(L("下载当前"), systemImage: "arrow.down.circle")
                }
            }
            Button {
                Task {
                    for m in medias {
                        _ = await store.createDownloadTask(post: detail ?? post, media: m)
                    }
                }
            } label: {
                Label(L("下载全部(\(medias.count))"), systemImage: "arrow.down.heart")
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .liquidGlass(interactive: true, cornerRadius: 22)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
    }

    // MARK: - 左：媒体卡

    private var mediaCard: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.65))
                if let media = current {
                    MediaContentView(media: media)
                        .padding(10)
                        .id(mediaIndex)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 40)
                                .onEnded { value in
                                    let dx = value.translation.width
                                    if dx < -50, mediaIndex < medias.count - 1 {
                                        withAnimation(.spring(duration: 0.35)) { mediaIndex += 1 }
                                    } else if dx > 50, mediaIndex > 0 {
                                        withAnimation(.spring(duration: 0.35)) { mediaIndex -= 1 }
                                    }
                                }
                        )
                }
                if medias.count > 1 {
                    VStack {
                        Spacer()
                        Text("\(mediaIndex + 1) / \(medias.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {} // 卡内点击不穿透到遮罩层(空操作)
        .liquidGlass(interactive: false, cornerRadius: 18)
    }

    // MARK: - 右上：推文卡

    private var tweetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CachedAvatarView(urlString: post.user.avatar, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.user.name).font(.headline)
                    Text("@\(post.user.screenName)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let created = post.createdAt {
                    Text(created.formatted(.dateTime.month().day()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(post.fullText ?? "")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 计数行（回复 · 转推 · 赞 · 浏览）
            HStack(spacing: 14) {
                if let rc = detail?.replyCount ?? post.replyCount { Label("\(rc)", systemImage: "bubble.right").labelStyle(.titleAndIcon) }
                if let tc = detail?.retweetCount ?? post.retweetCount { Label("\(tc)", systemImage: "arrow.triangle.2.squarepath").labelStyle(.titleAndIcon) }
                if let lc = detail?.favoriteCount ?? post.favoriteCount { Label("\(lc)", systemImage: "heart").labelStyle(.titleAndIcon) }
                if let vc = detail?.views ?? post.views { Label("\(vc)", systemImage: "chart.bar").labelStyle(.titleAndIcon) }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // 互动行:液态玻璃图标钮(点赞 / 书签 / 分享)
            HStack(spacing: 12) {
                glassIconButton(icon: liked ? "heart.fill" : "heart", tint: liked ? .pink : .secondary,
                                help: L("点赞")) { toggleLike() }
                glassIconButton(icon: bookmarked ? "bookmark.fill" : "bookmark", tint: bookmarked ? .blue : .secondary,
                                help: L("书签")) { toggleBookmark() }
                glassIconButton(icon: "square.and.arrow.up", tint: .secondary,
                                help: L("分享")) { shareTweet() }
                Spacer()
                if let actionMessage {
                    Text(actionMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {} // 卡内点击不穿透到遮罩层
        .liquidGlass(interactive: true, cornerRadius: 18)
    }

    /// 液态玻璃圆形图标按钮（36pt）
    private func glassIconButton(icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .liquidGlass(interactive: true, cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 右下：评论卡

    private var repliesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("评论")).font(.headline)
                Spacer()
                if loadingReplies { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if repliesError != nil {
                Text(repliesError!)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(replies) { reply in
                            HStack(alignment: .top, spacing: 10) {
                                CachedAvatarView(urlString: reply.user.avatar, size: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(reply.user.name).font(.subheadline.weight(.semibold))
                                        Text("@\(reply.user.screenName)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(reply.fullText ?? "")
                                        .font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }

            Divider()
            // 评论输入框（发送走 CreateTweet;UI 占位）
            HStack {
                TextField(L("发布你的评论…"), text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                Button(L("发送")) {}
                    .disabled(true)
            }
            .padding(12)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {} // 卡内点击不穿透到遮罩层
        .liquidGlass(interactive: true, cornerRadius: 18)
    }

    // MARK: - 动作

    private func toggleLike() {
        liked.toggle()
        Task {
            do {
                if liked { try await TwitterAPI.shared.favoriteTweet(id: post.id) }
                else { try await TwitterAPI.shared.unfavoriteTweet(id: post.id) }
            } catch { liked.toggle(); actionMessage = L("操作失败：") + error.localizedDescription }
        }
    }

    private func toggleRetweet() {
        retweeted.toggle()
        Task {
            do {
                if retweeted { try await TwitterAPI.shared.createRetweet(id: post.id) }
                else { try await TwitterAPI.shared.deleteRetweet(id: post.id) }
            } catch { retweeted.toggle(); actionMessage = L("操作失败：") + error.localizedDescription }
        }
    }

    private func toggleBookmark() {
        bookmarked.toggle()
        Task {
            do {
                if bookmarked { try await TwitterAPI.shared.createBookmark(id: post.id) }
                else { try await TwitterAPI.shared.deleteBookmark(id: post.id) }
            } catch { bookmarked.toggle(); actionMessage = L("操作失败：") + error.localizedDescription }
        }
    }

    private func shareTweet() {
        let url = "https://x.com/\(post.user.screenName)/status/\(post.id)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        actionMessage = L("链接已复制")
    }

    private func loadReplies() async {
        loadingReplies = true
        defer { loadingReplies = false }
        do {
            let full = try await TwitterAPI.shared.getTweet(id: post.id)
            detail = full
            liked = full.favorited ?? false
            retweeted = full.retweeted ?? false
            // replies = 会话时间线里非 focal 的推文
            let all = try await TwitterAPI.shared.getTweetReplies(id: post.id)
            replies = all.filter { $0.id != post.id }
        } catch {
            repliesError = L("评论加载失败")
        }
    }
}

/// 媒体内容视图:图片自适应 / 视频(AppKit AVPlayerView——SwiftUI VideoPlayer 在 sheet 内初始化崩溃 SIGABRT)
struct MediaContentView: View {
    let media: TwitterMedia
    @State private var image: NSImage?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if media.type == .video || media.type == .gif, let videoUrl = bestVideoURL(media) {
                VideoPlayerContainer(url: videoUrl, player: $player)
                    .aspectRatio(videoAspect, contentMode: .fit)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .task { await loadHD() }
    }

    private func loadHD() async {
        guard var s = media.url else { return }
        if s.contains("/media/"), var comps = URLComponents(string: s) {
            var items = comps.queryItems?.filter { $0.name != "name" } ?? []
            items.append(URLQueryItem(name: "name", value: "large"))
            comps.queryItems = items
            if let u = comps.url { s = u.absoluteString }
        }
        image = await ImageCache.shared.image(for: s, category: .mediaThumbnails)
    }

    private func bestVideoURL(_ media: TwitterMedia) -> URL? {
        media.videoInfo?.variants?
            .filter { $0.contentType?.contains("mp4") == true && $0.url != nil }
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            .flatMap { URL(string: $0.url!) }
    }

    private var videoAspect: CGFloat {
        let ar = media.videoInfo?.aspectRatio ?? [16, 9]
        guard ar.count == 2, ar[1] != 0 else { return 16 / 9 }
        return CGFloat(ar[0]) / CGFloat(ar[1])
    }
}

/// AppKit AVPlayerView 包装(规避 SwiftUI VideoPlayer 的 sheet 崩溃)
struct VideoPlayerContainer: NSViewRepresentable {
    let url: URL
    @Binding var player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        let p = AVPlayer(url: url)
        v.player = p
        player = p
        p.play()
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
