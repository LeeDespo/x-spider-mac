import SwiftUI

/// 同步页：watchOS 式头像圈选要同步的用户，底部居中「立即同步」。
struct SyncView: View {
    @State private var store = SyncStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if store.candidateUsers.isEmpty {
                emptyState
            } else {
                avatarCloud
                Spacer(minLength: 24)
                syncButton
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("同步"))
        // 底部留白：避免悬浮下载条遮挡
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 72)
        }
    }

    // MARK: - 头像云（watchOS 表盘布局：多行环形排列，越居中行越长）

    private var avatarCloud: some View {
        ScrollView {
            FlowLayout(spacing: 18) {
                ForEach(store.candidateUsers) { user in
                    AvatarPickCell(
                        user: user,
                        isSelected: store.selected.contains(user.screenName),
                        progress: store.progress.first { $0.screenName == user.screenName }
                    ) {
                        store.toggle(user)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.crop.square.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(L("暂无可同步的用户"))
                .font(.headline)
            Text(L("先在主页浏览或下载过用户媒体，再回到这里同步。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var syncButton: some View {
        VStack(spacing: 8) {
            Button {
                Task { await store.startSync() }
            } label: {
                HStack(spacing: 8) {
                    if store.running {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(store.running ? L("同步中…") : L("立即同步"))
                        .font(.headline)
                }
                .frame(minWidth: 160)
                .padding(.vertical, 8)
            }
            .compatGlassProminentButton()
            .disabled(store.selected.isEmpty || store.running)

            if !store.selected.isEmpty, !store.running {
                Text(L("已选择 ") + "\(store.selected.count)" + L(" 个用户"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 单个头像单元

private struct AvatarPickCell: View {
    let user: SyncStore.TargetUser
    let isSelected: Bool
    let progress: SyncStore.UserProgress?
    let onTap: () -> Void

    @State private var hovering = false

    private var ringColor: Color {
        switch progress?.status {
        case .loading: return .accentColor
        case .done: return .green
        case .failed: return .red
        default: return isSelected ? Color.accentColor : Color.clear
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    CachedAvatarView(urlString: user.avatar, size: 56)

                    if progress?.status == .loading {
                        ProgressView()
                            .controlSize(.regular)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 20, y: -20)
                    }
                }
                .frame(width: 60, height: 60)
                .background(Circle().strokeBorder(ringColor, lineWidth: isSelected || progress != nil ? 2.5 : 1))

                Text(user.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 76)

                if let progress, let message = progress.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(progress.status == .failed ? .red : .secondary)
                        .lineLimit(1)
                        .frame(width: 96)
                }
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear))
            }
            .scaleEffect(hovering ? 1.04 : 1)
            .animation(.spring(duration: 0.2), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("@\(user.screenName)")
    }
}

// MARK: - 流式布局（自动换行的头像云）

struct FlowLayout: Layout {
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
