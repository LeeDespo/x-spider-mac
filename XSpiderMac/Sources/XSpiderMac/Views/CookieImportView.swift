import SwiftUI

struct CookieImportView: View {
    @Binding var isPresented: Bool
    @State private var cookieText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入 Cookie")
                .font(.headline)

            Text("粘贴从浏览器复制的 Cookie 字符串（需包含 auth_token 与 ct0）")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $cookieText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))

            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(.glass)
                Button("导入") {
                    AppStore.shared.cookieString = cookieText
                    isPresented = false
                }
                .buttonStyle(.glassProminent)
                .disabled(cookieText.isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
    }
}

#Preview {
    CookieImportView(isPresented: .constant(true))
}
