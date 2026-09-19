import Foundation

/// `SearchTimeline` 端点的 queryId 提供者（含**自愈**）。
///
/// ## 关于 queryId 会变的实测结论（重要，别被误导）
///
/// X 的 GraphQL 端点路径里带 `queryId`。此前的方案文档曾写
/// "`.fetch/openapi.yaml` 里的 `Yw6L66Pw54NHKuq4Dp7b4Q` 已失效" —— **那是错的**。
/// 实测（POST + JSON）：
///
/// | queryId | GET | POST |
/// |---|---|---|
/// | openapi 记录的 `Yw6L66Pw…` | 404 | **200（42 条真实数据）** |
/// | 当前 bundle 的 `auLkqtmHq…` | 404 | **200（42 条真实数据）** |
/// | 随机乱写 | 404 | 404 |
///
/// **两个已知 queryId 都能用**；404 是 **GET 方法**造成的假象——
/// 这个端点只接受 POST（见 `TwitterAPI.searchTimeline` 的说明）。
/// 当年就是我一开始用 GET，才误判成"queryId 失效"。
///
/// 所以自愈机制的价值是"X 真改版时能自动跟上"，**不是**日常必需品。
/// 内置默认值本身可用，自愈只在确实拿到 404 时才触发。
/// bundle 走 `abs.twimg.com` CDN，匿名、**不消耗 X API 配额**。
actor SearchQueryIdProvider {
    static let shared = SearchQueryIdProvider()

    /// 内置默认值：`fetch/openapi.yaml` 记录的 `Yw6L66Pw54NHKuq4Dp7b4Q`。
    /// （实测与当前 bundle 的 `auLkqtmHqYEpRvflfvLhyQ` 同样有效。）
    private static let fallback = "Yw6L66Pw54NHKuq4Dp7b4Q"

    private var cached: String?
    /// 是否已经尝试过自愈（避免持续失败时反复抓 bundle）
    private var refreshAttempted = false

    private init() {}

    /// 当前可用 queryId（优先缓存 → 内置默认）
    func current() -> String {
        cached ?? Self.fallback
    }

    /// 自愈：从 X 网页资源里重新提取 queryId。
    /// - Returns: 新 queryId；失败返回 nil（调用方应把原错误抛给用户，不要吞掉）。
    @discardableResult
    func refresh(session: NetworkClient) async -> String? {
        guard !refreshAttempted else { return nil }
        refreshAttempted = true

        let started = Date()
        do {
            // 1) 搜索页 HTML：里面引用了当前的 main bundle
            let searchPage = URL(string: "https://x.com/search?q=from%3Atwitter&src=typed_query&f=live")!
            let htmlResp = try await session.requestFast(url: searchPage, headers: Self.cdnHeaders)
            let html = htmlResp.text()

            // 2) main bundle 地址
            guard let bundleURL = Self.extractMainBundleURL(from: html) else {
                AppLogger.warn("未能从搜索页找到 main bundle", category: "NET")
                return nil
            }
            let bundleResp = try await session.requestFast(url: bundleURL, headers: Self.cdnHeaders)
            let bundle = bundleResp.text()

            // 3) 提取 queryId
            guard let id = Self.extractSearchTimelineQueryId(from: bundle) else {
                AppLogger.warn("bundle 中未找到 SearchTimeline queryId", category: "NET")
                return nil
            }
            cached = id
            AppLogger.info("SearchTimeline queryId 已自动更新", category: "NET", [
                "queryId": id,
                "seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
            ])
            return id
        } catch {
            AppLogger.warn("queryId 自愈失败", category: "NET", ["error": error.localizedDescription])
            return nil
        }
    }

    /// 仅供测试：重置状态
    func resetForTesting() {
        cached = nil
        refreshAttempted = false
    }

    /// 仅供测试：注入一个 queryId
    func setForTesting(_ id: String?) {
        cached = id
    }

    // MARK: - 解析（静态、可单测）

    /// CDN 请求头：bundle 与搜索页都不需要认证
    static let cdnHeaders: [String: String] = [
        "User-Agent": TwitterAPI.userAgent,
    ]

    /// 从搜索页 HTML 里找出 main bundle 的绝对地址
    static func extractMainBundleURL(from html: String) -> URL? {
        let pattern = #"https://abs\.twimg\.com/responsive-web/client-web/main\.[a-f0-9]+\.js"#
        guard let range = html.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(html[range]))
    }

    /// 从 bundle 文本里提取 `SearchTimeline` 的 queryId。
    ///
    /// bundle 里的形态是对象字面量：
    /// `e.exports={queryId:"auLkqtmHqYEpRvflfvLhyQ",operationName:"SearchTimeline",…}`
    ///
    /// **必须锚定 `operationName:"SearchTimeline"`**：bundle 里还有
    /// `BookmarkSearchTimeline` / `ListSearchTimeline` /
    /// `GlobalCommunitiesPostSearchTimeline` 等多个含 "SearchTimeline" 的操作，
    /// 只按名字搜索会取到别的 queryId（实测这几个操作在前，会先命中）。
    static func extractSearchTimelineQueryId(from bundle: String) -> String? {
        let pattern = #"queryId:"([A-Za-z0-9_-]{20,24})",operationName:"SearchTimeline""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: bundle,
                                           range: NSRange(bundle.startIndex..., in: bundle)),
              let range = Range(match.range(at: 1), in: bundle) else { return nil }
        return String(bundle[range])
    }
}
