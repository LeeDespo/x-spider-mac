import SwiftUI
import AVKit

/// 媒体查看窗口内容：图片可缩放/旋转，视频可播放控制，两者都能切换上下一个媒体。
///
/// ## 布局原则（需求：按钮不要遮挡媒体）
///
/// 媒体占据中央区域，**全部控件都在底部独立一条**（不浮在媒体上）。
/// 视频**不用 AVPlayerView 自带的控制条**（`.floating` 会浮在画面上遮挡内容，
/// 且此前被上层的手势层挡住导致点不动）——播放/进度/倍速/字幕/全屏全在底栏。
/// 切换按钮分列左右两侧空白区。工具栏**只用图标**（配 `.help` 提示），不放文字。
///
/// ## 手势（图片与视频**共用**）
///
/// - 双指左右滑切换媒体（两种媒体都有，见 `ScrollWheelCatcher`）；
/// - 图片另有：双指捏合缩放、拖动平移、双击还原/放大；
/// - 键盘：←/→ 切换，空格播放暂停，⌘+ / ⌘- / ⌘0 缩放。
///
/// 手势提示**常驻在标题旁**（由 `MediaViewerWindowController` 注入窗口标题的
/// accessory view），不再做成悬停提示——悬停弹出会遮挡画面。
struct MediaViewerView: View {
    let center: MediaViewerCenter
    @State private var store = DownloadStore.shared
    @State private var playback = VideoPlaybackModel()

    /// 图片显示状态（切换媒体时重置）
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var rotation: Angle = .zero
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var session: MediaViewerCenter.Session? { center.session }
    private var media: TwitterMedia? {
        guard let s = session, s.medias.indices.contains(s.index) else { return nil }
        return s.medias[s.index]
    }
    private var isVideo: Bool {
        guard let t = media?.type else { return false }
        return t == .video || t == .gif
    }

    var body: some View {
        VStack(spacing: 0) {
            // 媒体区：控件全在下方工具条，画面无任何覆盖物
            ZStack {
                Color.black
                if let media {
                    if isVideo {
                        VideoStage(player: playback.player)
                            // 点画面播放/暂停：用 tap 手势而不是盖一层 Color.clear
                            // （后者会吃掉播放器与上层按钮的点击，是"按钮点不动"的根因）
                            .onTapGesture { playback.togglePlay() }
                            // 视频也支持双指捏合缩放（需求：把图片的手势也给视频）
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scale = min(max(0.5, lastScale * value), 4)
                                    }
                                    .onEnded { _ in lastScale = scale }
                            )
                            .scaleEffect(scale)
                    } else {
                        imageStage(media)
                    }
                } else {
                    ProgressView()
                }

                // 左右切换按钮：贴在两侧，半透明圆钮（压在画面边缘的空白处，不挡内容中心）
                if let s = session, s.medias.count > 1 {
                    HStack {
                        switchButton("chevron.left", enabled: s.index > 0) { step(-1) }
                        Spacer()
                        switchButton("chevron.right", enabled: s.index < s.medias.count - 1) { step(1) }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // 触控板双指左右滑切换媒体（复用已有监视器实现，含惯性判定）
            .background {
                ScrollWheelCatcher { direction in step(direction) }
            }

            Divider()
            toolbar
        }
        .frame(minWidth: 520, minHeight: 400)
        .background { keyboardShortcuts }
        .task(id: media?.id) {
            resetImageTransform()
            await loadPlaybackIfNeeded()
        }
        .onDisappear {
            // 离开查看窗口：暂停播放（详情页若在播，由详情页自己恢复）
            playback.teardown()
        }
    }

    // MARK: - 图片

    private func imageStage(_ media: TwitterMedia) -> some View {
        ZoomableImage(urlString: Self.largeURL(for: media),
                      scale: $scale, rotation: $rotation,
                      offset: $offset, lastOffset: $lastOffset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        // 以手势开始时的倍率为基准，避免累积误差
                        scale = min(max(0.2, lastScale * value), 12)
                    }
                    .onEnded { _ in lastScale = scale }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.25)) {
                    if scale > 1.01 { resetImageTransform() }
                    else { scale = 3; lastScale = 3 }
                }
            }
    }

    /// 复位缩放/旋转/平移
    private func resetImageTransform() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            lastScale = 1
            rotation = .zero
            offset = .zero
            lastOffset = .zero
        }
    }

    // MARK: - 视频

    private func loadPlaybackIfNeeded() async {
        guard let media, isVideo, let url = Self.bestVideoURL(media) else {
            playback.teardown()
            return
        }
        // 继承详情页的播放进度：同一条媒体在详情页播到哪，这里就从哪继续（需求）。
        // 键必须与详情页写入时一致——两处都用**视频 URL**（详情页只有 AVPlayer，
        // 拿 media.id 得额外传递；URL 两边都有，是唯一自然可对齐的键）。
        let resumeAt = MediaViewerCenter.shared.resumeTime(forMediaId: url.absoluteString)
        playback.load(url: url, resumeAt: resumeAt)
    }

    // MARK: - 工具条（纯图标；视频的播放控制全在这里）

    private var toolbar: some View {
        HStack(spacing: 12) {
            if isVideo {
                iconButton("arrow.counterclockwise", help: L("回到开头")) { playback.restart() }
                iconButton(playback.isPlaying ? "pause.fill" : "play.fill",
                           help: playback.isPlaying ? L("暂停") : L("播放")) { playback.togglePlay() }

                // 播放进度：**只读展示**，不提供拖动。
                //
                // 原先这里是可拖动的 Slider，但拖动/点击它需要水平拖拽与点击，
                // 与「双指左右滑切换媒体」「←/→ 切换」互相打架（用户反馈冲突）。
                // 需求明确要求关掉调进度的手势与快捷键，故改为纯展示的进度条。
                ProgressView(value: min(playback.currentTime, max(playback.duration, 0.01)),
                             total: max(playback.duration, 0.01))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(minWidth: 100)

                Text("\(Self.timeText(playback.currentTime)) / \(Self.timeText(playback.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                // 倍速：图标换成 `speedometer`（原 `goforward` 与「复位」的
                // `arrow.counterclockwise` 都是圆弧箭头，肉眼难分——用户反馈）
                iconButton("speedometer", help: L("加速")) { playback.cycleRate() }
                Text(String(format: "%.1fx", playback.rate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
            } else {
                iconButton("minus.magnifyingglass", help: L("缩小")) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        scale = max(0.2, scale - 0.25); lastScale = scale
                    }
                }
                iconButton("plus.magnifyingglass", help: L("放大")) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        scale = min(12, scale + 0.25); lastScale = scale
                    }
                }
                iconButton("arrow.counterclockwise", help: L("恢复原大小")) { resetImageTransform() }
                iconButton("rotate.right", help: L("向右旋转 90°")) {
                    withAnimation(.easeOut(duration: 0.2)) { rotation += .degrees(90) }
                }
                iconButton("rotate.left", help: L("向左旋转 90°")) {
                    withAnimation(.easeOut(duration: 0.2)) { rotation -= .degrees(90) }
                }
                Text(String(format: "%.0f%%", scale * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
            }

            Spacer()

            Text(center.positionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            // 下载当前（已下载则显示勾，且禁用——与各处媒体卡一致）
            if let media {
                let _ = store.judgementVersion
                let dir = store.targetDir(for: session?.post)
                if store.hasDownloaded(media: media, dir: dir, post: session?.post) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.green)
                        .help(L("该媒体已下载过"))
                } else {
                    iconButton("arrow.down.circle", help: L("下载当前")) {
                        Task {
                            if let post = session?.post {
                                _ = await store.createDownloadTask(post: post, media: media)
                            }
                        }
                    }
                }
            }

            // 全屏：窗口进/出系统全屏
            iconButton(center.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: center.isFullScreen ? L("退出全屏") : L("全屏")) {
                MediaViewerWindowController.shared.toggleFullScreen()
            }

            iconButton("xmark", help: L("关闭")) { center.close() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func step(_ delta: Int) {
        resetImageTransform()
        center.step(delta)
    }

    @ViewBuilder
    private func iconButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 左右切换圆钮（半透明底，白图标）
    private func switchButton(_ system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(enabled ? 0.45 : 0.15), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(system.contains("left") ? L("上一个媒体") : L("下一个媒体"))
    }

    /// 键盘快捷键：←/→ 切换，空格播放暂停，⌘+ / ⌘- / ⌘0 缩放
    @ViewBuilder
    private var keyboardShortcuts: some View {
        Group {
            Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { if isVideo { playback.togglePlay() } }.keyboardShortcut(.space, modifiers: [])
            Button("") { scale = min(12, scale + 0.25); lastScale = scale }
                .keyboardShortcut("+", modifiers: .command)
            Button("") { scale = max(0.2, scale - 0.25); lastScale = scale }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { resetImageTransform() }.keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: - URL / 格式化

    /// 大图 URL：优先 `name=large`（比 orig 稳，orig 偶发 404）
    static func largeURL(for media: TwitterMedia) -> String? {
        guard let raw = media.url, let url = URL(string: raw) else { return nil }
        guard url.path.contains("/media/"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return raw }
        var items = comps.queryItems?.filter { $0.name != "name" } ?? []
        items.append(URLQueryItem(name: "name", value: "large"))
        comps.queryItems = items
        return comps.url?.absoluteString ?? raw
    }

    /// 最佳视频地址（最高码率 mp4）；GIF 用 videoInfo.url
    static func bestVideoURL(_ media: TwitterMedia) -> URL? {
        if media.type == .gif, let s = media.videoInfo?.url, let u = URL(string: s) { return u }
        return media.videoInfo?.variants?
            .filter { $0.contentType?.contains("mp4") == true && $0.url != nil }
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            .flatMap { URL(string: $0.url!) }
    }

    /// 秒 → "m:ss"
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 视频播放状态

/// 视频播放状态与进度观察。
///
/// 单独成 `@MainActor @Observable` 类（而不是散在视图的 `@State`）的原因：
/// `addPeriodicTimeObserver` 的闭包是 `@Sendable`，在 Swift 6 严格并发下
/// 无法直接写入视图的 `@State`（会报跨隔离域写入）。状态收进 MainActor 类后，
/// 闭包里只用 `MainActor.assumeIsolated`（回调已保证在主队列）。
@MainActor
@Observable
final class VideoPlaybackModel {
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var rate: Float = 1.0

    private var timeObserver: Any?

    /// - Parameter resumeAt: 起始播放位置（秒）。用于从详情页继承进度（需求）。
    func load(url: URL, resumeAt: Double = 0) {
        teardown()
        let p = AVPlayer(url: url)
        p.rate = rate
        player = p
        currentTime = resumeAt
        duration = 0

        if resumeAt > 0 {
            p.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        }

        // 时长异步读取（同步访问 AVAsset.duration 已废弃）
        if let item = p.currentItem {
            Task { [weak self] in
                let d = try? await item.asset.load(.duration)
                let seconds = d?.seconds ?? 0
                self?.duration = (seconds.isFinite && seconds > 0) ? seconds : 0
            }
        }

        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // 回调已在主队列：直接断言隔离域，避免每 0.25s 起一个 Task
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = time.seconds
                self.currentTime = (s.isFinite && s >= 0) ? s : 0
                // 记住进度：详情页与查看窗口之间切换时可继承（需求）
                if let url = (self.player?.currentItem?.asset as? AVURLAsset)?.url {
                    MediaViewerCenter.shared.rememberProgress(mediaId: url.absoluteString,
                                                              seconds: self.currentTime)
                }
            }
        }
        play()
    }

    func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func play() {
        player?.rate = rate
        player?.play()
        isPlaying = true
    }

    func restart() {
        player?.seek(to: .zero)
        currentTime = 0
        play()
    }

    /// 0.5 → 1 → 1.5 → 2 → 0.5 循环
    func cycleRate() {
        let options: [Float] = [0.5, 1.0, 1.5, 2.0]
        let idx = options.firstIndex(of: rate) ?? 1
        rate = options[(idx + 1) % options.count]
        player?.rate = rate
    }

}

// MARK: - 可缩放图片

/// 图片展示：按窗口尺寸适应，支持缩放/旋转/拖动平移。
///
/// 用 `scaleEffect` + `rotationEffect` + `offset`，而不是改 frame：
/// 前者不触发布局重算，拖动时不会被布局回弹。
struct ZoomableImage: View {
    let urlString: String?
    @Binding var scale: CGFloat
    @Binding var rotation: Angle
    @Binding var offset: CGSize
    @Binding var lastOffset: CGSize

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .rotationEffect(rotation)
                    .offset(offset)
                    // 拖动平移：只在放大后有意义，未放大时拖动不生效（避免整图被拖出视野）
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1.01 else { return }
                                offset = CGSize(width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(L("图片加载失败"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: urlString) {
            failed = false
            image = nil
            guard let urlString else { failed = true; return }
            // 大图按 4096 降采样：够清晰又能显著降内存（原图可达数千像素）
            let loaded = await ImageCache.shared.image(for: urlString,
                                                       category: .mediaThumbnails,
                                                       maxPixelSize: 4096)
            image = loaded
            failed = loaded == nil
        }
    }
}

// MARK: - 视频舞台

/// AVPlayerView 包装。
///
/// **`controlsStyle = .none`**：自带的控制条会浮在画面上遮挡内容，
/// 需求是把播放控制全做进底栏（见 `MediaViewerView.toolbar`）。
/// 早先还叠了一层 `Color.clear` 做点击播放，它把播放器控制条的点击全吃掉了
/// ——"按钮无法点击"就是这么来的，现已移除。
struct VideoStage: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
