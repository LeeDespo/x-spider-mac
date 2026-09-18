import SwiftUI

/// 可折叠正文：超过 `collapsedLines` 行时折叠，并给出「显示更多 / 收起」入口。
///
/// 为什么需要：时间线卡片原先用 `.lineLimit(6)` + `fixedSize(vertical:)`，
/// 长推文被静默截断且**没有展开入口**——用户看不到全文也无从得知被截断了。
/// 评论区同样如此，且长回复会把整个列表撑得很长。
///
/// 是否显示按钮用**字符数**近似判断，而不是测量真实行数：
/// 精确行数需要在布局后测量（`GeometryReader` / `onGeometryChange`），
/// 对列表里每条正文都做测量代价过高。字符数阈值配合行数上限足够可靠：
/// 宁可多给一个按钮（点开发现是全文），也不要漏掉本该有的入口。
struct ExpandableText: View {
    let text: String
    /// 折叠时显示的最大行数
    var collapsedLines: Int = 6
    /// 超过多少字符才认为"可能需要展开"（近似判据，见类型说明）
    var expandThreshold: Int = 180
    var font: Font = .callout
    /// 是否允许选择文本（详情卡里需要，列表中会干扰滚动）
    var selectable: Bool = false

    @State private var expanded = false
    /// hover 时才显示"显示更多"，避免每张卡片都挂一个按钮视觉噪声
    @State private var hovering = false

    private var needsToggle: Bool { text.count > expandThreshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if selectable {
                    Text(text).textSelection(.enabled)
                } else {
                    Text(text)
                }
            }
            .font(font)
            .lineLimit(expanded ? nil : collapsedLines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 按钮只在"确实可能被截断"时出现；折叠态常显（提示有更多内容），
            // 展开态需 hover（避免占用视觉空间）
            if needsToggle && (!expanded || hovering) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Text(expanded ? L("收起") : L("显示更多"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
    }
}
