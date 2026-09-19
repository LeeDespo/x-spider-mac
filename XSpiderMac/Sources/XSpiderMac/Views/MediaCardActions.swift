import SwiftUI

/// 媒体卡 hover 操作（下载 / 详细查看）——搜索用户网格、主页瀑布流、评论缩略图
/// **共用同一实现**。
///
/// 抽出来的原因：三处都要"按已下载状态切换按钮"（判定依据跟随设置），
/// 各写一份必然漂移——之前瀑布流就没有下载按钮，正是这种漂移的结果。
///
/// 下载态判定读 `judgementVersion` 建立观察依赖：判定依据/保存路径变化后
/// 记录缓存会变，但 SwiftUI 追踪不到 static 缓存，不读它按钮会停在旧结果。
struct MediaCardActions: View {
    let post: TwitterPost
    let media: TwitterMedia
    /// 按钮直径。网格卡片用 36；评论缩略图只有 64pt，用 26 才放得下两个
    var buttonSize: CGFloat = 36
    /// 点击放大镜 → 由调用方决定"切换范围"（本推文 / 整个列表 / 该评论的媒体）
    var onOpenViewer: () -> Void

    private var iconSize: CGFloat { buttonSize <= 30 ? 11 : 14 }
    private var spacing: CGFloat { buttonSize <= 30 ? 6 : 10 }

    var body: some View {
        let _ = DownloadStore.shared.judgementVersion
        let dir = DownloadStore.shared.targetDir(for: post)
        HStack(spacing: spacing) {
            if DownloadStore.shared.hasDownloaded(media: media, dir: dir, post: post) {
                iconBadge()
            } else {
                roundIconButton("arrow.down", help: L("下载")) {
                    Task { await DownloadStore.shared.createDownloadTask(post: post, media: media) }
                }
            }
            roundIconButton("magnifyingglass", help: L("详细查看")) { onOpenViewer() }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    /// 已下载：绿色圆 + 白勾，不可点（点它没有意义——重复下载会被判定跳过）
    private func iconBadge() -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: buttonSize, height: buttonSize)
            .background(Color.green.opacity(0.85), in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1) }
            .help(L("该媒体已下载过"))
    }

    private func roundIconButton(_ system: String, help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: buttonSize, height: buttonSize)
                .background(.black.opacity(0.45), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
