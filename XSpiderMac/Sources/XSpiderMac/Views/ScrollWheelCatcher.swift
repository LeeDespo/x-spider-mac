import SwiftUI
import AppKit

/// 触控板双指横滑捕获:deltaX 累积超过阈值回调一次(±1)。
/// macOS SwiftUI 没有原生 scrollWheel 手势,这里用 NSView 包一层;仅水平分量参与,避免与页面纵向滚动打架。
struct ScrollWheelCatcher: NSViewRepresentable {
    var onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onSwipe = onSwipe
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onSwipe = onSwipe
    }

    final class CatcherView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var accumulated: CGFloat = 0
        private var cooldownUntil = Date.distantPast

        override func scrollWheel(with event: NSEvent) {
            // 只认触控板双指(有 deltaX 分量且是精确滚动)
            let dx = event.scrollingDeltaX
            guard event.hasPreciseScrollingDeltas, abs(dx) > 0.01 else {
                super.scrollWheel(with: event)
                return
            }
            accumulated += dx
            // 命中阈值(~2/3 指幅)且冷却 300ms,防连续触发
            let threshold: CGFloat = 42
            if Date() > cooldownUntil, abs(accumulated) >= threshold {
                let direction = accumulated > 0 ? -1 : 1  // 自然滚动:手指左推 = 下一张
                onSwipe?(direction)
                accumulated = 0
                cooldownUntil = Date().addingTimeInterval(0.3)
            } else if Date() > cooldownUntil {
                // 松手衰减:慢滑不触发
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.accumulated *= 0.4
                }
            }
        }
    }
}
