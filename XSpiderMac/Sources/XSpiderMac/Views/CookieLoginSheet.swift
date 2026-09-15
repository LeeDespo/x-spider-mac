import SwiftUI
import WebKit

/// 登录方式选择弹窗：内嵌 WebView 登录 / 手动输入 Cookie。
/// 点登录或切换账号时由 AppStore/ContentView 弹出。
struct CookieLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    enum Mode { case choose, webView, manual }
    @State private var mode: Mode = .choose
    @State private var capturedCookies: [(name: String, value: String)] = []

    var body: some View {
        Group {
            switch mode {
            case .choose: chooseView
            case .webView: webViewView
            case .manual: manualView
            }
        }
        .frame(width: mode == .webView ? 680 : 460, height: mode == .webView ? 560 : 380)
    }

    // MARK: - 方式选择

    private var chooseView: some View {
        VStack(spacing: 22) {
            Text(L("登录 X 账号"))
                .font(.title2.weight(.semibold))
                .padding(.top, 28)

            Text(L("选择登录方式"))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                optionButton(icon: "globe", title: L("打开登录页面"), subtitle: L("在应用内打开 x.com 登录，自动获取 Cookie")) {
                    mode = .webView
                }
                optionButton(icon: "doc.text", title: L("手动输入 Cookie"), subtitle: L("从浏览器复制 auth_token 与 ct0 粘贴")) {
                    mode = .manual
                }
            }
            .padding(.horizontal, 30)

            Spacer()

            HStack {
                Button(L("取消")) { dismiss() }
                    .compatGlassButton()
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private func optionButton(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .liquidGlass(interactive: true, cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - WebView 登录

    private var webViewView: some View {
        VStack(spacing: 0) {
            HStack {
                Button(L("返回")) { mode = .choose }
                Spacer()
                Text(L("登录 x.com，登录成功后自动获取 Cookie"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("完成")) { captureAndApply() }
                    .disabled(capturedCookies.isEmpty)
            }
            .padding(12)

            if !capturedCookies.isEmpty {
                Text(L("已捕获登录 Cookie，点击「完成」应用"))
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            XLoginWebView(onCookiesChanged: { cookies in
                capturedCookies = cookies
            })
        }
    }

    // MARK: - 手动输入(复用既有表单)

    private var manualView: some View {
        VStack(spacing: 0) {
            HStack {
                Button(L("返回")) { mode = .choose }
                Spacer()
            }
            .padding(12)
            CookieImportForm()
        }
    }

    /// 从捕获的 cookie 里取 auth_token + ct0 组装完整 cookie 字符串
    private func captureAndApply() {
        let dict = Dictionary(uniqueKeysWithValues: capturedCookies.map { ($0.name, $0.value) })
        guard let authToken = dict["auth_token"], let ct0 = dict["ct0"] else { return }
        AppStore.shared.cookieString = "auth_token=\(authToken); ct0=\(ct0)"
        dismiss()
    }
}

/// x.com 登录 WebView：监听 cookie 变化,捕获 auth_token/ct0
struct XLoginWebView: NSViewRepresentable {
    var onCookiesChanged: ([(name: String, value: String)]) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        // 桌面 UA:避免跳转移动版页面
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "https://x.com/login")!))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: XLoginWebView
        init(_ parent: XLoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            capture(webView)
        }

        private func capture(_ webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let relevant = cookies.compactMap { c -> (name: String, value: String)? in
                    guard c.domain.contains("x.com"),
                          c.name == "auth_token" || c.name == "ct0" else { return nil }
                    return (c.name, c.value)
                }
                if relevant.count >= 2 {
                    self.parent.onCookiesChanged(relevant)
                }
            }
        }
    }
}
