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
                .background(following ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor.opacity(0.18)),
                            in: Capsule())
                .foregroundStyle(following ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(busy || checking)
        .opacity(checking ? 0.5 : 1)
        .task {
            // 初始状态:查关系(轻量;失败默认未关注)
            following = (try? await TwitterAPI.shared.isFollowing(screenName: screenName)) ?? false
            checking = false
        }
    }
}
