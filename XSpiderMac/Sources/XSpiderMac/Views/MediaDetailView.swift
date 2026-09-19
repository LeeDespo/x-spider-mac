import SwiftUI
import AVKit

/// 推文详情弹窗（主页点击媒体触发；点击卡片外区域退出）：
/// - 左：媒体卡（高清图/视频，自适应尺寸，左右滑手势切换多媒体）
///   媒体下方悬浮：下载当前媒体 / 下载本推文全部媒体（不遮挡内容）
/// - 右上：推文卡（头像/昵称/正文/时间/互动行：点赞·转推·书签·分享）
/// - 右下：评论卡（TweetDetail 会话时间线懒加载，带层级 + 排序）
/// 液态玻璃：跟随设置；不支持系统自动退化普通材质。
struct MediaDetailView: View {
    @State private var store = DownloadStore.shared
    /// 点击头像 → 搜索该用户(HomeView 注入;nil = 不响应)
    var onSearchUser: ((String) -> Void)? = nil
    /// 返回上一层（引用推文跳转 / 头像跳转的返回语义见 `DetailOverlayCenter.back`）
    var onBack: (() -> Void)? = nil
    let post: TwitterPost
    @State private var mediaIndex: Int
    @State private var detail: TwitterPost?
    @State private var replies: [ReplyNode] = []
    @State private var replySort: ReplySort = .relevance
    @State private var loadingReplies = false
    @State private var liked = false
    @State private var retweeted = false
    @State private var bookmarked = false
    @State private var actionMessage: String?
    @State private var repliesError: String?
    @State private var showCapsule = false
    @Environment(\.dismiss) private var dismiss

    init(post: TwitterPost, initialMediaIndex: Int = 0, onSearchUser: ((String) -> Void)? = nil, onBack: (() -> Void)? = nil) {
        self.post = post
        _mediaIndex = State(initialValue: initialMediaIndex)
        self.onSearchUser = onSearchUser
        self.onBack = onBack
    }

    /// 返回：优先走详情栈（回到上一条推文详情），栈空则由 ContentView 关闭浮层。
    private func back() {
        if let onBack { onBack() } else { dismiss() }
    }

    /// 关闭整个浮层（点卡外空白 / ESC）：与「返回」不同——
    /// 返回是逐层回退（引用链、头像跳转），关闭是直接离开详情。
    private func close() {
        DetailOverlayCenter.shared.close()
    }

    /// 排序后的评论（层级展示用）。`relevance` 保持服务端顺序（见 `ReplySort`）。
    private var sortedReplies: [ReplyNode] {
        replySort.sorted(replies)
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
        // 点卡外空白 = 直接关闭（用户明确点了"外面"，语义是离开详情，
        // 不是逐层返回——否则点空白要按引用链一路退回去，与直觉不符）
        .onTapGesture { close() }
        .background {
            // 快捷键:ESC 逐层返回(与返回按钮一致);←/→ 切换媒体。
            // 注意：这里**不能**再放一个 ESC 关闭的按钮——两个 .escape 快捷键里
            // 只有一个会生效，语义会随注册顺序漂移，表现为"ESC 有时返回、有时直接关"。
            Button("") { back() }
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

    /// 返回按钮：与点赞/书签/分享同一行，靠右。
    ///
    /// **强调色用在背景上**（圆底填强调色 + 白色图案），而不是把图案本身染成强调色——
    /// 后者在玻璃底上对比度不足、也不像"主操作"。这样返回是这一行里最醒目的按钮。
    private var backButton: some View {
        Button {
            back()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(NavigationHistory.shared.canGoBack ? L("返回上一个界面") : L("返回"))
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
                    // 离卡片下缘留出呼吸空间：此前胶囊紧贴底部边线，
                    // 玻璃卡片的圆角与描边会切到它，看着"挤在边上"
                    .padding(.bottom, 14)
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

    /// 当前媒体是否已下载（判定依据跟随设置：记录文件 / 文件名）
    private var currentDownloaded: Bool {
        guard let media = current else { return false }
        return store.hasDownloaded(media: media, dir: store.targetDir(for: detail ?? post), post: detail ?? post)
    }

    /// 本条推文里已下载的媒体数（`m`）
    private var downloadedCount: Int {
        let p = detail ?? post
        let dir = store.targetDir(for: p)
        return medias.filter { store.hasDownloaded(media: $0, dir: dir, post: p) }.count
    }

    /// 下载胶囊：媒体正下方居中。
    ///
    /// 三个文案都随**已下载状态**变化（判定依据跟随设置，见 `DownloadStore.hasDownloaded`）：
    /// - 当前媒体已下载 → 「当前已下载」（不再显示「下载当前」，避免误导）
    /// - 还有未下载 → 「下载全部(n-m)」，n=推文媒体数，m=已下载数
    /// - 全部已下载 → 「全部已下载」
    private var downloadCapsule: some View {
        // 读 judgementVersion 建立观察依赖：判定依据/保存路径变化后缓存会变，
        // 但 SwiftUI 追踪不到 static 缓存 → 不读它按钮状态会停在旧结果
        let _ = store.judgementVersion
        let total = medias.count
        let done = downloadedCount
        let allDone = total > 0 && done >= total
        return HStack(spacing: 12) {
            Button {
                if let media = current { downloadCurrent(media) }
            } label: {
                Label(currentDownloaded ? L("当前已下载") : L("下载当前"),
                      systemImage: currentDownloaded ? "checkmark.circle" : "arrow.down.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .buttonBorderShape(.capsule)
            .disabled(currentDownloaded)

            Button {
                downloadAllInTweet()
            } label: {
                Label(allDone ? L("全部已下载") : L("下载全部(\(total - done))"),
                      systemImage: allDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .buttonBorderShape(.capsule)
            .disabled(allDone)

            // 放大镜：开媒体查看窗口（与下载按钮同一行）
            Button {
                openViewer()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .buttonBorderShape(.capsule)
            .help(L("详细查看"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .contentShape(Rectangle())
        .onTapGesture {} // 点击胶囊不退出弹窗
    }

    /// 打开媒体查看窗口：范围是**本条推文的全部媒体**
    private func openViewer() {
        guard !medias.isEmpty else { return }
        MediaViewerCenter.shared.open(medias: medias, index: mediaIndex,
                                      post: detail ?? post, origin: .detail)
    }

    private func downloadCurrent(_ media: TwitterMedia) {
        Task {
            if let idx = medias.firstIndex(where: { $0.id == media.id }) {
                _ = idx
                _ = await store.createDownloadTask(post: detail ?? post, media: media)
            }
        }
    }

    /// 下载本条推文里**尚未下载**的媒体（已下载的跳过，避免重复请求配额）
    private func downloadAllInTweet() {
        Task {
            let p = detail ?? post
            let dir = store.targetDir(for: p)
            let pending = medias.filter { !store.hasDownloaded(media: $0, dir: dir, post: p) }
            await store.batchCreateDownloadTasks(pending.map { (p, $0) })
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
                TranslatableText(text: post.fullText ?? "",
                                 translationKey: post.id,
                                 lang: post.lang)
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
                    // 在浮层**内部**跳转：`openFromDetail` 会把当前推文记入历史，
                    // 因此在新详情里点「返回」会回到本条推文（用户要求）
                    DetailOverlayCenter.shared.openFromDetail(quoted)
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
                // 返回放在最右：与互动按钮同排，位置固定且不会遮挡推文内容
                backButton
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
                // 排序：相关（服务端顺序）/ 喜欢 / 最近。
                // 放在卡片头而不是藏进菜单——评论排序是高频动作。
                Picker(L("排序"), selection: $replySort) {
                    Text(L("相关")).tag(ReplySort.relevance)
                    Text(L("喜欢")).tag(ReplySort.likes)
                    Text(L("最近")).tag(ReplySort.recent)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 84)
                .disabled(replies.isEmpty)
                .help(L("评论排序：相关为服务端推荐顺序"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if repliesError != nil {
                Text(repliesError!)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if replies.isEmpty && !loadingReplies {
                Text(L("暂无评论"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(sortedReplies) { node in
                            replyRow(node)
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

    /// 一条回复：按 depth 缩进 + 左侧连接线。
    ///
    /// 缩进上限 3 层（卡片只有 410pt 宽，无限缩进会把正文挤成一条缝）；
    /// 更深的层不再缩进，改为在作者行前加「回复 @xxx」前缀表明从属关系。
    /// 孤儿（父不在本页）同样用该前缀——它对用户来说与"父被折叠"是一回事。
    @ViewBuilder
    private func replyRow(_ node: ReplyNode) -> some View {
        let indent = min(node.depth - 1, 3)
        HStack(alignment: .top, spacing: 0) {
            if indent > 0 {
                // 连接线：标明从属关系（参考 X 网页端）
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
                    .padding(.trailing, 9)
            }
            HStack(alignment: .top, spacing: 10) {
                CachedAvatarView(urlString: node.post.user.avatar, size: 30)
                    .contentShape(Circle())
                    .onTapGesture { onSearchUser?(node.post.user.screenName) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(node.post.user.name).font(.subheadline.weight(.semibold))
                        Text("@\(node.post.user.screenName)")
                            .font(.caption).foregroundStyle(.secondary)
                        // 缩进到上限（或父不在本页）后，靠文字表达层级：
                        // 前缀用**被回复者**（node.parentScreenName），不是本条作者
                        if (indent >= 3 || node.isPartialParent), let parent = node.parentScreenName {
                            Text(L("回复 %@").replacingOccurrences(of: "%@", with: "@\(parent)"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSearchUser?(node.post.user.screenName) }
                    // 评论过长时折叠 + 可翻译
                    TranslatableText(text: node.post.fullText ?? "",
                                     translationKey: node.post.id,
                                     lang: node.post.lang,
                                     collapsedLines: 4)

                    // 评论自带的媒体缩略图（与媒体卡同一套 hover 按钮）
                    if let medias = node.post.medias, !medias.isEmpty {
                        ReplyMediaThumbRow(post: node.post, medias: medias)
                    }

                    // 计数行：点赞数 + 评论数（用户要求）。
                    // 用 `Label` + `.titleAndIcon`，与推文卡计数行视觉一致。
                    HStack(spacing: 14) {
                        Label("\(node.post.favoriteCount ?? 0)", systemImage: "heart")
                        Label("\(node.post.replyCount ?? 0)", systemImage: "bubble.right")
                        Spacer(minLength: 0)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                }
            }
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    /// 评论里的媒体缩略图行：与媒体卡**同一套 hover 按钮**（下载/已下载 + 详细查看）。
///
/// 布局与尺寸（与媒体卡一致的做法）：
/// - **单张保持宽高比**：像 @leoakok 那张 947×2048 的竖长图，方形裁切只剩中间一条；
/// - **多张用小方格 64pt**，尺寸要收着算：卡片宽 410，减内边距、缩进（最深 48）、
///   头像（30+10）后约 294pt，`4×64 + 3×4 = 268` 才放得下（用 84 会溢出被裁）；
/// - 按钮直径 26pt：64pt 的格子里放得下两个，不挡住缩略图主体。
///
/// **按钮挂在每一张缩略图上**（不是整行一组）：下载必须作用于确定的那张媒体，
/// 整行共用一组按钮会导致"多图时不知道在下载哪一张"。
///
/// **查看范围 = 本条评论自己的媒体**（需求：切换媒体只切评论内的；
/// 那条评论没有更多媒体时停在原地，不会跳到别的评论或主推文），
/// 起始位置为被点的那一张。
///
/// 解码一律走 `ImageCache` + 目标尺寸降采样：评论一次可显示几十条，
/// 按原图解码（可能 2048px）会拖慢滚动。
struct ReplyMediaThumbRow: View {
    let post: TwitterPost
    let medias: [TwitterMedia]

    var body: some View {
        Group {
            if medias.count == 1, let only = medias.first {
                ReplyMediaThumbCell(post: post, media: only, decodePixelSize: 320,
                                    allMedias: medias, index: 0)
                    .aspectRatio(only.aspectRatioValue, contentMode: .fit)
                    .frame(maxWidth: 168, maxHeight: 168, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(medias.prefix(4).enumerated()), id: \.offset) { index, media in
                        ReplyMediaThumbCell(post: post, media: media, decodePixelSize: 180,
                                            allMedias: medias, index: index)
                            .frame(width: 64, height: 64)
                            .overlay(alignment: .bottomTrailing) {
                                // 视频/GIF 角标：静态缩略图看不出是视频
                                if media.type == .video || media.type == .gif {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(.black.opacity(0.55), in: Circle())
                                        .padding(3)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                // 第 4 张且有更多时，角标出剩余数量
                                if index == 3, medias.count > 4 {
                                    Text("+\(medias.count - 4)")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.black.opacity(0.6), in: Capsule())
                                        .padding(2)
                                }
                            }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// 单张评论缩略图 + 自己的 hover 按钮。
///
/// 角标（视频/剩余数量）由外层叠加，避免这里同时管装饰与交互。
private struct ReplyMediaThumbCell: View {
    let post: TwitterPost
    let media: TwitterMedia
    let decodePixelSize: Int
    /// 该评论的全部媒体（查看窗口的切换范围）
    let allMedias: [TwitterMedia]
    let index: Int

    @State private var hovering = false

    var body: some View {
        ReplyMediaThumb(media: media, decodePixelSize: decodePixelSize)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .overlay(alignment: .center) {
                if hovering {
                    MediaCardActions(post: post, media: media, buttonSize: 26) {
                        // 范围 = 本评论的媒体，从被点的这张开始
                        MediaViewerCenter.shared.open(medias: allMedias, index: index,
                                                      post: post, origin: .reply)
                    }
                }
            }
    }
}

// MARK: - 动作

    private func toggleLike() {
        liked.toggle()
        // 本地的点赞状态已变，缓存里的计数过时了：丢弃该条，
        // 否则下次打开这条推文会看到旧的 liked/favoriteCount
        TweetDetailCache.shared.invalidate(post.id)
        Task {
            do {
                if liked { try await TwitterAPI.shared.favoriteTweet(id: post.id) }
                else { try await TwitterAPI.shared.unfavoriteTweet(id: post.id) }
            } catch { liked.toggle(); actionMessage = L("操作失败：") + error.localizedDescription }
        }
    }

    private func toggleRetweet() {
        retweeted.toggle()
        TweetDetailCache.shared.invalidate(post.id)
        Task {
            do {
                if retweeted { try await TwitterAPI.shared.createRetweet(id: post.id) }
                else { try await TwitterAPI.shared.deleteRetweet(id: post.id) }
            } catch { retweeted.toggle(); actionMessage = L("操作失败：") + error.localizedDescription }
        }
    }

    private func toggleBookmark() {
        bookmarked.toggle()
        TweetDetailCache.shared.invalidate(post.id)
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

        // 先查短期缓存：浮层内跳转（点引用推文、返回）会按推文 ID 重建视图，
        // 重建即重跑本方法。回看刚看过的推文不该再打一次 TweetDetail —— 见 `TweetDetailCache`。
        if let hit = TweetDetailCache.shared.get(post.id) {
            detail = hit.focal
            resyncMediaIndex(from: post.medias, to: hit.focal.medias)
            liked = hit.focal.favorited ?? false
            retweeted = hit.focal.retweeted ?? false
            replies = hit.replies
            return
        }

        do {
            // **一次** TweetDetail 拿到 focal + 评论树（分别取会把同一请求打两遍，白耗配额）
            let (full, nodes) = try await TwitterAPI.shared.getTweetDetailTree(id: post.id)
            detail = full
            // 详情返回的媒体集合可能与列表里的不一致（数量/顺序），按媒体 id 重新定位当前索引，
            // 否则页码错乱或停在越界位置
            resyncMediaIndex(from: post.medias, to: full.medias)
            liked = full.favorited ?? false
            retweeted = full.retweeted ?? false
            replies = nodes
            TweetDetailCache.shared.put(post.id, focal: full, replies: nodes)
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

/// 评论里的单张媒体缩略图。
///
/// 与媒体网格同样的做法：URL 加 `?name=small`（实际约 680px 宽，不是 120px），
/// 再由 `ImageCache` 在后台线程**按目标尺寸降采样解码**并做磁盘/内存双缓存。
/// 评论可能一次显示几十条，走缓存后滚动时零重复解码。
///
/// 只负责取图与裁形，**尺寸与比例由调用方决定**（单张保比例、多张方格）。
struct ReplyMediaThumb: View {
    let media: TwitterMedia
    /// 解码降采样的最大边长（由展示尺寸决定，避免按原图解码）
    var decodePixelSize: Int = 240
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary.opacity(0.4))
                    .overlay {
                        Image(systemName: media.type == .photo ? "photo" : "video.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(L("评论附带的媒体"))
        .task(id: media.id) {
            guard image == nil, let urlString = Self.thumbnailURL(for: media) else { return }
            image = await ImageCache.shared.image(for: urlString,
                                                 category: .mediaThumbnails,
                                                 maxPixelSize: decodePixelSize)
        }
    }

    /// 缩略图 URL：图片加 `name=small`；视频封面路径不带 /media/，原样使用
    static func thumbnailURL(for media: TwitterMedia) -> String? {
        guard let raw = media.url, let url = URL(string: raw) else { return nil }
        guard url.path.contains("/media/"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return raw }
        var items = comps.queryItems?.filter { $0.name != "name" } ?? []
        items.append(URLQueryItem(name: "name", value: "small"))
        comps.queryItems = items
        return comps.url?.absoluteString ?? raw
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
