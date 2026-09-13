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

    /// 快速模式（同步页用）：单次 15s 超时、最多 2 次尝试——离线/代理不可达时快速失败，
    /// 不让同步页长时间停留在「同步中」
    func requestFast(
        method: String = "GET",
        url: URL,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> NetworkResponse {
        try await request(method: method, url: url, query: query,
                          headers: headers, body: body,
                          maxAttempts: 2, perAttemptTimeout: 15)
    }

    func request(
        method: String = "GET",
        url: URL,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil,
        maxAttempts: Int? = nil,
        perAttemptTimeout: TimeInterval? = nil
    ) async throws -> NetworkResponse {
        let attemptLimit = maxAttempts ?? maxRetryCount
        var remainingRetryCount = attemptLimit
        var retryDelay: TimeInterval = 0.1
        var lastError: Error?

        while remainingRetryCount > 0 {
            do {
                let start = Date()
                let resp = try await requestInternal(
                    method: method, url: url, query: query,
                    headers: headers, body: body,
                    timeout: perAttemptTimeout
                )
                AppLogger.perf("\(method) \(url.path)", category: "NET", ms: Date().timeIntervalSince(start) * 1000, [
                    "status": "\(resp.status)",
                    "host": url.host ?? "?",
                ])
                if resp.status >= 400 {
                    throw NetworkError.httpStatus(resp.status)
                }
                return resp
            } catch {
                lastError = error
                AppLogger.warn("请求失败将重试", category: "NET", [
                    "method": method,
                    "url": url.path.isEmpty ? url.absoluteString : url.path,
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
        body: Data?,
        timeout: TimeInterval? = nil
    ) async throws -> NetworkResponse {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method.uppercased()
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        // 单次尝试限时：超时抛 timedOut（调用方快速失败,不拖同步状态）
        let doFetch: @Sendable () async throws -> NetworkResponse = { [request] in
            let (data, response) = try await self.session.data(for: request)
            let http = response as! HTTPURLResponse
            var headers: [String: [String]] = [:]
            for (key, value) in http.allHeaderFields {
                let k = key as! String
                headers[k, default: []].append(value as! String)
            }
            return NetworkResponse(status: http.statusCode, headers: headers, data: data)
        }
        if let timeout {
            request.timeoutInterval = timeout
            return try await withTimeout(timeout, doFetch)
        }
        return try await doFetch()
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


/// 竞速超时工具：deadline 先到则抛 timedOut(原任务自动作废)
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
        guard let result = try await group.next() else {
            throw URLError(.timedOut)
        }
        group.cancelAll()
        return result
    }
}
