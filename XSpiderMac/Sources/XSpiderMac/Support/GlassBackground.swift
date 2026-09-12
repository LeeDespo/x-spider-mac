import SwiftUI
import AppKit

/// 内容区背景：与边栏同一条液态玻璃渲染管线（NSGlassEffectView 包 sidebar 材质）。
/// 要点（对照边栏的真实观感调校）：
/// - 玻璃容器 style = .regular（折射扭曲的来源），contentView 为空 → 玻璃直接对背景取景，
///   不会被材质层挡住折射（之前拉满时材质 alpha=1 把折射全盖住，观感"发灰浑浊"）
/// - 材质层独立于玻璃放在后面：滑块控制**材质透明度**，第二低档（约 t=0.12-0.2）即边栏观感；
///   拉满 = 材质全显（最不透但玻璃仍在最上层折射）
/// - 全出血铺满整窗（无留边）→ 滚动条轨道、底缘等区域不再露出透明窗口底；
///   玻璃折射覆盖整个窗口表面
/// - 顶栏区域全覆盖（面板延伸到 titlebar 底下），顶栏随滑块变化
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

        // 材质层（vibrancy 着色，控制浓度）——玻璃后面
        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.isEmphasized = false
        effect.autoresizingMask = [.width, .height]

        // 玻璃容器（折射 + 玻璃质感）——最上层，contentView 为空只对背后取景
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.cornerRadius = 0
            glass.style = .regular
            glass.autoresizingMask = [.width, .height]
            container.addSubview(effect)
            container.addSubview(glass)
            context.coordinator.glassView = glass
        } else {
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 0
            effect.layer?.masksToBounds = true
            container.addSubview(effect)
        }
        context.coordinator.effectView = effect
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 最低档 20（0 档已移除）：材质浓度下限，玻璃折射层恒定显示
        let t = Double(min(100, max(20, level))) / 100
        context.coordinator.effectView?.alphaValue = CGFloat(t)
    }
}
