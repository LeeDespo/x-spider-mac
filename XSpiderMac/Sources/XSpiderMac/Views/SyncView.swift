import SwiftUI

/// 同步页：watchOS 蜂窝头像布局（六边形环展开 RadialLayout，中心即首格）。
/// 近大远小按「到滚动内容中心的距离」计算——内容大于视口时滑动即切换聚焦。
/// 状态卡悬浮页面 3/4 高度、胶囊形（下载提示框同款）、左右对称伸缩；
/// 右侧外挂「新增」「同步」中性玻璃按钮。
struct SyncView: View {
    @State private var store = SyncStore.shared
    @State private var showAddSheet = false
    @State private var input = ""
    @State private var appStore = AppStore.shared
    /// 页面可视高度（3/4 定位用）
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        honeycomb
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
                // 卡片本体以页面中心为锚（水平居中、垂直 3/4），
                // 按钮组在卡片右侧外挂——整组向左补偿半个按钮组宽度，卡片中心不受按钮影响
                HStack(spacing: 8) {
                    progressBarCard
                    addButton
                    syncButton
                }
                .offset(x: -52, y: viewportHeight * 0.25)
            }
            .navigationTitle(L("同步"))
            .sheet(isPresented: $showAddSheet) { addSheet }
            .task {
                store.syncOnLaunchIfNeeded()
            }
    }

    // MARK: - 蜂窝头像（六边形环展开 + 近大远小）

    private var honeycomb: some View {
        GeometryReader { geo in
            // 蜂窝内容中心（global 坐标）——Near/far 效果的参考点
            let contentW = honeycombDiameter + 120
            let contentH = honeycombDiameter + 120
            ScrollView([.horizontal, .vertical]) {
                HoneycombLayout(step: 88, cellExtent: 84) {
                    ForEach(store.users) { user in
                        honeycombCell(user)
                    }
                }
                .frame(width: contentW, height: contentH, alignment: .center)
                .overlay {
                    // 近大远小参考点 = 蜂窝内容中心（global）
                    GeometryReader { marker -> Color in
                        let f = marker.frame(in: .global)
                        viewportCenterGlobal = CGPoint(x: f.midX, y: f.midY)
                        return Color.clear
                    }
                }
                .padding(60)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                viewportHeight = geo.size.height
            }
            .onChange(of: geo.size.height) { _, newH in viewportHeight = newH }
        }
    }

    /// 近大远小参考点（蜂窝内容中心，global 坐标，由 overlay marker 持续更新）
    @State private var viewportCenterGlobal: CGPoint = .zero

    /// 蜂窝所需直径（满环公式：环 r 的横向半径 = r*step）
    private var honeycombDiameter: CGFloat {
        let n = max(1, store.users.count)
        let rings = max(0, Int(ceil((-1.0 + (1.0 + 12.0 * Double(n)).squareRoot()) / 6.0)))
        return CGFloat(2 * rings) * 88 + 84
    }

    @ViewBuilder
    private func honeycombCell(_ user: SyncUser) -> some View {
        let index = store.users.firstIndex(where: { $0.id == user.id }) ?? 0
        let isActive = store.phase == .syncing && store.currentUserIndex == index
        let isDone = store.phase == .done || (store.phase == .syncing && index < store.currentUserIndex)
        HoneycombCell(
            user: user,
            isActive: isActive,
            isDone: isDone,
            focusCenter: viewportCenterGlobal
        ) {
            withAnimation(.spring(duration: 0.25)) { store.removeUser(user.screenName) }
        }
    }

    // MARK: - 悬浮进度卡（下载提示框同款：胶囊形、46pt 高；idle 最窄，同步时左右对称拉长）

    /// 胶囊卡：idle 恰好容纳图标+四字；激活态左右对称拉长
    private var progressBarCard: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(phaseLabel)
                .font(.caption)
                .lineLimit(1)
            if store.phase == .syncing {
                let progress = store.users.isEmpty ? 0 : Double(store.currentUserIndex + 1) / Double(max(1, store.users.count))
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 56)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46, alignment: .center)
        .frame(width: cardWidth, alignment: .center)
        .liquidGlass(interactive: true, cornerRadius: 23)
        .clipShape(Capsule())
        .animation(.spring(duration: 0.4), value: store.phase)
        .animation(.spring(duration: 0.4), value: store.currentUserIndex)
    }

    /// 卡宽：idle 恰好容纳图标+四字（~96pt）；激活态左右对称拉长到 ~230pt
    private var cardWidth: CGFloat {
        store.phase == .idle ? 96 : 230
    }

    private var phaseLabel: String {
        var text = store.phase.label
        if store.phase == .syncing, store.currentUserIndex >= 0, store.currentUserIndex < store.users.count {
            text += " · " + store.users[store.currentUserIndex].name
        }
        return text
    }

    // MARK: - 中性玻璃按钮（新增 / 同步，44pt，与卡片同高族，无强调色）

    private var addButton: some View {
        glassDiscButton(icon: "plus", help: L("添加同步用户")) {
            showAddSheet = true
        }
    }

    @ViewBuilder
    private var syncButton: some View {
        let symbol = store.phase == .syncing ? "pause.fill"
            : (store.phase == .done ? "checkmark" : "arrow.triangle.2.circlepath")
        glassDiscButton(icon: symbol, help: store.phase.buttonHint) {
            store.primaryAction()
        }
        .disabled(store.users.isEmpty && store.phase == .idle)
    }

    /// 中性玻璃圆钮：与状态卡同材质（玻璃 + 发丝描边 + 微高光），图标随相位移入移出
    private func glassDiscButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Circle().fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.18), .clear],
                                    startPoint: .top, endPoint: .center
                                )
                            )
                        }
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 添加弹窗

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("添加同步用户"))
                .font(.headline)
            TextField(L("输入用户名，多个用逗号分隔"), text: $input)
                .textFieldStyle(.roundedBorder)
            if !appStore.searchHistory.isEmpty {
                Text(L("搜索历史"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(appStore.searchHistory.filter { $0.kind == .user }) { item in
                            Button {
                                input = input.isEmpty ? item.keyword : input + "," + item.keyword
                            } label: {
                                HStack(spacing: 8) {
                                    CachedAvatarView(urlString: item.imageURL ?? "", size: 24)
                                    Text(item.keyword)
                                        .font(.callout)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            HStack {
                Spacer()
                Button(L("取消")) { showAddSheet = false }
                Button(L("添加")) {
                    _ = store.addUsers(fromInput: input)
                    input = ""
                    showAddSheet = false
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - HoneycombLayout（六边形环展开：每环 6k 格，参考 redblobgames rings 公式）

/// 环形蜂窝布局：子视图按六边形环展开（环 k 恰好 6k 格），无中心占位。
/// step = 相邻格中心距；cellExtent = 单元视觉外径（直径）。
struct HoneycombLayout: Layout {
    var step: CGFloat = 88
    var cellExtent: CGFloat = 84

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let n = max(1, subviews.count)
        let rings = max(0, Int(ceil((-1.0 + (1.0 + 12.0 * Double(n)).squareRoot()) / 6.0)))
        let diameter = CGFloat(2 * rings) * step + cellExtent
        return CGSize(width: diameter, height: diameter)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // 六边形环展开（redblobgames rings：六方向步进，环 k 从 NW 角顶点起顺时针）
        let directions: [(Double, Double)] = [
            (0, -1), (1, -1), (1, 0), (0, 1), (-1, 1), (-1, 0),  // axial: N NE SE S SW NW
        ]
        var positions: [CGPoint] = []
        var axial: (q: Double, r: Double) = (0, 0)
        for ring in 1...64 {
            axial = (Double(-ring), Double(ring))
            for dir in directions.indices {
                for _ in 0..<ring {
                    let d = directions[dir]
                    axial = (axial.q + d.0, axial.r + d.1)
                    // axial → 平面像素（flat-top：x = step * (q + r/2), y = step * r * √3/2）
                    let px = center.x + CGFloat(step * (axial.q + axial.r / 2))
                    let py = center.y + CGFloat(step * axial.r * 0.866_025_4)
                    positions.append(CGPoint(x: px, y: py))
                }
            }
        }

        for (idx, subview) in subviews.enumerated() {
            guard idx < positions.count else { break }
            let pos = positions[idx]
            let size = subview.sizeThatFits(.unspecified)
            subview.place(
                at: CGPoint(x: pos.x - size.width / 2, y: pos.y - size.height / 2),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }
}

// MARK: - 蜂窝单元（近大远小 + 悬停删除遮罩 + 完成态遮罩）

private struct HoneycombCell: View {
    let user: SyncUser
    let isActive: Bool
    let isDone: Bool
    let focusCenter: CGPoint
    let onDelete: () -> Void
    @State private var showDelete = false
    @State private var isPressed = false

    var body: some View {
        GeometryReader { geo in
            // 近大远小：距「蜂窝内容中心」越远越小越淡；第五环起几乎不可见
            let frame = geo.frame(in: .global)
            let dist = hypot(frame.midX - focusCenter.x, frame.midY - focusCenter.y)
            // 归一化：一个环距 = 88pt；5 环 = 440pt 处几乎隐没
            let d = min(1, dist / (88.0 * 5.0))
            let scale = 1.14 - 0.5 * d          // 1.14 → 0.64
            let fade = max(0.02, 1.0 - 0.98 * d) // 1.0 → ~0.02

            ZStack {
                Circle()
                    .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 3)
                    .frame(width: 76, height: 76)
                CachedAvatarView(urlString: user.avatar, size: 68)
                    .clipShape(Circle())

                // 同步完成/已处理：头像中心黑透明遮罩 + 绿勾（watchOS 风格）
                if isDone {
                    Circle()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 68, height: 68)
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }

                // 悬停/长按删除：头像中心黑透明遮罩 + 白 ×（大小形状即头像）
                if showDelete {
                    Button(action: onDelete) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.55))
                                .frame(width: 68, height: 68)
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(scale * (isActive ? 1.06 : (isPressed ? 0.94 : 1.0)))
            .opacity(fade)
            .animation(.spring(duration: 0.3), value: isActive)
            .animation(.spring(duration: 0.2), value: isPressed)
            .animation(.easeOut(duration: 0.25), value: d)
        }
        .frame(width: 84, height: 84)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { showDelete = hovering }
        }
        .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
            isPressed = pressing
            if pressing {
                withAnimation(.spring(duration: 0.25)) { showDelete = true }
            }
        }, perform: {})
    }
}

#Preview {
    SyncView()
}
