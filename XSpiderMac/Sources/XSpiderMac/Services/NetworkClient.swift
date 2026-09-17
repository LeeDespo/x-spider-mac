import Foundation

/// 上游 ipc/network.ts 的移植：重试 + 指数退避 + 代理三态。
///
/// 与上游的必要差异：上游是浏览器环境（fetch 有天然超时，且用户能刷新页面），
/// 照搬"16 次重试"在 macOS 上不可接受 —— 实测最坏耗时约
/// `16 × 60s(系统默认超时) + 153s(退避累计) ≈ 19 分钟`，
/// 表现为"一直加载中、永远不失败、也无法重试"。
/// 因此这里改为**总预算制**：次数与总耗时双限，谁先到谁停。
actor NetworkClient {
    /// 最大尝试次数（含首次）
    private let maxRetryCount = 4
    /// 单次尝试超时（未显式指定时使用；不再依赖系统默认 60s）
    private let defaultAttemptTimeout: TimeInterval = 10
    /// 整个重试链的总时间预算：超过即放弃，让调用方显示失败并允许用户重试
    private let totalBudget: TimeInterval = 25
    private let maxRetryDelay: TimeInterval = 8

    private var proxy: ProxySettings
    private var session: URLSession

    init(proxy: ProxySettings = ProxySettings()) {
        self.proxy = proxy
        let config = URLSessionConfiguration.default
        // 401 根因修复：禁用共享 Cookie 存储，防止系统自动注入的 guest cookie
        // 覆盖请求头里手动设置的 auth_token/ct0 Cookie
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        // 显式超时：不再依赖系统默认（request 60s / resource 7 天）
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        // 代理波动时快速失败，而不是长期挂着半开连接
        config.waitsForConnectivity = false
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
        body: Data? = nil,
        bypassGate: Bool = false
    ) async throws -> NetworkResponse {
        try await request(method: method, url: url, query: query,
                          headers: headers, body: body,
                          maxAttempts: 2, perAttemptTimeout: 15,
                          bypassGate: bypassGate)
    }

    /// 上游 network.ts request：16 次重试、指数退避（100ms 起、16s 封顶）。
    /// 与上游的唯一必要差异是取消语义——上游 delay() 必然真实等待，而 Swift 的
    /// `Task.sleep` 在任务已取消时立即抛错返回；若把取消当作可重试错误，一次取消会在
    /// 同一毫秒内空转 16 次重试（实测日志 5400 行取消重试），是限流风暴的放大器。
    /// 因此：取消 → 立即抛 CancellationError，不重试、不计次。
    /// 429 另计：重试限流响应纯属放大，最多 3 次退避后放弃，交给调用方停本轮。
    func request(
        method: String = "GET",
        url: URL,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil,
        maxAttempts: Int? = nil,
        perAttemptTimeout: TimeInterval? = nil,
        bypassGate: Bool = false
    ) async throws -> NetworkResponse {
        let attemptLimit = maxAttempts ?? maxRetryCount
        var remainingRetryCount = attemptLimit
        var retryDelay: TimeInterval = 0.1
        var rateLimitRetries = 0
        var lastError: Error?
        // 端点类别：驱动闸门（令牌桶/串行/熔断）与被动状态上报
        let kind = RequestGate.Kind.classify(path: url.path)
        var acquired = false
        // 总预算起点：超过即放弃（含退避等待），避免"加载到永远"
        let startedAt = Date()
        // 全局请求超时用显式值，不再依赖系统默认 60s
        let attemptTimeout = perAttemptTimeout ?? defaultAttemptTimeout

        while remainingRetryCount > 0 {
            if Task.isCancelled { throw CancellationError() }
            // 总预算用尽：立刻失败，让调用方展示"加载失败 + 重试"
            if Date().timeIntervalSince(startedAt) > totalBudget {
                AppLogger.warn("重试总预算用尽,放弃本次请求", category: "NET", [
                    "url": url.path,
                    "elapsedSec": String(format: "%.1f", Date().timeIntervalSince(startedAt)),
                ])
                throw lastError ?? NetworkError.timedOut
            }
            do {
                // 闸门（令牌桶 + 同端点串行 + 熔断短路）。熔断/取消异常直接上抛，
                // 不进入重试，避免"越限越试"。
                // bypassGate：仅用于用户主动点的「重试」探测——那是明确的用户意图，
                // 不该被限速排队拖住，否则按钮要等一个时间窗才有反应。
                if !acquired, !bypassGate {
                    try await Self.gate.acquire(kind: kind)
                    acquired = true
                }
                let start = Date()
                let resp = try await requestInternal(
                    method: method, url: url, query: query,
                    headers: headers, body: body,
                    timeout: attemptTimeout
                )
                AppLogger.perf("\(method) \(url.path)", category: "NET", ms: Date().timeIntervalSince(start) * 1000, [
                    "status": "\(resp.status)",
                    "host": url.host ?? "?",
                ])
                await Self.gate.release(kind: kind)
                acquired = false
                if resp.status >= 400 {
                    if resp.status == 429 {
                        let retryAfter = Self.retryAfter(resp)
                        // 被动上报：账号限流 + 该类端点熔断（不主动探测，仅响应真实 429）
                        await Self.gate.noteRateLimited(kind: kind, retryAfter: retryAfter)
                        let gateOpen = await Self.gate.isBreakerOpen()
                        let breakerDeadline = await Self.gate.nearestBreakerDeadline()
                        await MainActor.run {
                            // 用熔断的真实截止时间驱动标签，保证"标签消失"与"请求恢复"同时发生
                            AccountStatusStore.shared.noteRateLimited(until: breakerDeadline)
                            AccountStatusStore.shared.breakerOpen = gateOpen
                        }
                        rateLimitRetries += 1
                        guard rateLimitRetries <= Self.maxRateLimitRetries else {
                            AppLogger.warn("限流(429)重试已用尽,停止本轮", category: "NET", [
                                "url": url.path, "retries": "\(rateLimitRetries)",
                            ])
                            throw NetworkError.httpStatus(429)
                        }
                        // 优先听服务端 Retry-After;否则指数退避(1s 起、16s 封顶)
                        let wait = retryAfter ?? min(max(retryDelay, 1.0) * 2, maxRetryDelay)
                        AppLogger.warn("触发限流(429),退避后重试", category: "NET", [
                            "url": url.path, "waitMs": "\(Int(wait * 1000))",
                            "retries": "\(rateLimitRetries)",
                        ])
                        try await Self.sleepCancellable(wait)
                        remainingRetryCount -= 1
                        continue
                    }
                    // 被动记录其它异常状态
                    if resp.status == 401 || resp.status == 403 {
                        await MainActor.run { AccountStatusStore.shared.noteUnauthenticated(status: resp.status) }
                    } else if resp.status >= 500 {
                        await MainActor.run { AccountStatusStore.shared.noteServerError(status: resp.status) }
                    }
                    throw NetworkError.httpStatus(resp.status)
                }
                // 成功：快速复位（store 内部先做一次枚举比较，正常态零开销）
                await MainActor.run { AccountStatusStore.shared.noteSuccess() }
                return resp
            } catch is CancellationError {
                if acquired { await Self.gate.release(kind: kind) }
                throw CancellationError()
            } catch let gateError as RequestGate.GateError {
                // 熔断短路：不是网络错误，直接上抛让调用方停本轮
                throw gateError
            } catch {
                if acquired { await Self.gate.release(kind: kind); acquired = false }
                // URLSession 在任务取消时抛 URLError.cancelled(.cancelled) —— 必须等价于取消,
                // 否则退避睡眠被跳过 → 同一毫秒空转重试
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                lastError = error
                let urlError = error as? URLError
                // 无法建立连接（代理不可达/离线）→ 归为 unreachable，供状态栏与文案使用；
                // 这类错误重试通常无效，但仍给 1 次机会（代理可能刚好在恢复）
                let isUnreachable: Bool = {
                    guard let code = urlError?.code else { return false }
                    switch code {
                    case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                         .notConnectedToInternet, .networkConnectionLost:
                        return true
                    default:
                        return false
                    }
                }()
                await MainActor.run {
                    AccountStatusStore.shared.noteNetworkFailure(error)
                }
                // 日志降噪：16 次重试刷 16 行没有价值，只记首次与末次
                if remainingRetryCount == attemptLimit || remainingRetryCount == 1 {
                    AppLogger.warn("请求失败将重试", category: "NET", [
                        "method": method,
                        "url": url.path.isEmpty ? url.absoluteString : url.path,
                        "error": error.localizedDescription,
                        "remains": "\(remainingRetryCount)",
                        "unreachable": isUnreachable ? "1" : "0",
                    ])
                }
                // 连不上时缩短退避：长等无意义，且会拖到总预算耗尽
                let wait = isUnreachable ? min(retryDelay, 1.0) : retryDelay
                try await Self.sleepCancellable(wait)
                remainingRetryCount -= 1
                retryDelay = min(retryDelay * 2, maxRetryDelay)
            }
        }

        // 次数用尽：把"连不上"统一包装成语义明确的错误
        if let urlError = lastError as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .notConnectedToInternet, .networkConnectionLost:
                throw NetworkError.unreachable(urlError.localizedDescription)
            case .timedOut:
                throw NetworkError.timedOut
            default:
                break
            }
        }
        throw lastError ?? NetworkError.unknown
    }

    /// 全局请求闸门（限流缓解）
    private static let gate = RequestGate.shared

    /// 把当前设置推给闸门（设置变更时调用；请求前也会惰性同步一次）
    static func syncGateConfig(_ settings: Settings) async {
        await gate.update(config: RequestGate.GatewayConfig(
            enabled: settings.gateEnabled,
            requestsPerWindow: settings.gateRequestsPerWindow,
            windowSeconds: settings.gateWindowSeconds,
            serialize: settings.serializePerEndpoint,
            breakerEnabled: settings.breakerEnabled,
            cooldownSeconds: settings.breakerCooldownSeconds
        ))
    }

    /// 429 最多重试次数（上游无此限制，此处为保护账号配额的有意收紧）
    private static let maxRateLimitRetries = 3

    /// 取消感知睡眠：任务被取消时抛 CancellationError，而非静默立即返回
    private static func sleepCancellable(_ seconds: TimeInterval) async throws {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        } catch {
            throw CancellationError()
        }
    }

    /// 解析 Retry-After（秒数或 HTTP 日期）
    private static func retryAfter(_ resp: NetworkResponse) -> TimeInterval? {
        guard let raw = resp.headers.first(where: { $0.key.lowercased() == "retry-after" })?.value.first else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) { return min(seconds, 60) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return min(max(date.timeIntervalSinceNow, 0), 60)
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
    /// 总预算用尽或单次超时（可重试，但本轮已放弃）
    case timedOut
    /// 无法建立连接（代理不可达 / 离线）
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .unknown: return "未知网络错误"
        case .httpStatus(let code): return "HTTP \(code)"
        case .timedOut: return L("请求超时，请稍后重试")
        case .unreachable(let detail): return L("无法连接到服务器：") + detail
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
        var dict: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: host,
            kCFNetworkProxiesHTTPSPort: port,
        ]
        // 代理身份验证（可选； undocumented-ish 公开键 kCFProxyUsernameKey）
        if let user = proxy.username, !user.isEmpty {
            dict["kCFProxyUsernameKey" as CFString] = user
            if let pass = proxy.password, !pass.isEmpty {
                dict["kCFProxyPasswordKey" as CFString] = pass
            }
        }
        connectionProxyDictionary = dict as? [String: Any]
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
