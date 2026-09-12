import SwiftUI

/// 同步页：watchOS 蜂窝头像布局（FlowLayout 环绕 + 外围淡化），
/// 中心加号添加用户；底部进度框 + 状态机圆形按钮。
struct SyncView: View {
    @State private var store = SyncStore.shared
    @State private var showAddSheet = false
    @State private var input = ""

    var body: some View {
        VStack(spacing: 20) {
            if store.users.isEmpty && store.phase != .syncing {
                emptyState
            } else {
                honeycomb
                progressBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("同步"))
        .sheet(isPresented: $showAddSheet) { addSheet }
        .task {
            // 打开应用自动同步（设置开启时）
            store.syncOnLaunchIfNeeded()
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 84, height: 84)
                    .background(.quinary, in: Circle())
            }
            .buttonStyle(.plain)
            Text(L("暂无可同步的用户"))
                .foregroundStyle(.secondary)
            Text(L("先在主页浏览或下载过用户媒体，再回到这里同步。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 蜂窝头像

    private var honeycomb: some View {
        ScrollView {
            FlowLayout(spacing: 18) {
                ForEach(Array(store.users.enumerated()), id: \.element.id) { idx, user in
                    honeycombCell(user, index: idx)
                }
                // 中心加号按钮
                addCenterButton
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func honeycombCell(_ user: SyncUser, index: Int) -> some View {
        let isActive = store.phase == .syncing && store.currentUserIndex == index
        let isDone = store.phase == .syncing && index < store.currentUserIndex
        HoneycombCell(user: user, isActive: isActive, isDone: isDone, cellOpacity: opacity(for: index)) {
            withAnimation(.spring(duration: 0.25)) { store.removeUser(user.screenName) }
        }
    }

    /// 外围淡化：按离中心的索引距离衰减（20+ 用户时外圈 0.35 起）
    private func opacity(for index: Int) -> Double {
        let total = store.users.count
        guard total > 12 else { return 1.0 }
        let distance = abs(index - total / 2)
        let maxD = Double(max(total - total / 2, 1))
        let t = Double(distance) / maxD
        return 1.0 - t * 0.55
    }

    private var addCenterButton: some View {
        Button {
            showAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 68, height: 68)
                .background(.quinary, in: Circle())
        }
        .buttonStyle(.plain)
        .help(L("添加同步用户"))
    }

    // MARK: - 进度框

    private var progressBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(phaseLabel)
                    .font(.callout.weight(.medium))
                if store.phase == .syncing {
                    let progress = store.users.isEmpty ? 0 : Double(store.currentUserIndex + 1) / Double(store.users.count)
                    ProgressView(value: progress)
                    Text(currentUserText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if store.phase == .done {
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            primaryButton
        }
        .padding(16)
        .liquidGlass(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
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

    // MARK: - 状态机圆形按钮（无文字，图标随状态变化 + 动画）

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
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 52, height: 52)
                .background(.quinary, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(color.opacity(0.35), lineWidth: 2)
                }
                // syncing 时旋转动画
                .rotationEffect(.degrees(store.phase == .syncing ? 360 : 0))
                .animation(store.phase == .syncing ? .linear(duration: 1.6).repeatForever(autoreverses: false) : .spring(duration: 0.35), value: store.phase)
        }
        .buttonStyle(.plain)
        .disabled(store.users.isEmpty && store.phase == .idle)
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

// MARK: - FlowLayout（环绕布局，watchOS 蜂窝用）

/// 蜂窝单元：头像 + 圆环 + 悬停删除按钮
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

/// 自适应流式布局：子视图按行排列，放不下换行（居中对齐）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
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
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var rowViews: [(Int, CGSize)] = []
        var rowStart = 0

        func flushRow() {
            guard !rowViews.isEmpty else { return }
            let totalWidth = rowViews.reduce(0) { $0 + $1.1.width } + CGFloat(rowViews.count - 1) * spacing
            var cx = bounds.minX + (bounds.width - totalWidth) / 2  // 居中
            for (idx, size) in rowViews {
                let sub = subviews[idx]
                let vSize = sub.sizeThatFits(.unspecified)
                sub.place(at: CGPoint(x: cx, y: y + (rowHeight - vSize.height) / 2),
                          proposal: ProposedViewSize(size))
                cx += size.width + spacing
            }
            y += rowHeight + spacing
            rowViews.removeAll()
            rowStart = 0
        }

        for (idx, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, !rowViews.isEmpty {
                flushRow()
                x = bounds.minX
            }
            rowViews.append((idx, size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        flushRow()
    }
}

#Preview {
    SyncView()
}
