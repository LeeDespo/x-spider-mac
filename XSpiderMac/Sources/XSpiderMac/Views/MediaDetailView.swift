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
    /// 点击头像 → 搜索该用户(HomeView 注入;nil = 不响应)
    var onSearchUser: ((String) -> Void)? = nil
    /// 关闭弹窗(全窗 overlay 注入;nil 时回退 @Environment dismiss)
    var onClose: (() -> Void)? = nil
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
    @State private var showCapsule = false
    @Environment(\.dismiss) private var dismiss

    init(post: TwitterPost, initialMediaIndex: Int = 0, onSearchUser: ((String) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.post = post
        _mediaIndex = State(initialValue: initialMediaIndex)
        self.onSearchUser = onSearchUser
        self.onClose = onClose
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var medias: [TwitterMedia] { (detail?.medias ?? post.medias) ?? [] }
    private var current: TwitterMedia? { medias.indices.contains(mediaIndex) ? medias[mediaIndex] : medias.first }

    var body: some View {
        // 点击 sheet 任何空白处退出;三卡内部各自吃掉点击(onTapGesture {})
        HStack(spacing: 20) {
            // 左:媒体卡(独立玻璃卡片)
            mediaCard
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 右:推文卡 + 评论卡(两张独立玻璃卡片)
            VStack(spacing: 20) {
                // 推文卡按内容自适应高度（长正文可滚），并设上限：
                // 固定 260pt 会压缩长正文、把标签行挤出卡片造成重叠；
                // 完全不限高则长推文会把评论卡挤没。minHeight 保证短推文时卡片不塌。
                // 上限取 420：引用推文会额外占高，340 时容易被压得正文只剩一两行。
                tweetCard
                    .frame(minHeight: 180, maxHeight: 420)
                repliesCard
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 410)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // 全窗背景模糊:毛玻璃虚化底层内容,三卡更聚焦
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.primary.opacity(0.04))
                .ignoresSafeArea()
        )
        .contentShape(Rectangle())
        .onTapGesture { close() }
        .background {
            // 快捷键:ESC 关闭;←/→ 切换媒体
            Button("") { close() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
            Button("") {
                if mediaIndex > 0 { withAnimation(.spring(duration: 0.35)) { mediaIndex -= 1 } }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .opacity(0)
            Button("") {
                if mediaIndex < medias.count - 1 { withAnimation(.spring(duration: 0.35)) { mediaIndex += 1 } }
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .opacity(0)
        }
        .task {
            await loadReplies()
            // 下载胶囊延迟浮现(打开详情后的入场动画)
            try? await Task.sleep(nanoseconds: 350_000_000)
            showCapsule = true
        }
    }

    // MARK: - 左：媒体卡

    /// 关闭按钮：与点赞/书签/分享同一行，靠右（放在推文卡内，用户一进详情就能看到出口）
    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .liquidGlass(interactive: true, cornerRadius: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("关闭"))
        .keyboardShortcut(.escape, modifiers: []) // 保留 ESC 关闭
    }

    private var mediaCard: some View {
        VStack(spacing: 10) {
            // 媒体区(手势挂在这一层,不影响 AVPlayerView 内部点击/控制)
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.65))
                if let media = current {
                    MediaContentView(media: media)
                        .padding(10)
                        .id(mediaIndex)
                        .transition(.opacity)
                } else {
                    // 无媒体推文（如"推文时间线"里的纯文字推文）：给出明确空态，
                    // 此前这里只剩黑底，看起来像界面崩了
                    VStack(spacing: 10) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(L("该推文没有媒体内容"))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                // 多媒体页码(右上)
                if medias.count > 1 {
                    Text("\(mediaIndex + 1) / \(medias.count)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                // 左右切换箭头(多媒体时显示;可靠,不依赖手势竞争)
                if medias.count > 1 {
                    HStack {
                        if mediaIndex > 0 {
                            arrowButton("chevron.left") { withAnimation(.spring(duration: 0.3)) { mediaIndex -= 1 } }
                        }
                        Spacer()
                        if mediaIndex < medias.count - 1 {
                            arrowButton("chevron.right") { withAnimation(.spring(duration: 0.3)) { mediaIndex += 1 } }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            // 触控板双指左右滑切媒体（事件监视器实现，含惯性判定；此前因命中测试问题不触发）
            .contentShape(Rectangle())
            .background {
                ScrollWheelCatcher { direction in
                    let next = mediaIndex + direction
                    if medias.indices.contains(next) {
                        withAnimation(.spring(duration: 0.35)) { mediaIndex = next }
                    }
                }
            }
            // 下载胶囊:媒体正下方居中(同一面板内,与媒体有 10pt 间隙);出入带动画。
            // 无媒体时不渲染（否则出现"下载全部(0)"这种无意义操作）
            if showCapsule, !medias.isEmpty {
                downloadCapsule
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: showCapsule)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {} // 卡内点击不穿透
        .liquidGlass(interactive: false, cornerRadius: 18)
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 10)
    }

    /// 媒体切换圆形箭头钮
    private func arrowButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var downloadCapsule: some View {
        HStack(spacing: 14) {
            Button {
                if let media = current { downloadCurrent(media) }
            } label: {
                Label(L("下载当前"), systemImage: "arrow.down.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .buttonBorderShape(.capsule)

            Button {
                downloadAllInTweet()
            } label: {
                Label(L("下载全部(\(medias.count))"), systemImage: "arrow.down.circle.fill")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .contentShape(Rectangle())
        .onTapGesture {} // 点击胶囊不退出弹窗
    }

    private func downloadCurrent(_ media: TwitterMedia) {
        Task {
            if let idx = medias.firstIndex(where: { $0.id == media.id }) {
                _ = await store.createDownloadTask(post: detail ?? post, media: media)
            }
        }
    }

    private func downloadAllInTweet() {
        Task {
            let p = detail ?? post
            await store.batchCreateDownloadTasks((p.medias ?? []).map { (p, $0) })
        }
    }

    // MARK: - 右上：推文卡

    private var tweetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CachedAvatarView(urlString: post.user.avatar, size: 40)
                    .contentShape(Circle())
                    .onTapGesture { onSearchUser?(post.user.screenName) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.user.name).font(.headline)
                    Text("@\(post.user.screenName)").font(.caption).foregroundStyle(.secondary)
                }
                FollowButton(screenName: post.user.screenName)
                Spacer()
                if let created = post.createdAt {
                    Text(created.postDisplayText)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // 正文 + 标签：**两者分开**，正文独占可滚动区，标签固定在正文之后。
            //
            // 旧实现把正文与 tags 塞进同一个 ScrollView，且正文用
            // `.frame(maxWidth: .infinity)` + `fixedSize(vertical:)` —— 在 ScrollView 里
            // 横向约束是未定的，maxWidth:.infinity 会与 fixedSize 互相拉扯，
            // 表现为标签行错位、并压到正文上。
            // 现在正文用 ScrollView 承载（长文可滚），标签放在其外层之后，不再重叠。
            // **不**给正文设 maxHeight:.infinity —— 那会与卡片外层的 maxHeight 上限
            // 冲突（两层都想吃掉剩余空间），高度协商异常时内容被压扁或溢出。
            // 让它自然占据剩余空间，上下限统一由外层 frame 决定。
            ScrollView {
                Text(post.fullText ?? "")
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .layoutPriority(1)

            // 标签：独立一行，横向可滚动（标签多时不换行、不挤压正文）
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
                                .fixedSize()
                        }
                    }
                }
                .frame(height: 22)   // 固定行高：避免 ScrollView 在 VStack 里撑出不确定高度
            }

            // 引用推文：内嵌在正文下方（与时间线卡片一致）
            if let quoted = post.quotedPost?.value {
                QuotedPostCard(post: quoted, onOpen: {
                    // 用 detail 里的最新副本，保证引用内容与主推文同源
                    DetailOverlayCenter.shared.open(quoted)
                }, onAvatar: { onSearchUser?(quoted.user.screenName) })
            }

            // 计数行（回复 · 转推 · 赞 · 浏览）
            HStack(spacing: 14) {
                if let rc = detail?.replyCount ?? post.replyCount { Label("\(rc)", systemImage: "bubble.right").labelStyle(.titleAndIcon) }
                if let tc = detail?.retweetCount ?? post.retweetCount { Label("\(tc)", systemImage: "arrow.2.squarepath").labelStyle(.titleAndIcon) }
                if let lc = detail?.favoriteCount ?? post.favoriteCount { Label("\(lc)", systemImage: "heart").labelStyle(.titleAndIcon) }
                if let vc = detail?.views ?? post.views { Label("\(vc)", systemImage: "chart.bar").labelStyle(.titleAndIcon) }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // 互动行:液态玻璃图标钮(点赞 / 书签 / 分享) + 右侧关闭
            HStack(spacing: 12) {
                glassIconButton(icon: liked ? "heart.fill" : "heart", tint: liked ? .pink : .secondary,
                                help: L("点赞")) { toggleLike() }
                glassIconButton(icon: bookmarked ? "bookmark.fill" : "bookmark", tint: bookmarked ? .blue : .secondary,
                                help: L("书签")) { toggleBookmark() }
                glassIconButton(icon: "square.and.arrow.up", tint: .secondary,
                                help: L("分享")) { shareTweet() }
                if let actionMessage {
                    Text(actionMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // 关闭放在最右：与互动按钮同排，位置固定且不会遮挡推文内容
                closeButton
            }
            .padding(.top, 2)
        }
        .padding(16)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {} // 卡内点击不穿透到遮罩层
        .liquidGlass(interactive: true, cornerRadius: 18)
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 10)
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
                                    .contentShape(Circle())
                                    .onTapGesture { onSearchUser?(reply.user.screenName) }
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(reply.user.name).font(.subheadline.weight(.semibold))
                                        Text("@\(reply.user.screenName)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { onSearchUser?(reply.user.screenName) }
                                    // 评论过长时折叠（列表里逐条全展开会把滚动条拉得很长）
                                    ExpandableText(text: reply.fullText ?? "",
                                                   collapsedLines: 4,
                                                   expandThreshold: 140,
                                                   font: .callout)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {} // 卡内点击不穿透到遮罩层
        .liquidGlass(interactive: true, cornerRadius: 18)
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 10)
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
            // 详情返回的媒体集合可能与列表里的不一致（数量/顺序），按媒体 id 重新定位当前索引，
            // 否则页码错乱或停在越界位置
            resyncMediaIndex(from: post.medias, to: full.medias)
            liked = full.favorited ?? false
            retweeted = full.retweeted ?? false
            // replies = 会话时间线里非 focal 的推文
            let all = try await TwitterAPI.shared.getTweetReplies(id: post.id)
            replies = all.filter { $0.id != post.id }
        } catch {
            repliesError = L("评论加载失败")
        }
    }

    /// 详情媒体集合变化时，按当前媒体的 id 在新集合中重新定位
    private func resyncMediaIndex(from old: [TwitterMedia]?, to new: [TwitterMedia]?) {
        let oldList = old ?? []
        let newList = new ?? []
        guard !oldList.isEmpty, !newList.isEmpty else { return }
        guard oldList.count != newList.count else { return } // 结构相同则保持用户在看的索引
        let currentId = oldList.indices.contains(mediaIndex) ? oldList[mediaIndex].id : nil
        guard let currentId, let newIndex = newList.firstIndex(where: { $0.id == currentId }) else {
            mediaIndex = min(mediaIndex, max(0, newList.count - 1))
            return
        }
        mediaIndex = newIndex
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
        image = await ImageCache.shared.image(for: s, category: .mediaThumbnails, maxPixelSize: 1600)
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
