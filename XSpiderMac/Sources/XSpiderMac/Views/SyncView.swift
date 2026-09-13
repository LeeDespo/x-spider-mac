import SwiftUI
import AppKit

/// 同步页：蜂窝头像云（六边形环展开）。
/// - 中心锚定：蜂窝与状态卡共用同一锚点（GeometryReader 中心 = body overlay 中心），聚焦中心即页面中心
/// - 尺寸：中心160% → 一环150% → 二环120% → 三环105% → 其余100%（按距离分段线性插值）
/// - 图层（自下而上）：占位/垫圈（白色普通材质实心圆 + 阴影）→ 头像（外环先画、内环盖上）
///   → 完成徽标 → 悬停控件（左上删除 / 右上同步 / 底部昵称标签）→ 状态卡（body overlay，最顶层）
/// - 顶栏：标题保留；元素滑入顶栏区域时渐进模糊（景深式虚化，不做硬裁剪）
/// - 占位：白色材质圈补满「当前最大环 + 1 环」，上限 6 环；头像底下垫 105% 同材质圈（最底层）
struct SyncView: View {
    @State private var store = SyncStore.shared
    @State private var showAddSheet = false
    @State private var input = ""
    @State private var appStore = AppStore.shared
    /// 页面可视尺寸（状态卡 3/4 高度定位与平移钳制用）
    @State private var viewportSize: CGSize = .zero
    /// 蜂窝内容的平移偏移（拖拽/滚轮/方向键驱动）
    @State private var panOffset: CGSize = .zero
    /// 滚轮 + 方向键事件监听
    @State private var scrollMonitor: Any?
    /// 当前悬停的用户下标（悬停控件层只渲染这一个的按钮/标签）
    @State private var hoveredIndex: Int?
    /// 悬停桥区激活中（鼠标从头像移到按钮/标签上时防止控件消失）
    @State private var chromeHoverActive = false
    /// 悬停去抖任务（可取消——切换悬停目标时旧任务立即失效，消除卡顿）
    @State private var hoverDebounceTask: Task<Void, Never>?

    /// 占位圈上限：补满当前最大用户环 + 5 环，封顶 6 环（一环用户也直接补到 6 环）
    private var placeholderRingLimit: Int {
        let maxUserRing = store.users.isEmpty ? 0 : HexRing.ringNumber(index: store.users.count - 1)
        return min(6, maxUserRing + 5)
    }

    /// 蜂窝总格数（含占位）
    private var totalSlots: Int {
        3 * placeholderRingLimit * (placeholderRingLimit + 1) + 1
    }

    var body: some View {
        honeycomb
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
                // 状态卡行：卡片中心对准页面中心（按钮组只向右延伸 104pt，整组右移半个按钮组 52pt）
                HStack(spacing: 8) {
                    progressBarCard
                    addButton
                    syncButton
                }
                .offset(x: 52, y: viewportSize.height * 0.25)
            }
            .navigationTitle(L("同步"))
            .sheet(isPresented: $showAddSheet) { addSheet }
            .task {
                store.syncOnLaunchIfNeeded()
            }
    }

    // MARK: - 蜂窝

    private var honeycomb: some View {
        GeometryReader { geo in
            // 蜂窝内容中心 = GeometryReader 中心 = 状态卡 overlay 中心（同一锚点，聚焦中心即页面中心）
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // 平移极限只由用户头像环数决定（垫圈只是装饰，不参与边界）
            let D = HexRing.diameter(userCount: max(1, store.users.count))

            ZStack {
                // ── 底层：白色普通材质实心圆（头像垫圈 105% + 空位占位圈）──
                ForEach(0..<totalSlots, id: \.self) { idx in
                    let rel = HexRing.position(index: idx)
                    let p = CGPoint(x: center.x + panOffset.width + rel.x,
                                    y: center.y + panOffset.height + rel.y)
                    let size = HexRing.cellSize(distanceToFocus: hypot(rel.x + panOffset.width,
                                                                       rel.y + panOffset.height))
                    let padSize = idx < store.users.count ? size * 1.05 : size
                    padCircle(size: padSize, edgeT: edgeFactor(p, geo.size))
                        .position(p)
                }

                // ── 头像层：外环先画、内环后画（内环头像永远盖住外环）──
                ForEach(Array(store.users.enumerated()).reversed(), id: \.element.id) { idx, user in
                    let rel = HexRing.position(index: idx)
                    let p = CGPoint(x: center.x + panOffset.width + rel.x,
                                    y: center.y + panOffset.height + rel.y)
                    let size = HexRing.cellSize(distanceToFocus: hypot(rel.x + panOffset.width,
                                                                       rel.y + panOffset.height))
                    avatarView(user, index: idx, size: size, edgeT: edgeFactor(p, geo.size))
                        .position(p)
                }

                // ── 完成徽标层（悬停时隐藏，让位给按钮组）──
                ForEach(Array(store.users.enumerated()), id: \.element.id) { idx, user in
                    if store.completedUsers.contains(user.screenName) && hoveredIndex != idx {
                        let rel = HexRing.position(index: idx)
                        let p = CGPoint(x: center.x + panOffset.width + rel.x,
                                        y: center.y + panOffset.height + rel.y)
                        let size = HexRing.cellSize(distanceToFocus: hypot(rel.x + panOffset.width,
                                                                           rel.y + panOffset.height))
                        completionBadge
                            .position(CGPoint(x: p.x + size / 2 + 6, y: p.y - size / 2 - 6))
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }

                // ── 悬停控件层（所有头像之上、状态卡之下）──
                if let hIdx = hoveredIndex, hIdx < store.users.count {
                    let user = store.users[hIdx]
                    let rel = HexRing.position(index: hIdx)
                    let p = CGPoint(x: center.x + panOffset.width + rel.x,
                                    y: center.y + panOffset.height + rel.y)
                    let size = HexRing.cellSize(distanceToFocus: hypot(rel.x + panOffset.width,
                                                                       rel.y + panOffset.height))
                    cellChrome(user: user, index: hIdx, size: size)
                        .position(p)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .mask {
                // 横向裁剪（防溢出到侧栏）；纵向放行——图标可滑入顶栏下，靠边缘模糊虚化
                Rectangle()
                    .frame(width: geo.size.width, height: geo.size.height + 1600)
            }
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
                installScrollMonitor()
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

    // MARK: - 元素视图

    /// 头像（同步中 = 强调色描边环；五环外只有 tooltip）
    @ViewBuilder
    private func avatarView(_ user: SyncUser, index: Int, size: CGFloat, edgeT: Double) -> some View {
        let isActive = store.phase == .syncing && store.currentUser == user.screenName
        let avatar = CachedAvatarView(urlString: user.avatar, size: size)
            .clipShape(Circle())
            .overlay {
                if isActive {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-6)
                }
            }
        let hovered = avatar
            .onHover { h in
                guard HexRing.ringNumber(index: index) <= 5 else { return }
                if h {
                    withAnimation(.spring(duration: 0.18)) { hoveredIndex = index }
                } else {
                    // 去抖：给悬停桥区（按钮/标签）接管的时间；新悬停取消旧任务，切目标不卡
                    hoverDebounceTask?.cancel()
                    hoverDebounceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 90_000_000)
                        guard !Task.isCancelled else { return }
                        if hoveredIndex == index && !chromeHoverActive {
                            withAnimation(.spring(duration: 0.15)) { hoveredIndex = nil }
                        }
                    }
                }
            }
            .help(HexRing.ringNumber(index: index) > 5 ? user.name : "")
        // 边缘模糊：始终挂载（条件挂载会让进入/离开边缘带时视图树结构突变 → 闪烁缩动）
        return hovered
            .blur(radius: 8 * edgeT)
            .opacity(1 - 0.4 * edgeT)
    }

    /// 白色实心圆（占位圈 / 头像垫圈）：静态颜色合成，不做材质/阴影/模糊（127 个圈的性能命门）
    @ViewBuilder
    private func padCircle(size: CGFloat, edgeT: Double) -> some View {
        let circle = Circle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.92), location: 0),
                        .init(color: Color(white: 0.97, opacity: 0.82), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
            .frame(width: size, height: size)
        return circle
            .blur(radius: 8 * edgeT)
            .opacity(1 - 0.4 * edgeT)
    }

    /// 悬停控件：左上删除、右上同步（已完成=绿）、底部昵称标签；带悬停桥区防闪抖
    @ViewBuilder
    private func cellChrome(user: SyncUser, index: Int, size: CGFloat) -> some View {
        let isDone = store.completedUsers.contains(user.screenName)
        ZStack {
            hoverBridge(size: size)
            glassMiniButton(icon: "xmark", tint: .red, help: L("移除该用户")) {
                withAnimation(.spring(duration: 0.25)) { store.removeUser(user.screenName) }
            }
            .offset(x: -size / 2 - 8, y: -size / 2 - 8)
            .transition(.scale(scale: 0.6).combined(with: .opacity))

            glassMiniButton(icon: "arrow.triangle.2.circlepath",
                            tint: isDone ? Color.green : Color.accentColor,
                            help: L("同步该用户")) {
                withAnimation(.spring(duration: 0.3)) { store.startSync(target: [user]) }
            }
            .offset(x: size / 2 + 8, y: -size / 2 - 8)
            .transition(.scale(scale: 0.6).combined(with: .opacity))

            Text("\(user.name)-@\(user.screenName)")
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .liquidGlass(interactive: false, cornerRadius: 12)
                .fixedSize()
                .offset(y: size / 2 + 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        // 悬停桥区：命中形是 ZStack 首子视图（透明但参与 hit 联合）——
        // 鼠标从头像移到任一控件上时 hover 持续 true，控件永不中途消失
        .onHover { h in
            chromeHoverActive = h
            if !h {
                hoverDebounceTask?.cancel()
                hoverDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    guard !Task.isCancelled else { return }
                    if !chromeHoverActive && hoveredIndex == index {
                        withAnimation(.spring(duration: 0.15)) { hoveredIndex = nil }
                    }
                }
            }
        }
    }

    /// 边缘模糊系数：距可视区边缘 90pt 内从 0 → 1（滑入顶栏下 = 全模糊）
    private func edgeFactor(_ p: CGPoint, _ viewport: CGSize) -> Double {
        let margin: CGFloat = 90
        let d = min(p.x, p.y, viewport.width - p.x, viewport.height - p.y)
        return Double(max(0, min(1, 1 - d / margin)))
    }

    // MARK: - 平移（拖拽 / 滚轮 / 方向键）

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

    /// 滚轮/触控板双指滑动 + 方向键 → 平移蜂窝（弹窗打开时放行；闭包内实时读取最新状态）
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { event in
            guard showAddSheet == false, NSApp.keyWindow?.sheets.isEmpty ?? true else { return event }
            let D = HexRing.diameter(userCount: max(1, store.users.count))
            if event.type == .scrollWheel {
                let dx = -event.scrollingDeltaX * 2.2
                let dy = -event.scrollingDeltaY * 2.2
                guard abs(dx) > 0.1 || abs(dy) > 0.1 else { return event }
                withAnimation(.easeOut(duration: 0.12)) {
                    panOffset = clampedPan(panOffset, viewport: viewportSize, content: D, dx: dx, dy: dy)
                }
                return nil
            }
            // 方向键平移（无系统焦点环）
            let step: CGFloat = 44
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch event.keyCode {
            case 123: dx = step
            case 124: dx = -step
            case 125: dy = -step
            case 126: dy = step
            default: return event
            }
            withAnimation(.spring(duration: 0.25)) {
                panOffset = clampedPan(panOffset, viewport: viewportSize, content: D, dx: dx, dy: dy)
            }
            return nil
        }
    }

    /// 悬停桥区命中形：头像圆 + 顶部按钮横带 + 底部标签横带（联合 hit 区，近乎透明仍可命中）
    private func hoverBridge(size: CGFloat) -> some View {
        let pad = size / 2 + 10
        return ZStack {
            Circle().fill(Color.white.opacity(0.001)).frame(width: size, height: size)
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: size + 2 * pad + 56, height: 36)
                .offset(y: -pad)
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: 260, height: 26)
                .offset(y: pad + 8)
        }
    }

    // MARK: - 悬浮进度卡（下载提示框同款：胶囊形、46pt 高；idle 最窄，同步时左右对称拉长）

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

    // MARK: - 中性玻璃按钮（新增 / 同步，44pt，与卡片同高族）

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
    }

    @ViewBuilder
    private func glassDiscButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
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
                            Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        }
                }
                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 右上角小号玻璃圆钮（32pt，玻璃材质 + 阴影，与状态卡同族）
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

    /// 完成徽标：绿色玻璃小圆 + 白勾（24pt 固定，悬停淡出）
    private var completionBadge: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Color.green.opacity(0.85))
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
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
                .compatGlassProminentButton()
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - 六边形环数学（布局与视图共用的唯一事实来源，参考 redblobgames rings 公式）

enum HexRing {
    /// 六方向轴向步进（N NE SE S SW NW）
    static let directions: [(Double, Double)] = [
        (0, -1), (1, -1), (1, 0), (0, 1), (-1, 1), (-1, 0),
    ]

    /// 基准头像直径
    static let baseSize: CGFloat = 68

    /// 每环头像直径：中心 160% → 一环 150% → 二环 120% → 三环 105% → 其余 100%
    static func cellSize(ring: Int) -> CGFloat {
        switch ring {
        case 0: return baseSize * 1.60
        case 1: return baseSize * 1.50
        case 2: return baseSize * 1.20
        case 3: return baseSize * 1.05
        default: return baseSize * 1.0
        }
    }

    /// 距焦点距离 → 尺寸：在各环半径锚点间分段线性插值（连续，且与环表端点一致）
    static func cellSize(distanceToFocus dist: CGFloat) -> CGFloat {
        let anchors: [(d: CGFloat, s: CGFloat)] = [
            (0, cellSize(ring: 0)),
            (ringRadius(ring: 1), cellSize(ring: 1)),
            (ringRadius(ring: 2), cellSize(ring: 2)),
            (ringRadius(ring: 3), cellSize(ring: 3)),
            (ringRadius(ring: 4), cellSize(ring: 4)),
        ]
        if dist <= 0 { return anchors[0].s }
        if dist >= anchors[4].d { return anchors[4].s }
        for i in 1..<anchors.count where dist <= anchors[i].d {
            let a0 = anchors[i - 1], a1 = anchors[i]
            let t = (dist - a0.d) / (a1.d - a0.d)
            return a0.s + (a1.s - a0.s) * t
        }
        return anchors[4].s
    }

    /// 环间距：一环 25pt、每环 ×1.5 递增；五环外恒定（25×1.5⁴≈126.6pt，直接内联不递归）
    static func ringGap(ring: Int) -> CGFloat {
        if ring >= 5 { return 25 * pow(1.5, 4) }
        return 25 * pow(1.5, Double(ring - 1))
    }

    /// 环 r 的中心距（环 0→1 = 中心尺寸/2 + 环1尺寸/2 + 间隙；环间 = 两环尺寸/2 之和 + 间隙）
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

    /// 蜂窝整体直径（按最大环半径 × 2 + 该环格径 + 余量）
    static func diameter(userCount: Int) -> CGFloat {
        let rings = ringNumber(index: max(0, userCount - 1))
        guard rings > 0 else { return cellSize(ring: 0) + 40 }
        return ringRadius(ring: rings) * 2 + cellSize(ring: rings) + 24
    }

    /// 第 index 格（0 起）所在环号（环 k 恰好 6k 格：累计 3k(k+1)+1）
    static func ringNumber(index: Int) -> Int {
        guard index > 0 else { return 0 }
        return Int(ceil((-3.0 + (9.0 + 12.0 * Double(index)).squareRoot()) / 6.0))
    }

    /// 全量位置缓存（6 环封顶 127 格）：布局每帧取 O(1)，避免逐格全量重算
    private static let cachedPositions = SafePositionCache()

    /// 第 index 格相对蜂窝中心的平面位置
    static func position(index: Int) -> CGPoint {
        let count = index + 1
        if let cached = cachedPositions.get(count) { return cached[index] }
        let positions = allPositions(count: count)
        cachedPositions.set(count, positions)
        return positions[index]
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
                    // 轴向 → 平面（flat-top），除以 ring 归一化到该环半径
                    result.append(CGPoint(
                        x: radius * CGFloat(axial.q + axial.r / 2) / CGFloat(ring),
                        y: radius * CGFloat(axial.r) * 0.866_025_4 / CGFloat(ring)
                    ))
                    if result.count >= count { return result }
                }
            }
            ring += 1
        }
        return result
    }
}

/// 线程安全的位置缓存（HexRing 静态缓存用，Swift 6 并发检查合规）
final class SafePositionCache: @unchecked Sendable {
    private var storage: [Int: [CGPoint]] = [:]
    private let lock = NSLock()

    func get(_ key: Int) -> [CGPoint]? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: Int, _ value: [CGPoint]) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }
}
