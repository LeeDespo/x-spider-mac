import SwiftUI

/// 同步页：watchOS 蜂窝头像布局（六边形环展开 RadialLayout：中心加号 + 每环 6k 个），
/// 外围淡化；进度框（下载提示框同款 UI）+ 外侧小号状态机按钮。
struct SyncView: View {
    @State private var store = SyncStore.shared
    @State private var showAddSheet = false
    @State private var input = ""

    var body: some View {
        VStack(spacing: 14) {
            if store.users.isEmpty && store.phase != .syncing {
                emptyState
            } else {
                Spacer(minLength: 0)
                honeycomb
                // 进度框 + 外侧小按钮（贴框右侧）
                HStack(alignment: .center, spacing: 10) {
                    progressBar
                    primaryButton
                }
                .frame(maxWidth: 560)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("同步"))
        .sheet(isPresented: $showAddSheet) { addSheet }
        .task {
            store.syncOnLaunchIfNeeded()
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 16) {
            primaryButton
            Text(L("暂无可同步的用户"))
                .foregroundStyle(.secondary)
            Text(L("先在主页浏览或下载过用户媒体，再回到这里同步。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 蜂窝头像（六边形环展开）

    private var honeycomb: some View {
        ScrollView([.horizontal, .vertical]) {
            HoneycombLayout(cellSize: 96, ringGap: 10) {
                // 中心 = 加号
                addCenterButton
                // 外圈 = 用户（按环展开顺序）
                ForEach(Array(store.users.enumerated()), id: \.element.id) { idx, user in
                    honeycombCell(user, index: idx)
                }
            }
            .frame(width: honeycombDiameter, height: honeycombDiameter, alignment: .center)
            .padding(40)
        }
        .scrollIndicators(.hidden)
    }

    /// 蜂窝所需直径：环数 = ceil((n) / 6)；直径 ≈ (2*环数+1) * 环间距
    private var honeycombDiameter: CGFloat {
        let rings = Double((store.users.count + 5) / 6)
        return CGFloat((2 * rings + 1)) * 110 + 80
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
        let ring = Double((index + 5) / 6)  // 第几环（0 起）
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
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .background(.quinary, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .help(L("添加同步用户"))
    }

    // MARK: - 进度框（下载提示框同款 UI）

    private var progressBar: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(phaseLabel)
                    .font(.caption)
                Spacer()
            }
            if store.phase == .syncing {
                let progress = store.users.isEmpty ? 0 : Double(store.currentUserIndex + 1) / Double(store.users.count)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                Text(currentUserText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if store.phase == .done {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .liquidGlass(interactive: true, cornerRadius: 20)
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

    // MARK: - 状态机圆形按钮（小号，无文字）

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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
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

    @State private var appStore = AppStore.shared
}

// MARK: - HoneycombLayout（六边形环展开：中心 + 每环 6k 个，参考 redblobgames rings 公式）

/// 环形蜂窝布局：子视图 0 = 中心，其余按六边形环展开（环 k 有 6k 个位置，
/// 每环半径 = k * step）。角度微交错让相邻环错位，形成蜂窝视觉密度。
struct HoneycombLayout: Layout {
    var cellSize: CGFloat = 96
    var ringGap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rings = Double(max(0, subviews.count - 1)) / 6.0
        let count = Int(ceil(rings))
        let diameter = CGFloat(2 * count + 1) * (cellSize / 2 + ringGap) + cellSize
        return CGSize(width: diameter, height: diameter)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let step = cellSize / 2 + ringGap

        for (idx, subview) in subviews.enumerated() {
            let pos: CGPoint
            if idx == 0 {
                pos = center
            } else {
                // 第 idx 个子视图 → (ring, ringIndex)：环 k 容纳 6k 个
                let ring = Int(ceil(Double(idx) / 6.0))
                let indexInRing = idx - (6 * (ring - 1) + 1)  // 环内 0-based
                let capacity = 6 * ring
                // 六边形环：角度均匀 + 半环交错偏移，模拟蜂窝错位嵌套
                let angle = (Double(indexInRing) / Double(capacity)) * 2 * .pi
                    + (Double(ring) * .pi / 6)  // 每环错开 30°
                let radius = Double(ring) * step
                pos = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * radius,
                    y: center.y + CGFloat(sin(angle)) * radius
                )
            }
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
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .strokeBorder(ringColor, lineWidth: 3)
                        .frame(width: 62, height: 62)
                    CachedAvatarView(urlString: user.avatar, size: 54)
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
                .frame(width: 72)
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
