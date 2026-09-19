import SwiftUI
import AVKit

/// 媒体查看窗口内容：图片可缩放/旋转，视频可播放控制，两者都能切换上下一个媒体。
///
/// ## 布局原则（需求：按钮不要遮挡媒体）
///
/// 媒体占据中央区域，**工具条在底部独立一条**（不浮在图上）。
/// 切换按钮分列左右两侧空白区，也不压住画面。
/// 工具栏**只用图标**（配 `.help` 提示），不放文字。
///
/// ## 手势
///
/// - 图片：双指捏合缩放（`MagnificationGesture`）、拖动平移、双指左右滑切换；
/// - 视频：左右滑切换、空格播放/暂停；
/// - 两者：←/→ 切换，`⌘+`/`⌘-` 缩放，`⌘0` 复位（键盘快捷键见 body 的隐藏按钮）。
struct MediaViewerView: View {
    let center: MediaViewerCenter
    @State private var store = DownloadStore.shared

    /// 图片显示状态（每个媒体独立会被重置：切换时清空）
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var rotation: Angle = .zero
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// 视频播放器
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var rate: Float = 1.0

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
            // 媒体区：zIndex 无关，工具条在下方独立一条，保证不遮挡
            ZStack {
                Color.black
                if let media {
                    if isVideo {
                        videoStage(media)
                    } else {
                        imageStage(media)
                    }
                } else {
                    ProgressView()
                }

                // 左右切换按钮：贴在两侧，半透明圆钮（不压画面中央）
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
            await loadPlayerIfNeeded()
        }
        .onDisappear { player?.pause() }
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
                // 双击：在「适应窗口」与「放大 3 倍」之间切换
                withAnimation(.spring(duration: 0.25)) {
                    if scale > 1.01 { resetImageTransform() }
                    else { scale = 3; lastScale = 3 }
                }
            }
            .help(L("双指捏合缩放，拖动平移，双击放大/复位"))
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

    private func videoStage(_ media: TwitterMedia) -> some View {
        VideoStage(player: player)
            .overlay(alignment: .bottom) {
                // 点击视频本身播放/暂停
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlay() }
            }
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    private func loadPlayerIfNeeded() async {
        guard let media, isVideo else {
            player?.pause()
            player = nil
            return
        }
        guard let url = Self.bestVideoURL(media) else { return }
        let p = AVPlayer(url: url)
        p.rate = rate
        p.play()
        player = p
        isPlaying = true
    }

    // MARK: - 工具条（纯图标，不遮挡媒体）

    private var toolbar: some View {
        HStack(spacing: 14) {
            if isVideo {
                iconButton("arrow.counterclockwise", help: L("回到开头")) {
                    player?.seek(to: .zero)
                    player?.play()
                    isPlaying = true
                }
                iconButton(isPlaying ? "pause.fill" : "play.fill",
                           help: isPlaying ? L("暂停") : L("播放")) { togglePlay() }
                iconButton("goforward", help: L("加速")) { cycleRate() }
                rateText
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
                zoomText
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

            iconButton("xmark", help: L("关闭")) { center.close() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var zoomText: some View {
        Text(String(format: "%.0f%%", scale * 100))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 46, alignment: .leading)
    }

    private var rateText: some View {
        Text(String(format: "%.1fx", rate))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 46, alignment: .leading)
    }

    /// 0.5 → 1 → 1.5 → 2 → 0.5 循环
    private func cycleRate() {
        let options: [Float] = [0.5, 1.0, 1.5, 2.0]
        let idx = options.firstIndex(of: rate) ?? 1
        rate = options[(idx + 1) % options.count]
        player?.rate = rate
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
            Button("") { if isVideo { togglePlay() } }.keyboardShortcut(.space, modifiers: [])
            Button("") { scale = min(12, scale + 0.25); lastScale = scale }
                .keyboardShortcut("+", modifiers: .command)
            Button("") { scale = max(0.2, scale - 0.25); lastScale = scale }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { resetImageTransform() }.keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: - URL

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
                    .onTapGesture(count: 2) {}
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

/// AVPlayerView 包装：查看窗口里用 AppKit 播放器（SwiftUI VideoPlayer 在独立窗口同样有崩溃史）。
struct VideoStage: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating   // 悬浮控制条：不占固定高度，也不遮挡画面主体
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
