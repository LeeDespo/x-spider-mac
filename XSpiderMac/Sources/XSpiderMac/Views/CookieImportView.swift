import SwiftUI

/// 上游 Account.tsx 的移植：auth_token + ct0 双字段登录，在线验证后更新账户卡。
struct CookieImportView: View {
    @Binding var isPresented: Bool
    @State private var authToken: String = ""
    @State private var ct0: String = ""
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("登录 X 账号")
                .font(.headline)

            Text("从浏览器复制 Cookie 中的 auth_token 和 ct0 两个值填入下方（浏览器 F12 → 应用/存储 → Cookie → https://x.com）")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("auth_token")
                    .font(.subheadline)
                SecureField("auth_token（约 40 位十六进制）", text: $authToken)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("ct0")
                    .font(.subheadline)
                SecureField("ct0（约 32 位以上十六进制）", text: $ct0)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(.glass)
                Button(loading ? "验证中…" : "登录") {
                    Task { await login() }
                }
                .buttonStyle(.glassProminent)
                .disabled(authToken.isEmpty || ct0.isEmpty || loading)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func login() async {
        loading = true
        errorMessage = nil
        // 上游 stringifyCookie：两个字段拼成完整 cookie 字符串
        let cookieString = Cookie.stringify([
            "auth_token": authToken,
            "ct0": ct0,
        ])
        do {
            _ = try await AppStore.shared.login(cookieString: cookieString)
            isPresented = false
        } catch {
            errorMessage = "登录失败：\(error.localizedDescription)。请检查 auth_token 和 ct0 是否正确、是否过期。"
        }
        loading = false
    }
}

#Preview {
    CookieImportView(isPresented: .constant(true))
}
