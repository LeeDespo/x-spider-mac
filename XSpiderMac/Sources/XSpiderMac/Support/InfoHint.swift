import SwiftUI

/// 设置项的信息补充按钮：圈+i，点击在按钮附近弹出说明小窗
struct InfoHint: View {
    let text: String
    @State private var visible = false

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.2)) { visible.toggle() }
        } label: {
            Image(systemName: visible ? "info.circle.fill" : "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(visible ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(L("查看说明"))
        .popover(isPresented: $visible, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .lineSpacing(4)
                .frame(width: 300, alignment: .leading)
                .padding(14)
        }
    }
}

extension View {
    /// 在控件右侧（label 区域）追加信息提示按钮
    func infoHint(_ text: String) -> some View {
        HStack(spacing: 6) {
            self
            InfoHint(text: text)
        }
    }
}
