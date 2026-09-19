import SwiftUI

/// 媒体卡右上角的类型标签（视频 / GIF）。
///
/// ## 为什么需要
///
/// 需求：媒体卡上要能一眼看出"这是视频，不是图片"。
/// 缩略图是**静态封面帧**，与普通图片长得一样；只有底部的时长角标不足以区分
/// （GIF 甚至没有时长）。所以在**右上角**放一个明确的类型标签。
///
/// **图片不加标签**（需求）：图片是默认预期，加标签只会造成噪声。
///
/// 三处媒体卡共用（搜索网格 / 主页瀑布流 / 推文卡内的媒体行），
/// 避免各写一份导致样式漂移——与 `MediaCardActions` 同样的理由。
struct MediaTypeBadge: View {
    let type: MediaType
    /// 紧凑尺寸用于小图（推文卡内的媒体行 / 评论缩略图）
    var compact: Bool = false

    var body: some View {
        // 图片不显示标签
        if type != .photo {
            HStack(spacing: 3) {
                Image(systemName: type == .gif ? "sparkles" : "video.fill")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                Text(type == .gif ? "GIF" : L("视频"))
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(.black.opacity(0.6), in: Capsule())
            .help(type == .gif ? L("动图") : L("视频"))
        }
    }
}

extension View {
    /// 在媒体卡右上角叠加类型标签（视频/GIF 才显示）
    func mediaTypeBadge(_ type: MediaType, compact: Bool = false, padding: CGFloat = 6) -> some View {
        overlay(alignment: .topTrailing) {
            MediaTypeBadge(type: type, compact: compact)
                .padding(padding)
        }
    }
}
