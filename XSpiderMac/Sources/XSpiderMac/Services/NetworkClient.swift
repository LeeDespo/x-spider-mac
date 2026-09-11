import Foundation

/// 上游 ipc/network.ts 的移植：16 次重试、指数退避（100ms 起、16s 封顶）、代理三态。
actor NetworkClient {
    private let maxRetryCount = 16
    private let maxRetryDelay: TimeInterval = 16

    private var proxy: ProxySettings
    private var session: URLSession

    init(proxy: ProxySettings = ProxySettings()) {
        self.proxy = proxy
        let config = URLSessionConfiguration.default
        // 401 根因修复：禁用共享 Cookie 存储，防止系统自动注入的 guest cookie
        // 覆盖请求头里手动设置的 auth_token/ct0 Cookie
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.apply(proxy: proxy)
        self.session = URLSession(configuration: config)
    }

    func request(
        method: String = "GET",
        url: URL,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> NetworkResponse {
        var remainingRetryCount = maxRetryCount
        var retryDelay: TimeInterval = 0.1
        var lastError: Error?

        while remainingRetryCount > 0 {
            do {
                let start = Date()
                let resp = try await requestInternal(
                    method: method, url: url, query: query,
                    headers: headers, body: body
                )
                AppLogger.perf("\(method) \(url.absoluteString)", category: "NET", ms: Date().timeIntervalSince(start) * 1000, ["status": "\(resp.status)"])
                if resp.status >= 400 {
                    throw NetworkError.httpStatus(resp.status)
                }
                return resp
            } catch {
                lastError = error
                AppLogger.warn("请求失败将重试", category: "NET", [
                    "url": url.absoluteString,
                    "error": error.localizedDescription,
                    "remains": "\(remainingRetryCount)",
                ])
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                remainingRetryCount -= 1
                retryDelay = min(retryDelay * 2, maxRetryDelay)
            }
        }

        throw lastError ?? NetworkError.unknown
    }

    private func requestInternal(
        method: String,
        url: URL,
        query: [String: String],
        headers: [String: String],
        body: Data?
    ) async throws -> NetworkResponse {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method.uppercased()
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse

        var respHeaders: [String: [String]] = [:]
        for (key, value) in http.allHeaderFields {
            let k = key as! String
            respHeaders[k, default: []].append(value as! String)
        }

        return NetworkResponse(status: http.statusCode, headers: respHeaders, data: data)
    }
}

enum NetworkError: LocalizedError {
    case unknown
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unknown: return "未知网络错误"
        case .httpStatus(let code): return "HTTP \(code)"
        }
    }
}

struct NetworkResponse: Sendable {
    let status: Int
    let headers: [String: [String]]
    let data: Data

    func json() throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [])
    }

    func text() -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

extension URLSessionConfiguration {
    /// 代理三态：关闭 / 系统 / 手动（对应上游 proxy.enable + proxy.useSystem + proxy.url）
    func apply(proxy: ProxySettings) {
        if !proxy.enable {
            connectionProxyDictionary = [:]
            return
        }
        if proxy.useSystem {
            connectionProxyDictionary = nil
            return
        }
        guard let url = URL(string: proxy.url), let host = url.host else { return }
        let port = url.port ?? 80
        connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: host,
            kCFNetworkProxiesHTTPSPort: port,
        ]
    }
}
