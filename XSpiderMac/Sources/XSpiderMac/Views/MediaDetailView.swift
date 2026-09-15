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
            // 点击空白退出
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            HStack(spacing: 14) {
                mediaCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 14) {
                    tweetCard
                        .frame(height: 240)
                    repliesCard
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 400)
            }
            .padding(18)
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(.ultraThinMaterial)
        .task {
            await loadReplies()
            liked = detail?.favorited ?? false
            retweeted = detail?.retweeted ?? false
        }
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
                        .gesture(
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
            .overlay(alignment: .bottom) {
                // 悬浮下载按钮（媒体下方,不遮挡内容:半透明胶囊悬浮在卡底缘）
                HStack(spacing: 10) {
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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 12)
            }
        }
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

            // 互动行
            HStack(spacing: 22) {
                actionButton("heart", active: liked, tint: .pink, activeIcon: "heart.fill") { toggleLike() }
                actionButton("arrow.triangle.2.squarepath", active: retweeted, tint: .green,
                             activeIcon: "arrow.triangle.2.squarepath") { toggleRetweet() }
                actionButton("bookmark", active: bookmarked, tint: .blue, activeIcon: "bookmark.fill") { toggleBookmark() }
                actionButton("square.and.arrow.up", active: false, tint: .primary, activeIcon: "square.and.arrow.up") { shareTweet() }
            }
            .padding(.top, 2)

            if let actionMessage {
                Text(actionMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .liquidGlass(interactive: true, cornerRadius: 18)
    }

    private func actionButton(_ icon: String, active: Bool, tint: Color, activeIcon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: active ? activeIcon : icon)
                .foregroundStyle(active ? tint : .secondary)
                .font(.system(size: 15, weight: .medium))
        }
        .buttonStyle(.plain)
        .help("")
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
        .liquidGlass(interactive: true, cornerRadius: 18)
    }

    // MARK: - 动作

    private func toggleLike() {
        liked.toggle()
        Task {
            do { liked ? try await TwitterAPI.shared.favoriteTweet(id: post.id) : () }
            catch { liked.toggle(); actionMessage = L("操作失败：") + error.localizedDescription }
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

/// 媒体内容视图:图片自适应 / 视频 AVKit
struct MediaContentView: View {
    let media: TwitterMedia
    @State private var image: NSImage?

    var body: some View {
        Group {
            if media.type == .video || media.type == .gif, let videoUrl = bestVideoURL(media) {
                VideoPlayer(player: AVPlayer(url: videoUrl))
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
}
