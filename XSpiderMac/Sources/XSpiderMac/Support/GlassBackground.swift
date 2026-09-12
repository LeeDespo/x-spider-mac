import SwiftUI
import AppKit

/// 内容区背景：与边栏同一条液态玻璃渲染管线（NSGlassEffectView 包 sidebar 材质）。
/// 关键差异修正：
/// - 只垫在内容区（detail），边栏底下不放，避免与边栏自身材质叠加发浑发灰
/// - isEmphasized 关掉（那是 sidebar 强调灰调的来源之一）
/// - 圆角浮动面板 → 有边缘，NSGlassEffectView 的折射扭曲才能显现
/// 滑块控制材质浓度：100 = 与边栏观感一致；0 = 完全无层（窗口透明）。
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
        container.layer?.masksToBounds = false

        // 边栏同款材质（模糊 + vibrancy 着色），关掉 emphasized 避免发灰
        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.isEmphasized = false
        effect.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            // 液态玻璃容器：边缘折射扭曲的来源（与 NavigationSplitView 边栏一致）
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.cornerRadius = 16
            glass.contentView = effect
            glass.autoresizingMask = [.width, .height]
            container.addSubview(glass)
            context.coordinator.glassView = glass
        } else {
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 16
            effect.layer?.masksToBounds = true
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
            glass?.isHidden = level == 0
            // 材质浓度随滑块；玻璃容器的折射恒定
            effect?.alphaValue = CGFloat(t)
        } else {
            effect?.alphaValue = CGFloat(t)
        }
    }
}
