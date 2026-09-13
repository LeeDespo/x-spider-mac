import SwiftUI

/// 仿 Dock 布局（同步页默认布局）：
/// - 头像中心处于同一条水平直线（不做弧形）；固定间距 84pt（最大头像 102pt 也不重叠）
/// - 大小阶梯：中心 150% → 一号位 128% → 二号位 112% → 三号位及以外 100%
/// - 中心 = 正在同步（或第一个待同步）的用户；右侧 = 待同步；左侧 = 已完成/失败
/// - 远离中心透明度加速上升 + 模糊：第 5 个约 20% 并开始模糊，再远快速消失；反向渐清晰
/// - 行整体悬在同步状态卡上方（y 由 SyncView 传入）
/// - 未同步点击 → 同步清单；同步中不可点击；完成头像带动画移到左侧消失
/// - 全部完成无失败：中心浮现纯色打勾；重新同步时打勾淡出、头像从右侧回出
/// - 有失败：失败头像从右侧快速弹出（红描边），点击打开失败清单（忽略/重试）
struct DockSyncLayout: View {
    @State private var store = SyncStore.shared
    @State private var showListSheet = false
    @State private var showFailureSheet = false
    /// 头像行的 y 坐标（由 SyncView 计算：状态卡上方）
    var y: CGFloat

    /// 视觉排序：completed 在左、当前/待同步在右（动画驱动的是位置变化）
    private var ordering: [String] {
        let done = store.users.filter { store.completedUsers.contains($0.screenName) }
        let rest = store.users.filter { !store.completedUsers.contains($0.screenName) }
        return (done + rest).map(\.screenName)
    }

    private var centerIndex: Int {
        ordering.firstIndex(where: { $0 == store.currentUser })
            ?? ordering.firstIndex(where: { !store.completedUsers.contains($0) })
            ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(ordering.enumerated()), id: \.element) { idx, sn in
                    dockItem(screenName: sn, index: idx, w: geo.size.width)
                }
                // 全部完成 + 无失败：中心纯色打勾（无背景，大小 = 中心头像量级）
                if store.phase == .done && !store.hasFailures && !store.users.isEmpty {
                    Image(systemName: "checkmark")
                        .font(.system(size: 72, weight: .bold))
                        .foregroundStyle(Color.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        .animation(.spring(duration: 0.45), value: store.phase)
                        .position(x: geo.size.width / 2, y: y)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if store.phase == .idle || store.phase == .done { showListSheet = true }
            }
            .sheet(isPresented: $showListSheet) { SyncListManagerSheet() }
            .sheet(isPresented: $showFailureSheet) { SyncFailureSheet() }
        }
    }

    // MARK: - 直线几何（固定间距）

    /// 固定步距：中心头像 102pt + 安全余量 → 84pt（任何相邻两档都不重叠）
    private let step: CGFloat = 84

    private func xFor(index: Int, center: Int, w: CGFloat) -> CGFloat {
        w / 2 + CGFloat(index - center) * step
    }

    // MARK: - 单项

    @ViewBuilder
    private func dockItem(screenName: String, index: Int, w: CGFloat) -> some View {
        let center = centerIndex
        let off = index - center
        let absOff = abs(off)
        let base: CGFloat = 68

        if let user = store.users.first(where: { $0.screenName == screenName }) {
            let sizeScale: CGFloat = absOff == 0 ? 1.5 : (absOff == 1 ? 1.28 : (absOff == 2 ? 1.12 : 1.0))
            let size = base * sizeScale
            // 透明度：加速上升——越远越快变透明，第 5 个约 0.2，再远快速趋 0
            let opacity: Double = absOff == 0 ? 1.0 : max(0.0, 1.02 - 0.15 * Double(absOff) * sqrt(Double(absOff)))
            let blurR: CGFloat = absOff >= 4 ? CGFloat(absOff - 3) * 2.5 : 0
            let isFailed = store.failedUsers[user.screenName] != nil
            let isDone = store.completedUsers.contains(user.screenName)

            CachedAvatarView(urlString: user.avatar, size: size)
                .clipShape(Circle())
                .overlay {
                    if user.screenName == store.currentUser && store.phase == .syncing {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-5)
                    }
                    if isFailed {
                        Circle().strokeBorder(Color.red, lineWidth: 3).padding(-5)
                    }
                    if isDone && !isFailed {
                        Circle().fill(Color.green.opacity(0.18)).padding(-5)
                    }
                }
                .opacity(opacity)
                .blur(radius: blurR)
                .scaleEffect(absOff == 0 ? 1.06 : 1.0)
                .animation(.spring(duration: 0.45, bounce: 0.2), value: store.completedUsers)
                .animation(.spring(duration: 0.45, bounce: 0.2), value: store.currentUser)
                .animation(.spring(duration: 0.4), value: store.phase)
                .position(x: xFor(index: index, center: center, w: w), y: y)
                .onTapGesture {
                    if isFailed && store.phase == .done { showFailureSheet = true }
                }
        }
    }
}

/// 同步失败清单：只显示失败用户、红字原因、右下角 忽略/重试
struct SyncFailureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = SyncStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("同步失败"))
                    .font(.headline)
                    .foregroundStyle(.red)
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.failedUserList) { user in
                        HStack(spacing: 12) {
                            CachedAvatarView(urlString: user.avatar, size: 36)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(user.name)-@\(user.screenName)")
                                    .font(.callout)
                                Text(store.failedUsers[user.screenName] ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .liquidGlass(interactive: false, cornerRadius: 12)
                    }
                }
                .padding(12)
            }

            Divider()

            HStack {
                Spacer()
                Button(L("忽略")) {
                    for u in store.failedUserList { store.ignoreFailure(u.screenName) }
                    dismiss()
                }
                Button(L("重试")) {
                    store.retryFailures()
                    dismiss()
                }
                .compatGlassProminentButton()
            }
            .padding(16)
        }
        .frame(width: 460, height: 440)
        .presentationBackground(.thinMaterial)
    }
}
