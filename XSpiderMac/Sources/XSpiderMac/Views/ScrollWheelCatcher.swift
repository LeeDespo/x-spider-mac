import SwiftUI
import AppKit

/// 触控板双指左右滑动捕获：一次手势触发一次切换（±1），带惯性判定。
///
/// 为什么用 `NSEvent.addLocalMonitorForEvents` 而不是 NSView 子类：
/// 此前实现把 `NSViewRepresentable` 放在 `.background` 并加 `allowsHitTesting(false)`，
/// 结果该视图不参与命中测试，`scrollWheel(with:)` 根本收不到事件 —— 这就是"手势一直不触发"
/// 的原因。本地事件监视器在窗口级别接收事件，不依赖命中测试，也不吞点击/拖拽，
/// 与 AVPlayerView 等 AppKit 控件互不干扰。
///
/// 惯性判定：触控板惯性阶段（`momentumPhase` 非空）只累积不触发，且一次手势
/// （`phase` 从 .began 到 .ended）内最多触发一次，避免惯性滚动连跳多张。
struct ScrollWheelCatcher: View {
    var onSwipe: (Int) -> Void

    @State private var monitor: Any?
    /// 累积的水平位移（一次手势内）
    @State private var accumulated: CGFloat = 0
    /// 本次手势是否已触发过（防止一次滑动连跳）
    @State private var firedInGesture = false
    /// 是否处于惯性阶段（惯性期间不再触发）
    @State private var inMomentum = false

    /// 触发阈值（累积水平位移，单位是触控板 delta 的累计值）
    private let threshold: CGFloat = 60

    var body: some View {
        // 纯监视器视图：不参与命中测试、不绘制
        Color.clear
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handle(event)
            return event // 始终放行，不影响其它滚动
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // 惯性阶段：不参与判定（惯性滚动会带来大量残余 delta）
        if event.momentumPhase != [] {
            inMomentum = true
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                resetGesture()
            }
            return
        }
        if inMomentum {
            // 惯性未结束前忽略新的判定（等待 .ended 重置）
            return
        }

        switch event.phase {
        case .began:
            resetGesture()
        case .ended, .cancelled:
            resetGesture()
            return
        default:
            break
        }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        // 只认水平占优的精确滚动（触控板），避免与页面纵向滚动打架
        guard event.hasPreciseScrollingDeltas, abs(dx) > abs(dy), abs(dx) > 0.01 else { return }

        accumulated += dx

        guard !firedInGesture, abs(accumulated) >= threshold else { return }
        // 自然滚动：手指左推（内容左移）= 下一张
        let direction = accumulated > 0 ? -1 : 1
        firedInGesture = true
        accumulated = 0
        onSwipe(direction)
    }

    private func resetGesture() {
        accumulated = 0
        firedInGesture = false
        inMomentum = false
    }
}
