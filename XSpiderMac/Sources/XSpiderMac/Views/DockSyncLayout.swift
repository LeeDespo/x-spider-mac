import SwiftUI

/// 仿 Dock 布局（同步页默认布局）：
/// - 居中弧形网格（类 dock 栏）：中心大（150%），向两侧阶梯变小，第 3 个位置 100%
/// - 中心 = 正在同步（或第一个待同步）的用户头像；右侧 = 待同步；左侧 = 已完成/失败
/// - 远离中心透明度加速上升 + 模糊：第 5 个 20% 透明度并模糊，再远快速消失
/// - 待同步点击 → 同步清单；同步中不可点击；完成头像快速移到左侧（带动画）
/// - 全部完成无失败：中心浮现打勾；有失败：失败头像从右侧弹出，点击打开失败清单
struct DockSyncLayout: View {
    @State private var store = SyncStore.shared
    @State private var settingsStore = SettingsStore.shared
    @State private var showListSheet = false
    @State private var showFailureSheet = false
    /// 视觉排序：completed 在左、当前/待同步在右（动画驱动的是位置变化）
    private var ordering: [String] {
        let done = store.users.filter { store.completedUsers.contains($0.screenName) }
        let rest = store.users.filter { !store.completedUsers.contains($0.screenName) }
        return (done + rest).map(\.screenName)
    }

    private var centerIndex: Int {
        ordering.firstIndex(where: { $0 == store.currentUser }) ?? min(0, ordering.count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                ForEach(Array(ordering.enumerated()), id: \.element) { idx, sn in
                    dockItem(screenName: sn, index: idx, viewport: geo.size)
                }
                // 全部完成 + 无失败：中心纯色打勾（无背景）
                if store.phase == .done && !store.hasFailures && !store.users.isEmpty {
                    Image(systemName: "checkmark")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(Color.green)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .position(x: geo.size.width / 2, y: arcY(0, h: h))
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

    // MARK: - 弧形几何

    /// 弧线 y 偏移：中心最低（dock 弧），越靠边越高
    private func arcY(_ offsetIndex: Int, h: CGFloat) -> CGFloat {
        h * 0.62 + CGFloat(abs(offsetIndex)) * CGFloat(abs(offsetIndex)) * 2.2
    }

    /// 水平间距：中心密、边缘疏（dock 观感）
    private func xStep(_ offsetIndex: Int) -> CGFloat {
        74 + CGFloat(abs(offsetIndex)) * 7
    }

    private func xFor(index: Int, center: Int, w: CGFloat) -> CGFloat {
        let off = index - center
        guard off != 0 else { return w / 2 }  // 中心：直接返回中点（1...0 空区间会 trap）
        var x = w / 2
        let dir: CGFloat = off > 0 ? 1 : -1
        for step in 1...abs(off) {
            x += dir * xStep(step - 1) + dir * CGFloat(step > 1 ? 6 : 0)
        }
        return x
    }

    // MARK: - 单项

    private func dockItem(screenName: String, index: Int, viewport: CGSize) -> some View {
        let center = centerIndex
        let off = index - center
        let absOff = abs(off)
        let base: CGFloat = 68

        return Group {
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
                    .position(x: xFor(index: index, center: center, w: viewport.width),
                              y: arcY(off, h: viewport.height))
                    .onTapGesture {
                        if isFailed && store.phase == .done { showFailureSheet = true }
                    }
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
