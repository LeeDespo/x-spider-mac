import SwiftUI
import AVKit

/// 推文详情弹窗（主页双击媒体触发）：
/// - 左侧：媒体区（高清图 / 视频播放器），推文多媒体时左右切换
/// - 右侧：推文正文、互动统计、评论区（TweetDetail conversation 时间线）
/// - 评论区懒加载：弹窗打开后异步拉取
struct MediaDetailView: View {
    let post: TwitterPost
    /// 双击的媒体在 post.medias 里的下标
    @State private var mediaIndex: Int
    @State private var detail: TwitterPost?
    @State private var replies: [TwitterPost] = []
    @State private var loadingReplies = false
    @State private var repliesError: String?
    @Environment(\.dismiss) private var dismiss

    init(post: TwitterPost, initialMediaIndex: Int = 0) {
        self.post = post
        _mediaIndex = State(initialValue: initialMediaIndex)
    }

    private var medias: [TwitterMedia] { post.medias ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            // ── 左：媒体 ──
            mediaPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85))

            Divider()

            // ── 右：推文信息 + 评论区 ──
            VStack(alignment: .leading, spacing: 0) {
                tweetHeader
                Divider()
                repliesPane
            }
            .frame(width: 380)
        }
        .frame(minWidth: 920, minHeight: 600)
        .task { await loadReplies() }
    }

    // MARK: - 媒体区

    @ViewBuilder
    private var mediaPane: some View {
        VStack(spacing: 0) {
            Spacer()
            if medias.isEmpty {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                mediaView(for: medias[min(mediaIndex, medias.count - 1)])
                    .id(mediaIndex)
                    .transition(.opacity)
            }
            Spacer()

            if medias.count > 1 {
                HStack(spacing: 16) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            mediaIndex = (mediaIndex - 1 + medias.count) % medias.count
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Text("\(mediaIndex + 1) / \(medias.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))

                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            mediaIndex = (mediaIndex + 1) % medias.count
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder
    private func mediaView(for media: TwitterMedia) -> some View {
        switch media.type {
        case .photo:
            FullPhotoView(urlString: media.url ?? "")
        case .video, .gif:
            if let url = playableURL(for: media), let player = makePlayer(url: url) {
                VideoPlayer(player: player)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            } else {
                Image(systemName: "video.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    /// 视频/ gif 播放地址：取码率最高的 mp4 变体；gif 用 videoInfo.url
    private func playableURL(for media: TwitterMedia) -> URL? {
        if media.type == .gif, let u = media.videoInfo?.url { return URL(string: u) }
        let variants = media.videoInfo?.variants ?? []
        let mp4s = variants.filter { ($0.contentType ?? "").contains("mp4") && $0.url != nil }
        if let best = mp4s.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
            return URL(string: best.url!)
        }
        return media.videoInfo?.url.flatMap { URL(string: $0) }
    }

    @State private var playerCache: [String: AVPlayer] = [:]
    private func makePlayer(url: URL) -> AVPlayer? {
        if let cached = playerCache[url.absoluteString] { return cached }
        let p = AVPlayer(url: url)
        playerCache[url.absoluteString] = p
        return p
    }

    // MARK: - 推文信息

    private var tweetHeader: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    CachedAvatarView(urlString: post.user.avatar, size: 44)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.user.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("@\(post.user.screenName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let text = post.fullText, !text.isEmpty {
                    Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }

                // 时间 + 互动统计
                VStack(alignment: .leading, spacing: 6) {
                    if let created = post.createdAt {
                        Text(created.formatted(date: .long, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 18) {
                        stat("message", post.replyCount)
                        stat("arrow.2.squarepath", post.retweetCount)
                        stat("heart", post.favoriteCount)
                        stat("bookmark", post.bookmarkCount)
                        stat("chart.bar", post.views)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // 互动计数格式化（1.2K / 3.4M）
                Divider().padding(.vertical, 2)
                Text(L("评论"))
                    .font(.headline)
                    .padding(.top, 6)
            }
            .padding(16)
        }
        .frame(maxHeight: 340)
    }

    @ViewBuilder
    private func stat(_ icon: String, _ value: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(Self.countText(value ?? 0))
        }
    }

    static func countText(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    // MARK: - 评论区

    private var repliesPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if loadingReplies {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).padding(18)
                        Spacer()
                    }
                } else if let err = repliesError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                        Text(L("评论加载失败，可稍后重试")).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity).padding(24)
                } else if replies.isEmpty {
                    Text(L("暂无评论"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(24)
                } else {
                    ForEach(replies) { reply in
                        replyRow(reply)
                        Divider()
                    }
                }
            }
        }
    }

    private func replyRow(_ reply: TwitterPost) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAvatarView(urlString: reply.user.avatar, size: 32)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(reply.user.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text("@\(reply.user.screenName)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let created = reply.createdAt {
                        Text(created.formatted(date: .numeric, time: .omitted))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let text = reply.fullText, !text.isEmpty {
                    Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 14) {
                    statMini("message", reply.replyCount)
                    statMini("heart", reply.favoriteCount)
                }
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statMini(_ icon: String, _ value: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(Self.countText(value ?? 0)).monospacedDigit()
        }
        .font(.caption2)
    }

    // MARK: - 数据

    /// TweetDetail 的 conversation 时间线里 focal 之后的条目即回复
    private func loadReplies() async {
        loadingReplies = true
        repliesError = nil
        defer { loadingReplies = false }
        do {
            let (focal, all) = try await TwitterAPI.shared.getTweetWithReplies(id: post.id)
            detail = focal
            replies = all.filter { $0.id != focal.id }
        } catch {
            repliesError = error.localizedDescription
        }
    }
}

/// 高清大图（全图 contain，缓存走 mediaThumbnails 类目）
struct FullPhotoView: View {
    let urlString: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: urlString) {
            image = await ImageCache.shared.image(for: urlString, category: .mediaThumbnails)
        }
    }
}
