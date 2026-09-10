import Foundation

actor NetworkClient {
    private let session: URLSession
    private var proxy: ProxySettings

    init(proxy: ProxySettings = ProxySettings()) {
        self.proxy = proxy
        let config = URLSessionConfiguration.default
        config.apply(proxy: proxy)
        self.session = URLSession(configuration: config)
    }

    func updateProxy(_ proxy: ProxySettings) {
        self.proxy = proxy
    }

    func request(
        method: String = "GET",
        url: URL,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil,
        responseType: NetworkResponseType = .json
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

enum NetworkResponseType {
    case json, text, binary
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
    func apply(proxy: ProxySettings) {
        if !proxy.enable {
            self.connectionProxyDictionary = [:]
            return
        }
        if proxy.useSystem {
            self.connectionProxyDictionary = nil
            return
        }
        guard let url = URL(string: proxy.url), let host = url.host else { return }
        let port = url.port ?? 80
        self.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: host,
            kCFNetworkProxiesHTTPSPort: port,
        ]
    }
}
