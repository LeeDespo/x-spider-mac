import SwiftUI
import AppKit

/// 同步页：watchOS 蜂窝头像布局（六边形环展开 RadialLayout，无中心占位）。
/// 近大远小按「格子在内容坐标中到焦点中心的距离」计算；
/// 焦点通过拖拽 / 滚轮 / 方向键平移蜂窝改变——不依赖内容超出视口。
/// 状态卡悬浮页面 3/4 高度、胶囊形（下载提示框同款）、左右对称伸缩；
/// 右侧外挂「新增」「同步」中性玻璃按钮。
struct SyncView: View {
    @State private var store = SyncStore.shared
    @State private var showAddSheet = false
    @State private var input = ""
    @State private var appStore = AppStore.shared
    /// 页面可视尺寸（3/4 定位与平移钳制用）
    @State private var viewportSize: CGSize = .zero
    /// 蜂窝内容的平移偏移（拖拽/滚轮/方向键驱动）
    @State private var panOffset: CGSize = .zero
    /// 滚轮事件监听器
    @State private var scrollMonitor: Any?

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
                .offset(x: -52, y: viewportSize.height * 0.25)
            }
            .navigationTitle(L("同步"))
            .sheet(isPresented: $showAddSheet) { addSheet }
            .task {
                store.syncOnLaunchIfNeeded()
            }
    }

    // MARK: - 蜂窝（六边形环展开 + 拖拽/滚轮平移近大远小）

    private var honeycomb: some View {
        GeometryReader { geo in
            let D = HexRing.diameter(userCount: store.users.count)
            // 焦点 = 蜂窝内容中心 − 平移偏移（拖拽/滚轮/方向键实时驱动尺寸重排）
            let focus = CGPoint(x: D / 2 - panOffset.width, y: D / 2 - panOffset.height)
            ZStack {
                HoneycombLayout(focusPosition: focus) {
                    ForEach(Array(store.users.enumerated()), id: \.element.id) { idx, user in
                        honeycombCell(user, index: idx)
                            .zIndex(Double(100 - HexRing.ringNumber(index: idx)))
                    }
                }
                .frame(width: D, height: D, alignment: .center)
                .offset(panOffset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        panOffset = clampedPan(panOffset, viewport: geo.size, content: D,
                                               dx: value.translation.width, dy: value.translation.height,
                                               additive: false)
                    }
                    .onEnded { value in
                        withAnimation(.spring(duration: 0.3)) {
                            panOffset = clampedPan(panOffset, viewport: geo.size, content: D,
                                                   dx: value.predictedEndTranslation.width - value.translation.width,
                                                   dy: value.predictedEndTranslation.height - value.translation.height)
                        }
                    }
            )
            .onAppear {
                viewportSize = geo.size
                installScrollMonitor(contentDiameter: D, viewport: geo.size)
            }
            .onChange(of: geo.size) { _, newSize in
                viewportSize = newSize
                panOffset = clampedPan(panOffset, viewport: newSize, content: D, dx: 0, dy: 0, additive: false)
            }
            .onDisappear {
                if let monitor = scrollMonitor {
                    NSEvent.removeMonitor(monitor)
                    scrollMonitor = nil
                }
            }
        }
    }

    /// 平移钳制：蜂窝大于视口时限到边缘，小于视口时也允许 ±120pt 漫游（焦点仍可移动）
    private func clampedPan(_ current: CGSize, viewport: CGSize, content: CGFloat,
                            dx: CGFloat, dy: CGFloat, additive: Bool = true) -> CGSize {
        let base = additive
            ? CGSize(width: current.width + dx, height: current.height + dy)
            : CGSize(width: dx, height: dy)
        let halfW = max(0, (content - viewport.width) / 2) + 120
        let halfH = max(0, (content - viewport.height) / 2) + 120
        return CGSize(
            width: min(halfW, max(-halfW, base.width)),
            height: min(halfH, max(-halfH, base.height))
        )
    }

    /// 滚轮/触控板双指滑动 + 方向键 → 平移蜂窝（本地事件监听；弹窗打开时放行不拦截）
    private func installScrollMonitor(contentDiameter: CGFloat, viewport: CGSize) {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { event in
            guard showAddSheet == false, NSApp.keyWindow?.sheets.isEmpty ?? true else { return event }
            if event.type == .scrollWheel {
                let dx = -event.scrollingDeltaX * 2.2
                let dy = -event.scrollingDeltaY * 2.2
                guard abs(dx) > 0.1 || abs(dy) > 0.1 else { return event }
                withAnimation(.easeOut(duration: 0.12)) {
                    panOffset = clampedPan(panOffset, viewport: viewport, content: contentDiameter,
                                           dx: dx, dy: dy)
                }
                return nil
            } else {
                // 方向键平移焦点（无 focusable 焦点环）
                let step: CGFloat = 44
                let dx: CGFloat, dy: CGFloat
                switch event.keyCode {
                case 123: (dx, dy) = (step, 0)      // left
                case 124: (dx, dy) = (-step, 0)     // right
                case 125: (dx, dy) = (0, step)      // down
                case 126: (dx, dy) = (0, -step)     // up
                default: return event
                }
                withAnimation(.spring(duration: 0.25)) {
                    panOffset = clampedPan(panOffset, viewport: viewport, content: contentDiameter,
                                           dx: dx, dy: dy)
                }
                return nil
            }
        }
    }

    @ViewBuilder
    private func honeycombCell(_ user: SyncUser, index: Int) -> some View {
        let D = HexRing.diameter(userCount: store.users.count)
        let center = CGPoint(x: D / 2, y: D / 2)
        let rel = HexRing.position(index: index)
        let cellPos = CGPoint(x: center.x + rel.x, y: center.y + rel.y)
        let focus = CGPoint(x: center.x - panOffset.width, y: center.y - panOffset.height)
        let ring = HexRing.ringNumber(index: index)
        let isActive = store.phase == .syncing && store.currentUser == user.screenName
        let isDone = store.completedUsers.contains(user.screenName)
        let cellSize = HexRing.cellSize(distanceToFocus: hypot(cellPos.x - focus.x, cellPos.y - focus.y))
        return HoneycombCell(
            user: user,
            isActive: isActive,
            isDone: isDone,
            size: cellSize,
            interactive: ring <= 5
        ) {
            withAnimation(.spring(duration: 0.25)) { store.removeUser(user.screenName) }
        } onSync: {
            withAnimation(.spring(duration: 0.3)) { store.startSync(target: [user]) }
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
        .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 5)
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
                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
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

// MARK: - 六边形环位置（布局与视图共用的唯一事实来源，参考 redblobgames rings 公式）

enum HexRing {
    /// 六方向轴向步进（N NE SE S SW NW）
    static let directions: [(Double, Double)] = [
        (0, -1), (1, -1), (1, 0), (0, 1), (-1, 1), (-1, 0),
    ]

    /// 基准头像直径
    static let baseSize: CGFloat = 68

    /// 距焦点的连续尺寸曲线（布局与视图共用的唯一事实来源）：
    /// 中心 200% → 每环 ×0.72 → 第五环 ≈50% → 之外一律 20%
    static func cellSize(distanceToFocus dist: CGFloat) -> CGFloat {
        let r5 = ringRadius(ring: 5)  // 第五环半径（≈415pt）
        guard dist > cellSize(ring: 0) * 0.38 else { return cellSize(ring: 0) }
        guard dist < r5 else { return cellSize(ring: 6) }  // 五环外一律 20%
        let ringEquivalent = 5.0 * Double(dist / r5)
        return min(cellSize(ring: 0), baseSize * 2.0 * CGFloat(pow(0.72, ringEquivalent)))
    }

    /// 每环头像直径：中心 200% → 每环 ×0.72 → 五环 50% → 六环起一律 20%
    static func cellSize(ring: Int) -> CGFloat {
        switch ring {
        case 0: return baseSize * 2.0
        case 1: return baseSize * 1.44
        case 2: return baseSize * 1.04
        case 3: return baseSize * 0.75
        case 4: return baseSize * 0.60
        case 5: return baseSize * 0.50
        default: return baseSize * 0.20
        }
    }

    /// 环间距：随环号递减——内环大头像配大间隙（一环 34pt），外环小头像收紧（五环外 7pt）
    /// 让整张蜂窝的视觉密度均匀，避免内环拥挤、外环稀疏
    static func ringGap(ring: Int) -> CGFloat {
        max(7, 34 * pow(0.78, Double(ring - 1)))
    }

    /// 环 r 的中心距（环 0→1 = 中心尺寸/2 + 环1尺寸/2 + 该处间隙；环间 = 两环尺寸/2 之和 + 该处间隙）
    static func ringRadius(ring: Int) -> CGFloat {
        guard ring > 0 else { return 0 }
        var radius: CGFloat = cellSize(ring: 0) / 2 + cellSize(ring: 1) / 2 + ringGap(ring: 1)
        if ring >= 2 {
            for r in 2...ring {
                radius += cellSize(ring: r - 1) / 2 + cellSize(ring: r) / 2 + ringGap(ring: r)
            }
        }
        return radius
    }

    /// 蜂窝整体直径（最大环半径 × 2 + 最大格径 + 余量）
    static func diameter(userCount: Int) -> CGFloat {
        let rings = max(0, Int(ceil((-1.0 + (1.0 + 12.0 * Double(max(1, userCount))).squareRoot()) / 6.0)))
        guard rings > 0 else { return cellSize(ring: 0) + 40 }
        let maxCell = cellSize(ring: rings)
        return ringRadius(ring: rings) * 2 + maxCell + 24
    }

    /// 第 index 格（0 起）所在环号
    static func ringNumber(index: Int) -> Int {
        guard index > 0 else { return 0 }
        return Int(ceil((-3.0 + (9.0 + 12.0 * Double(index)).squareRoot()) / 6.0))
    }

    /// 第 index 格（0 起）在内容坐标系中相对蜂窝中心的平面位置
    static func position(index: Int) -> CGPoint {
        allPositions(count: index + 1)[index]
    }

    /// 前 count 格的全部位置（含中心）：环 r 在其专属半径上均匀分布（每环独立半径 → 永不重叠）
    static func allPositions(count: Int) -> [CGPoint] {
        var result: [CGPoint] = [.zero]
        guard count > 1 else { return result }
        var ring = 1
        while result.count < count {
            let radius = ringRadius(ring: ring)
            var axial: (q: Double, r: Double) = (Double(-ring), Double(ring))  // 环起点：NW 角顶点
            for dir in directions.indices {
                for _ in 0..<ring {
                    let d = directions[dir]
                    axial = (axial.q + d.0, axial.r + d.1)
                    // 轴向 → 平面（flat-top：x = radius*(q + r/2)/ring, y = radius*r*√3/2/ring）
                    // 即把该环的 6r 格均匀放在半径 radius 的六边形环上
                    let x = radius * CGFloat(axial.q + axial.r / 2) / CGFloat(ring)
                    let y = radius * CGFloat(axial.r) * 0.866_025_4 / CGFloat(ring)
                    result.append(CGPoint(x: x, y: y))
                    if result.count >= count { return result }
                }
            }
            ring += 1
        }
        return result
    }
}

// MARK: - HoneycombLayout（六边形环展开：每环 6k 格）

/// 环形蜂窝布局：子视图按六边形环展开（环 k 恰好 6k 格），无中心占位。
/// step = 相邻格中心距；cellExtent = 单元视觉外径（直径）。
struct HoneycombLayout: Layout {
    /// 焦点中心在内容坐标系中的位置（随拖拽/滚轮平移实时更新 → 触发重布局）
    var focusPosition: CGPoint = .zero

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let d = HexRing.diameter(userCount: subviews.count)
        return CGSize(width: d, height: d)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let positions = HexRing.allPositions(count: subviews.count)

        for (idx, subview) in subviews.enumerated() {
            guard idx < positions.count else { break }
            let pos = positions[idx]
            // 尺寸 = 该格到焦点的距离（与视图层同一公式）
            let dist = hypot(pos.x - focusPosition.x, pos.y - focusPosition.y)
            let cellSize = HexRing.cellSize(distanceToFocus: dist)
            // 直接把格子按目标尺寸摆放（布局即尺寸，无 scaleEffect 溢出）
            subview.place(
                at: CGPoint(x: center.x + pos.x - cellSize / 2, y: center.y + pos.y - cellSize / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cellSize, height: cellSize)
            )
        }
    }
}

// MARK: - 蜂窝单元（尺寸由布局按环提案；悬停元素 overlay 锚定头像边缘，永不错位）

private struct HoneycombCell: View {
    let user: SyncUser
    let isActive: Bool
    let isDone: Bool
    /// 头像直径（布局按环号算好直接给）
    let size: CGFloat
    /// 五环内才响应悬停按钮/标签
    let interactive: Bool
    let onDelete: () -> Void
    let onSync: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        avatar
            .overlay(alignment: .topTrailing) {
                // 完成态：右上角玻璃打勾徽标（悬停时淡出让位给按钮组）
                if isDone && !isHovering {
                    completionBadge
                        .offset(x: 6, y: -6)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                // 悬停（五环内）：右上角 = 同步该用户圆钮
                if isHovering && interactive {
                    glassMiniButton(icon: "arrow.triangle.2.circlepath",
                                    tint: isDone ? Color.green : Color.accentColor,
                                    help: L("同步该用户")) { onSync() }
                        .offset(x: 10, y: -10)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // 悬停（五环内）：右下角 = 删除该用户圆钮
                if isHovering && interactive {
                    glassMiniButton(icon: "xmark", tint: .red, help: L("移除该用户")) { onDelete() }
                        .offset(x: 10, y: 10)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                // 悬停（五环内）：昵称-@用户名 白色液态玻璃标签（贴头像下缘）
                if isHovering && interactive {
                    Text("\(user.name)-@\(user.screenName)")
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.88), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                        .fixedSize()
                        .offset(y: 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                // 同步中：强调色圆环（随头像尺寸）
                if isActive {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(-5)
                }
            }
            .scaleEffect(isPressed ? 0.94 : 1.0)
            .animation(.spring(duration: 0.22), value: isHovering)
            .animation(.spring(duration: 0.25), value: isDone)
            .onHover { h in
                guard interactive else { return }
                isHovering = h
            }
            .onLongPressGesture(minimumDuration: 0.25, pressing: { p in
                isPressed = p
            }, perform: {})
            .help(interactive ? "" : user.name)
    }

    private var avatar: some View {
        CachedAvatarView(urlString: user.avatar, size: size)
            .clipShape(Circle())
    }

    /// 完成徽标：绿色玻璃小圆 + 白勾（24pt 固定，悬停淡出）
    private var completionBadge: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .fill(Color.green.opacity(0.85))
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    /// 32pt 玻璃圆钮（与状态卡同材质族）
    private func glassMiniButton(icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Circle().fill(
                                LinearGradient(colors: [.white.opacity(0.25), .clear],
                                               startPoint: .top, endPoint: .center)
                            )
                        }
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.30), lineWidth: 1)
                        }
                }
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
