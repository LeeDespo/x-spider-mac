import SwiftUI

/// 内嵌的引用推文卡片（缩小版）。
///
/// 用于推文卡正文下方，展示被引用的推文。点击整卡打开**被引用推文**的详情，
/// 与点击外层卡片（打开主推文详情）区分——因此本视图自己有 `onTapGesture`，
/// 且调用方需要在它上面阻止事件冒泡（SwiftUI 中内层手势优先，无需额外处理）。
///
/// 尺寸刻意小于主卡：头像 20、正文 `.caption`、限 3 行、媒体最多 2 张，
/// 让视觉层次清晰（主推文 > 引用推文）。
struct QuotedPostCard: View {
    let post: TwitterPost
    /// 点击整卡 → 打开被引用推文的详情
    var onOpen: () -> Void
    /// 点击头像 → 搜索该用户（可空）
    var onAvatar: (() -> Void)? = nil

    @State private var hovering = false
    /// 详情浮层是否已打开。用于**让出悬停提示**：`.help` 是 AppKit 工具提示，
    /// 不受 SwiftUI 浮层遮挡影响，浮层开着时仍会从底层卡片弹出（见文件末尾注释）。
    private var overlayOpen: Bool { DetailOverlayCenter.shared.post != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 作者行：小头像 + 昵称 + @用户名 + 日期
            HStack(spacing: 6) {
                CachedAvatarView(urlString: post.user.avatar, size: 20)
                    .contentShape(Circle())
                    .onTapGesture { onAvatar?() }
                Text(post.user.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("@\(post.user.screenName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let created = post.createdAt {
                    Text(created.postDisplayText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let text = post.fullText, !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 媒体缩略：最多 2 张，避免引用卡过高
            if let medias = post.medias, !medias.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(medias.prefix(2).enumerated()), id: \.offset) { _, media in
                        CachedMediaThumbView(urlString: media.url, width: 56, height: 56, cornerRadius: 6)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .bottomTrailing) {
                                if media.type == .video || media.type == .gif {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(.black.opacity(0.55), in: Circle())
                                        .padding(3)
                                }
                            }
                    }
                    if medias.count > 2 {
                        Text("+\(medias.count - 2)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                // 浅底 + 描边：与主卡形成"内嵌"的视觉层次
                .fill(.quaternary.opacity(hovering ? 0.5 : 0.3))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture { onOpen() }
        // 悬停提示只在**没有详情浮层**时挂载。
        //
        // 原因：`.help` 是 AppKit 工具提示，由窗口级别的 tracking area 驱动，
        // **不受 SwiftUI 的 zIndex/浮层遮挡影响**。详情浮层打开时鼠标移到浮层上，
        // 底层这张引用卡仍会弹出"打开被引用的推文"提示（用户反馈）。
        // SwiftUI 层做遮罩挡不住它，只能在源头不挂这个 modifier。
        .help(overlayOpen ? "" : L("打开被引用的推文"))
        // 浮层打开时把悬停态复位，避免浮层期间卡片保持高亮
        .onChange(of: overlayOpen) { _, open in
            if open { hovering = false }
        }
    }
}
