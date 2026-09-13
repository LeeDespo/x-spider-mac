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
            let D = honeycombDiameter
            let contentCenter = CGPoint(x: D / 2, y: D / 2)
            // 焦点 = 视口中心映射到内容坐标：内容右移 → 焦点左移
            let focus = CGPoint(
                x: contentCenter.x - panOffset.width,
                y: contentCenter.y - panOffset.height
            )

            ZStack {
                HoneycombLayout(step: 88, cellExtent: 84) {
                    ForEach(Array(store.users.enumerated()), id: \.element.id) { idx, user in
                        let rel = HexRing.position(index: idx, step: 88)
                        let cellPos = CGPoint(x: contentCenter.x + rel.x, y: contentCenter.y + rel.y)
                        honeycombCell(user, index: idx, cellPos: cellPos, focus: focus)
                    }
                }
                .frame(width: D, height: D, alignment: .center)
                .offset(panOffset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .focusable(true)
            .onMoveCommand { dir in
                // 方向键平移焦点
                withAnimation(.spring(duration: 0.25)) {
                    panOffset = clampedPan(panOffset, viewport: geo.size, content: D,
                                           dx: dir == .left ? 44 : dir == .right ? -44 : 0,
                                           dy: dir == .up ? 44 : dir == .down ? -44 : 0)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        panOffset = clampedPan(panOffset, viewport: geo.size, content: D,
                                               dx: value.translation.width, dy: value.translation.height,
                                               additive: false)
                    }
                    .onEnded { value in
                        withAnimation(.spring(duration: 0.35)) {
                            panOffset = clampedPan(panOffset, viewport: geo.size, content: D,
                                                   dx: value.translation.width, dy: value.translation.height,
                                                   additive: false)
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

    /// 滚轮/触控板双指滑动 → 平移蜂窝（本地事件监听；弹窗打开时放行不拦截）
    private func installScrollMonitor(contentDiameter: CGFloat, viewport: CGSize) {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard showAddSheet == false, NSApp.keyWindow?.sheets.isEmpty ?? true else { return event }
            let dx = -event.scrollingDeltaX * 2.2
            let dy = -event.scrollingDeltaY * 2.2
            guard abs(dx) > 0.1 || abs(dy) > 0.1 else { return event }
            withAnimation(.easeOut(duration: 0.12)) {
                panOffset = clampedPan(panOffset, viewport: viewport, content: contentDiameter,
                                       dx: dx, dy: dy)
            }
            return nil
        }
    }

    /// 蜂窝所需直径（满环公式：环 r 横向半径 = r*step）
    private var honeycombDiameter: CGFloat {
        let n = max(1, store.users.count)
        let rings = max(0, Int(ceil((-1.0 + (1.0 + 12.0 * Double(n)).squareRoot()) / 6.0)))
        return CGFloat(2 * rings) * 88 + 84
    }

    @ViewBuilder
    private func honeycombCell(_ user: SyncUser, index: Int, cellPos: CGPoint, focus: CGPoint) -> some View {
        let isActive = store.phase == .syncing && store.currentUserIndex == index
        let isDone = store.phase == .done || (store.phase == .syncing && index < store.currentUserIndex)
        HoneycombCell(
            user: user,
            isActive: isActive,
            isDone: isDone,
            cellPosition: cellPos,
            focusPosition: focus
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

// MARK: - 六边形环位置（布局与视图共用的唯一事实来源，参考 redblobgames rings 公式）

enum HexRing {
    /// 六方向轴向步进（N NE SE S SW NW）
    static let directions: [(Double, Double)] = [
        (0, -1), (1, -1), (1, 0), (0, 1), (-1, 1), (-1, 0),
    ]

    /// 第 index 格（0 = 中心）相对蜂窝中心的平面坐标（flat-top 投影）
    static func position(index: Int, step: CGFloat) -> CGPoint {
        allPositions(count: index + 1, step: step)[index]
    }

    /// 前 count 格的全部位置（含中心）；与 HoneycombLayout.placeSubviews 顺序一致
    static func allPositions(count: Int, step: CGFloat) -> [CGPoint] {
        var result: [CGPoint] = [.zero]
        guard count > 1 else { return result }
        var axial: (q: Double, r: Double) = (0, 0)
        var ring = 1
        while result.count < count {
            axial = (Double(-ring), Double(ring))  // 环起点：NW 角顶点
            for dir in directions.indices {
                for _ in 0..<ring {
                    let d = directions[dir]
                    axial = (axial.q + d.0, axial.r + d.1)
                    // axial → 平面像素（flat-top：x = step*(q + r/2), y = step*r*√3/2）
                    result.append(CGPoint(
                        x: CGFloat(step * (axial.q + axial.r / 2)),
                        y: CGFloat(step * axial.r * 0.866_025_4)
                    ))
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
        let positions = HexRing.allPositions(count: subviews.count, step: step)

        for (idx, subview) in subviews.enumerated() {
            guard idx < positions.count else { break }
            let pos = positions[idx]
            let size = subview.sizeThatFits(.unspecified)
            subview.place(
                at: CGPoint(x: center.x + pos.x - size.width / 2, y: center.y + pos.y - size.width / 2),
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
    /// 本格在内容坐标系中的位置
    let cellPosition: CGPoint
    /// 焦点中心在内容坐标系中的位置（拖拽/滚轮驱动）
    let focusPosition: CGPoint
    let onDelete: () -> Void
    @State private var showDelete = false
    @State private var isPressed = false

    /// 深度参数：一个环距 = 88pt；第 4~5 环几乎隐没
    private var depth: (scale: CGFloat, fade: Double) {
        let dist = hypot(cellPosition.x - focusPosition.x, cellPosition.y - focusPosition.y)
        let d = min(1, dist / (88.0 * 4.4))
        // 幂曲线：近环保持明亮，远环快速隐没
        let fade = max(0.03, 1.0 - 0.95 * pow(d, 1.6))
        let scale = 1.12 - 0.42 * pow(d, 1.2)
        return (scale, fade)
    }

    var body: some View {
        let depth = depth
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
        .scaleEffect(depth.scale * (isActive ? 1.06 : (isPressed ? 0.94 : 1.0)))
        .opacity(depth.fade)
        .animation(.easeOut(duration: 0.12), value: focusPosition)
        .animation(.spring(duration: 0.3), value: isActive)
        .animation(.spring(duration: 0.2), value: isPressed)
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
