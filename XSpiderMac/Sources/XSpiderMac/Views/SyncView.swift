import SwiftUI

/// 同步页：watchOS 蜂窝头像布局（六边形环展开 RadialLayout：中心加号 + 每环 6k 个），
/// 外围淡化；悬浮进度框固定在页面 3/4 高度（宽度随状态伸缩），外侧小号状态机按钮。
struct SyncView: View {
    @State private var store = SyncStore.shared
    @State private var showAddSheet = false
    @State private var input = ""
    @State private var appStore = AppStore.shared

    var body: some View {
        // 蜂窝铺满全页；进度框悬浮在页面 3/4 高度点（overlay，不参与布局挤压蜂窝）
        honeycomb
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
                // 垂直偏移 +25% 页面高 = 3/4 位置；左右居中
                progressBar
                    .offset(y: honeycombBoxHeight * 0.25)
            }
            .navigationTitle(L("同步"))
            .sheet(isPresented: $showAddSheet) { addSheet }
            .task {
                store.syncOnLaunchIfNeeded()
            }
    }

    /// 页面可视高度（用于 3/4 定位）：用 GeometryReader 探测
    @State private var honeycombBoxHeight: CGFloat = 0

    // MARK: - 蜂窝头像（六边形环展开）

    private var honeycomb: some View {
        GeometryReader { geo in
            let boxH = geo.size.height
            ScrollView([.horizontal, .vertical]) {
                HoneycombLayout(cellSize: 118, ringGap: 22) {
                    // 中心 = 加号
                    addCenterButton
                    // 外圈 = 用户（按环展开顺序）
                    ForEach(Array(store.users.enumerated()), id: \.element.id) { idx, user in
                        honeycombCell(user, index: idx)
                    }
                }
                .frame(width: honeycombDiameter, height: honeycombDiameter, alignment: .center)
                .padding(48)
                .frame(width: geo.size.width, height: boxH)  // 蜂窝内容在可视区内居中
            }
            .scrollIndicators(.hidden)
            .onAppear { honeycombBoxHeight = boxH }
            .onChange(of: geo.size.height) { _, newH in honeycombBoxHeight = newH }
        }
    }

    /// 蜂窝所需直径（满环公式，与 HoneycombLayout.sizeThatFits 一致）
    private var honeycombDiameter: CGFloat {
        let n = max(1, store.users.count)
        let rings = max(0, Int(ceil((-1.0 + (1.0 + 12.0 * Double(n)).squareRoot()) / 6.0)))
        let step: CGFloat = 118 / 2 + 22
        return CGFloat(2 * rings + 1) * step + 118
    }

    @ViewBuilder
    private func honeycombCell(_ user: SyncUser, index: Int) -> some View {
        let isActive = store.phase == .syncing && store.currentUserIndex == index
        let isDone = store.phase == .syncing && index < store.currentUserIndex
        HoneycombCell(user: user, isActive: isActive, isDone: isDone, cellOpacity: opacity(for: index)) {
            withAnimation(.spring(duration: 0.25)) { store.removeUser(user.screenName) }
        }
    }

    /// 外围淡化：环号越深越透明
    private func opacity(for index: Int) -> Double {
        let ring = Double((index + 5) / 6)
        let maxRing = Double((store.users.count + 5) / 6)
        guard maxRing > 1 else { return 1.0 }
        let t = ring / maxRing
        return 1.0 - t * 0.5
    }

    private var addCenterButton: some View {
        Button {
            showAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 76, height: 76)
                .background(.quinary, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .help(L("添加同步用户"))
    }

    // MARK: - 悬浮进度框（3/4 高度、宽度随状态伸缩动画）

    @ViewBuilder
    private var progressBar: some View {
        HStack(alignment: .center, spacing: 8) {
            progressBarCard
            primaryButton
        }
    }

    /// 进度卡：idle 最窄（约 1/4，只容纳四字），同步时**左右对称拉长**。
    /// 高度恒定 + 内容 ZStack overlay 切换 → 宽度变化只走水平方向，不上下拉伸。
    private var progressBarCard: some View {
        ZStack {
            if store.phase == .idle {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(L("等待同步"))
                        .font(.caption)
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(phaseLabel)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                    }
                    if store.phase == .syncing {
                        let progress = store.users.isEmpty ? 0 : Double(store.currentUserIndex + 1) / Double(max(1, store.users.count))
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    } else {
                        Text(store.phase == .done ? summaryText : L("已取消"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: cardWidth, height: 52, alignment: .center)  // 宽度动画、高度恒定 → 只左右伸缩
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .liquidGlass(interactive: true, cornerRadius: 18)
        .animation(.spring(duration: 0.4), value: store.phase)
        .animation(.spring(duration: 0.4), value: store.currentUserIndex)
    }

    /// 卡宽：idle ≈ 容纳"等待同步"（~110pt）；激活态拉长（~200pt，用户要求约 1/4 长度级别）
    private var cardWidth: CGFloat {
        store.phase == .idle ? 112 : 210
    }

    private var phaseLabel: String {
        var text = store.phase.label
        if store.phase == .syncing, store.currentUserIndex >= 0, store.currentUserIndex < store.users.count {
            text += " · " + store.users[store.currentUserIndex].name
        }
        return text
    }

    private var currentUserText: String {
        guard store.currentUserIndex >= 0, store.currentUserIndex < store.users.count else { return "" }
        let user = store.users[store.currentUserIndex]
        return store.userMessages[user.screenName] ?? ""
    }

    private var summaryText: String {
        store.userMessages.values.joined(separator: " · ")
    }

    // MARK: - 状态机圆形按钮（小号 36pt，无文字，贴进度框右缘）

    @ViewBuilder
    private var primaryButton: some View {
        let (symbol, color): (String, Color) = {
            switch store.phase {
            case .idle: return ("arrow.triangle.2.circlepath", Color.accentColor)
            case .syncing: return ("pause.fill", .red)
            case .done: return ("checkmark", .green)
            case .interrupted: return ("arrow.triangle.2.circlepath", Color.accentColor)
            }
        }()
        Button {
            withAnimation(.spring(duration: 0.35)) { store.primaryAction() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(.quinary, in: Circle())
                .overlay {
                    Circle().strokeBorder(color.opacity(0.35), lineWidth: 1.5)
                }
                .rotationEffect(.degrees(store.phase == .syncing ? 360 : 0))
                .animation(store.phase == .syncing ? .linear(duration: 1.6).repeatForever(autoreverses: false) : .spring(duration: 0.35), value: store.phase)
        }
        .buttonStyle(.plain)
        .disabled(store.users.isEmpty && store.phase == .idle)
        .help(store.phase.buttonHint)
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

// MARK: - HoneycombLayout（六边形环展开：中心 + 每环 6k 个，参考 redblobgames rings 公式）

/// 环形蜂窝布局：子视图 0 = 中心，其余按六边形环展开（环 k 有 6k 个位置，
/// 每环半径 = k * step）。每环旋转 30° 错位，形成蜂窝视觉密度。
struct HoneycombLayout: Layout {
    var cellSize: CGFloat = 118
    var ringGap: CGFloat = 22

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 满蜂窝环数公式：n-1 ≤ 3r(r+1) → r = ceil((-1+sqrt(1+12(n-1)))/6)
        let n = max(1, subviews.count - 1)
        let rings = max(0, Int(ceil((-1.0 + (1.0 + 12.0 * Double(n)).squareRoot()) / 6.0)))
        let diameter = CGFloat(2 * rings + 1) * (cellSize / 2 + ringGap) + cellSize
        return CGSize(width: diameter, height: diameter)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let step = cellSize / 2 + ringGap

        // 六边形环展开（redblobgames rings：cube 坐标六方向螺旋步进，
        // 环 k 恰好 6k 格，从 12 点方向顺时针，保证一环满再到下一环、相邻格等距）
        let directions: [(Double, Double)] = [
            (0, -1), (1, -1), (1, 0), (0, 1), (-1, 1), (-1, 0),  // axial: N NE SE S SW NW
        ]
        // 预生成蜂窝位置序列（下标 = 子视图序号；0 = 中心）
        var positions: [CGPoint] = [center]
        var axial: (q: Double, r: Double) = (0, 0)
        for ring in 1...64 {
            // 先走到环起点：NW 方向 × ring 步（六边形角）
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

// MARK: - 蜂窝单元

private struct HoneycombCell: View {
    let user: SyncUser
    let isActive: Bool
    let isDone: Bool
    let cellOpacity: Double
    let onDelete: () -> Void
    @State private var showDelete = false
    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .strokeBorder(ringColor, lineWidth: 3)
                        .frame(width: 76, height: 76)
                    CachedAvatarView(urlString: user.avatar, size: 68)
                }
                if showDelete {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red, .white)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            Text(user.name)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 88)
        }
        .opacity(cellOpacity)
        .scaleEffect(isActive ? 1.08 : (isPressed ? 0.95 : 1.0))
        .animation(.spring(duration: 0.3), value: isActive)
        .animation(.spring(duration: 0.2), value: isPressed)
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

    private var ringColor: Color {
        if isActive { return Color.accentColor }
        if isDone { return .green }
        return Color.clear
    }
}

#Preview {
    SyncView()
}
