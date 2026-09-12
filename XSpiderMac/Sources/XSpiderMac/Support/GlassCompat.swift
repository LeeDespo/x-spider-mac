import SwiftUI

/// 液态玻璃兼容层：macOS 26+ 且设置开启时用 glassEffect；
/// 否则优雅退化为常规材质卡片（低版本系统/开关关闭均可正常运行）。
struct GlassCompat: ViewModifier {
    @State private var settingsStore = SettingsStore.shared
    var interactive: Bool = false
    var cornerRadius: CGFloat

    /// macOS 26 (Tahoe) 才有 glassEffect API
    static let supportsLiquidGlass: Bool = {
        if #available(macOS 26.0, *) { return true }
        return false
    }()

    func body(content: Content) -> some View {
        if Self.supportsLiquidGlass && settingsStore.settings.liquidGlassEnabled {
            Group {
                if interactive {
                    content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                } else {
                    content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                }
            }
        } else if GlassCompat.supportsLiquidGlass {
            // 关闭液态玻璃但系统 26+：按模糊度滑块选材质；0 = 完全透明无背景
            let blur = settingsStore.settings.glassBlur
            if blur < 5 {
                content
            } else {
                let material: Material = blur >= 67 ? .thickMaterial : (blur >= 34 ? .regularMaterial : .ultraThinMaterial)
                content
                    .background(material, in: .rect(cornerRadius: cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    }
            }
        } else {
            content
                .background(.background, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
        }
    }
}

/// 按钮玻璃样式兼容：低版本/关闭时用 bordered 玻璃感按钮
struct GlassButtonCompat: ViewModifier {
    @State private var settingsStore = SettingsStore.shared

    func body(content: Content) -> some View {
        if GlassCompat.supportsLiquidGlass && settingsStore.settings.liquidGlassEnabled {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func liquidGlass(interactive: Bool = false, cornerRadius: CGFloat) -> some View {
        modifier(GlassCompat(interactive: interactive, cornerRadius: cornerRadius))
    }

    func compatGlassButton() -> some View {
        modifier(GlassButtonCompat())
    }
}

/// 强调按钮玻璃样式兼容
struct GlassProminentButtonCompat: ViewModifier {
    @State private var settingsStore = SettingsStore.shared

    func body(content: Content) -> some View {
        if GlassCompat.supportsLiquidGlass && settingsStore.settings.liquidGlassEnabled {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    func compatGlassProminentButton() -> some View {
        modifier(GlassProminentButtonCompat())
    }
}
