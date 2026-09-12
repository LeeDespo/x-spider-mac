import SwiftUI
import AppKit

/// 侧栏同款效果背景：NSVisualEffectView(.sidebar, behindWindow) 提供与边栏一致的
/// 模糊 + 边缘折射扭曲；玻璃开启时再叠一层官方 glassEffect 增加液态玻璃光泽。
/// 滑块 0–100 控制整体强度：拉满 = 边栏同款浓度，拉到 0 = 完全无背景层。
struct SidebarStyleBackground: NSViewRepresentable {
    var level: Int // 0–100

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // 与边栏完全相同的材质/混合模式/状态
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // 滑块 → 强度：用 alpha 控制背景层浓度（1.0 = 边栏同款）
        let t = Double(min(100, max(0, level))) / 100
        view.alphaValue = CGFloat(t == 0 ? 0 : max(0.12, t))
    }
}

/// 应用背景层：blur 滑块全模式统一控制
/// - 玻璃开：sidebar 材质打底（与边栏一致）+ glassEffect 光泽层
/// - 玻璃关：仅 sidebar 材质
struct LiquidGlassBackground: View {
    var blur: Double
    var glassEnabled: Bool

    var body: some View {
        let level = Int(blur.rounded())
        ZStack {
            if level > 0 {
                // 打底：与边栏同款模糊/折射
                SidebarStyleBackground(level: level)
                // 光泽层：液态玻璃开启时叠加官方玻璃效果（不遮挡 sidebar 材质的模糊）
                if glassEnabled, GlassCompat.supportsLiquidGlass, #available(macOS 26.0, *) {
                    Rectangle()
                        .fill(.clear)
                        .glassEffect(.regular, in: .rect)
                        .opacity(0.25 + blur / 100 * 0.35)
                }
            }
        }
    }
}
