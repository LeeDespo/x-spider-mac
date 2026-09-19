import SwiftUI
import AppKit
import AVKit

/// 媒体查看窗口中枢：以独立 `NSWindow` 打开（不是 sheet）——
/// 需求是"可详细查看媒体、带一系列工具按钮"，独立窗口才能自由缩放/移动、
/// 也不遮住背后的列表（用户可以对照浏览）。
///
/// ## 为什么用 NSWindow 而不是 SwiftUI `.sheet`
///
/// 1. 查看大图时用户往往想同时看到背后的列表（对照、继续挑），sheet 会锁住父窗口；
/// 2. 图片缩放/旋转需要窗口级手势与工具栏，独立窗口语义更自然；
/// 3. 详情卡本身就是一个全窗浮层，再叠 sheet 会出现"层中层"，层级与 ESC 处理复杂。
@MainActor
@Observable
final class MediaViewerCenter {
    static let shared = MediaViewerCenter()

    /// 当前查看的会话（窗口关闭时清空）
    private(set) var session: Session?

    /// 窗口关闭时由控制器调用（`private(set)` 不允许外部直接写）
    func clearSessionForWindowClose() {
        session = nil
    }

    /// 一次查看会话：媒体列表 + 当前索引 + 来源。
    ///
    /// `来源` 决定"切换媒体"的范围——需求明确要求区分：
    /// 详情页切的是**本推文内**的媒体；瀑布流切的是**整个瀑布流**的媒体。
    struct Session {
        var medias: [TwitterMedia]
        var index: Int
        var origin: Origin
        /// 帖子（下载需要：目标目录与文件名模板都依赖 post）
        var post: TwitterPost?
    }

    enum Origin: String, Sendable {
        case detail      // 推文详情（切换范围 = 本条推文）
        case waterfall   // 主页媒体瀑布流（切换范围 = 瀑布流已加载的媒体）
        case userGrid    // 搜索用户的媒体网格
        case reply       // 评论里的媒体（切换范围 = **该条评论自己的媒体**）
    }

    /// 打开查看窗口。同一时间只保留一个（再次打开即换内容）。
    func open(medias: [TwitterMedia], index: Int, post: TwitterPost? = nil,
              origin: Origin = .detail) {
        guard !medias.isEmpty else { return }
        let clamped = min(max(0, index), medias.count - 1)
        session = Session(medias: medias, index: clamped, origin: origin, post: post)
        MediaViewerWindowController.shared.show(center: self)
    }

    /// 关闭窗口并清空会话（保存缩放/旋转状态随会话一起丢弃）
    func close() {
        session = nil
        MediaViewerWindowController.shared.hide()
    }

    // MARK: - 播放进度记忆（详情页 ↔ 查看窗口 之间继承）

    /// 媒体 URL → 已播放秒数。
    ///
    /// 需求：查看窗口里播视频要**继承详情页的进度**。
    /// 键用媒体 URL（详情页与查看窗口拿到的是同一个 CDN 地址），
    /// 这样不必在两处传递 `TwitterMedia` 对象。
    ///
    /// 只在进程内、且容量很小：它服务于"从详情页点进查看窗口"这一瞬间的衔接，
    /// 不是长期观看历史。
    private var playbackProgress: [String: Double] = [:]
    private let progressLimit = 24

    /// 记住某个媒体的播放位置
    func rememberProgress(mediaId: String, seconds: Double) {
        guard seconds > 0 else { return }
        playbackProgress[mediaId] = seconds
        if playbackProgress.count > progressLimit {
            // 简单淘汰：丢一个非当前的即可（缓存只为衔接，不要求精确 LRU）
            if let key = playbackProgress.keys.first(where: { $0 != mediaId }) {
                playbackProgress.removeValue(forKey: key)
            }
        }
    }

    /// 取该媒体的续播位置（无记录返回 0）
    func resumeTime(forMediaId mediaId: String?) -> Double {
        guard let mediaId else { return 0 }
        return playbackProgress[mediaId] ?? 0
    }

    /// 清掉某媒体的进度（播完或用户从头播放时）
    func clearProgress(mediaId: String?) {
        guard let mediaId else { return }
        playbackProgress.removeValue(forKey: mediaId)
    }

    /// 是否处于全屏（工具条据此切换图标）
    var isFullScreen: Bool {
        MediaViewerWindowController.shared.isFullScreen
    }

    /// 前后切换。越界时**收敛到边界**而不是忽略：
    /// 手势可能一次给 +1/-1，键盘长按可能给更大的步长，
    /// 直接忽略会让"按住左箭头"卡在半路（实测 step(-10) 停在原处而非第一张）。
    func step(_ delta: Int) {
        guard var s = session, !s.medias.isEmpty else { return }
        let next = min(max(0, s.index + delta), s.medias.count - 1)
        guard next != s.index else { return }
        s.index = next
        session = s
    }

    /// 底部工具条用的文案：当前第几张 / 共几张
    var positionText: String {
        guard let s = session, !s.medias.isEmpty else { return "" }
        return "\(s.index + 1) / \(s.medias.count)"
    }
}

// MARK: - 窗口管理

/// 创建/复用查看窗口。
///
/// `NSWindow` 用 `.titled + .closable + .resizable`：用户能自由拖动与缩放，
/// 关闭即结束会话（`windowWillClose` 里清 session）。
@MainActor
final class MediaViewerWindowController: NSObject, NSWindowDelegate {
    static let shared = MediaViewerWindowController()

    private var window: NSWindow?
    /// 标题栏上的手势提示（常驻，不再用悬停——悬停会遮挡画面）
    private var hintLabel: NSTextField?

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func show(center: MediaViewerCenter) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: MediaViewerView(center: center))
        let w = NSWindow(contentViewController: hosting)
        w.title = L("查看媒体")
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 900, height: 660))
        w.minSize = NSSize(width: 520, height: 400)
        w.delegate = self
        w.center()
        w.isReleasedWhenClosed = false
        // 全屏按钮已进工具条，但仍保留系统绿灯全屏能力
        w.collectionBehavior.insert(.fullScreenPrimary)
        attachGestureHint(to: w)
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// 把手势提示挂在**窗口标题之后**（accessory view），常驻显示。
    ///
    /// 需求：提示要在标题后一直显示、且悬停时不再弹提示。
    /// 用 `NSTitlebarAccessoryViewController` 是最贴合的位置——
    /// 它属于窗口 chrome，不占用媒体区域、也不会遮挡画面。
    private func attachGestureHint(to window: NSWindow) {
        let label = NSTextField(labelWithString: L("双指左右滑切换 · 捏合缩放 · ←/→ 切换 · 空格播放"))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = label
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        hintLabel = label
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    func hide() {
        // 退出全屏再隐藏，否则下次打开会以全屏状态出现
        if isFullScreen { window?.toggleFullScreen(nil) }
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭窗口 = 结束会话：清掉 index/缩放状态，下次打开是干净的
        MediaViewerCenter.shared.clearSessionForWindowClose()
    }
}
