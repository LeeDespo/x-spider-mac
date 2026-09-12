import SwiftUI
import AppKit

/// 边栏同款背景：macOS 26 上用 NSGlassEffectView（液态玻璃：折射扭曲 + 玻璃模糊）
/// 包裹 NSVisualEffectView(.sidebar)（边栏同款 vibrancy 材质），
/// 渲染管线与 NavigationSplitView 边栏一致。
/// 滑块控制 sidebar 材质浓度：100 = 与边栏完全一致；越低越透（玻璃折射保持）；
/// 0 = 无背景层（NSWindow 透明底 → 完全透明）。
struct SidebarStyleBackground: NSViewRepresentable {
    /// 0–100
    var level: Int

    final class Coordinator {
        var glassView: NSView?
        var effectView: NSVisualEffectView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true

        // 边栏同款材质（模糊 + vibrancy 着色）
        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.isEmphasized = true
        effect.autoresizingMask = [.width, .height]
        effect.frame = container.bounds

        if #available(macOS 26.0, *) {
            // 液态玻璃容器：边缘折射扭曲 + Tahoe 玻璃渲染（边栏的真实来源）
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.cornerRadius = 0
            glass.contentView = effect
            glass.autoresizingMask = [.width, .height]
            container.addSubview(glass)
            context.coordinator.glassView = glass
        } else {
            container.addSubview(effect)
        }
        context.coordinator.effectView = effect
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let t = Double(min(100, max(0, level))) / 100
        let effect = context.coordinator.effectView
        if #available(macOS 26.0, *) {
            let glass = context.coordinator.glassView
            // 0 = 连玻璃一起隐藏（完全透明）；>0 玻璃折射恒定，sidebar 材质浓度随滑块
            glass?.isHidden = level == 0
            effect?.alphaValue = CGFloat(t)
        } else {
            effect?.alphaValue = CGFloat(t)
        }
    }
}
