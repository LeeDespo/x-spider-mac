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

    /// 蜂窝所需直径：环数 = ceil(n / 6)；直径 ≈ (2*环数+1) * 环间距
    private var honeycombDiameter: CGFloat {
        let rings = Double((store.users.count + 5) / 6)
        return CGFloat((2 * rings + 1)) * (59 + 22) + 118 + 96
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

    /// 进度卡：idle 最窄（只容纳"等待同步"），syncing/done 拉长显示进度条；居中锚点伸缩
    private var progressBarCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(phaseLabel)
                    .font(.caption)
                if store.phase != .idle {
                    Spacer()
                }
            }
            // idle 隐藏进度条（占位不塌陷，保持高度恒定）
            if store.phase != .idle {
                if store.phase == .syncing {
                    let progress = store.users.isEmpty ? 0 : Double(store.currentUserIndex + 1) / Double(store.users.count)
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    Text(currentUserText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if store.phase == .done {
                    Text(summaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if store.phase == .interrupted {
                    Text(L("已取消"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 168, maxWidth: 380, alignment: .leading)
        .liquidGlass(interactive: true, cornerRadius: 20)
        .animation(.spring(duration: 0.4), value: store.phase)
        .animation(.spring(duration: 0.4), value: store.currentUserIndex)
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
                .frame(width: 36, height: 36)
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
                let ring = Int(ceil(Double(idx) / 6.0))
                let indexInRing = idx - (6 * (ring - 1) + 1)
                let capacity = 6 * ring
                let angle = (Double(indexInRing) / Double(capacity)) * 2 * .pi
                    + (Double(ring) * .pi / 6)
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
