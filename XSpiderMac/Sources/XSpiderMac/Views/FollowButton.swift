import SwiftUI

/// 关注/取关按钮（推文卡作者行;已关注态点击 = 取关）
struct FollowButton: View {
    let screenName: String
    @State private var following = false
    @State private var checking = true
    @State private var busy = false

    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            let target = !following
            Task {
                defer { busy = false }
                do {
                    if target { try await TwitterAPI.shared.followUser(screenName: screenName) }
                    else { try await TwitterAPI.shared.unfollowUser(screenName: screenName) }
                    following = target
                } catch {
                    AppLogger.warn("关注操作失败", category: "HOME", ["user": screenName, "error": error.localizedDescription])
                }
            }
        } label: {
            Text(following ? L("已关注") : L("关注"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                // 强调色用在**背景**上，图案/文字用白色——
                // 而不是"淡色底 + 强调色文字"那种弱化写法：
                // 「关注」是卡片上的主操作，实心强调色才是它的视觉权重。
                // 「已关注」是中性状态（点它=取关），保持淡底灰字，不抢视线。
                .background(following ? AnyShapeStyle(.quaternary)
                                      : AnyShapeStyle(Color.accentColor),
                            in: Capsule())
                .foregroundStyle(following ? Color.secondary : Color.white)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(checking ? 0.55 : 1)
        .task {
            // 初始状态:查关系(轻量;失败默认未关注)
            following = (try? await TwitterAPI.shared.isFollowing(screenName: screenName)) ?? false
            checking = false
        }
    }
}
