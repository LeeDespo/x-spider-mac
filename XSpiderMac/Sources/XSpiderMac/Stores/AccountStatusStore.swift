import Foundation

/// 账号健康状态的**被动**采集与展示（不做定时探测、不发额外请求）。
///
/// 采集原则：
/// - 唯一自动采集口是 `NetworkClient`（所有 X 请求的汇聚点），由它调用 `note*` 上报；
/// - 只在真实操作遇阻时变更状态，成功响应按状态类型决定是否复位；
/// - 状态值 `Equatable`，相同则直接返回，不触发 `@Observable` 重绘；
/// - 不写日志（仅状态迁移那一次），避免热路径 I/O。
///
/// 唯一的**主动**行为是用户点「重试」按钮：那是明确的用户意图，不算轮询。
@Observable
@MainActor
final class AccountStatusStore {
    static let shared = AccountStatusStore()

    /// 可被动检测的异常状态（全部由"操作遇阻"推导，无需额外请求）
    enum Health: Equatable {
        /// 绿灯：最近一次请求正常
        case normal
        /// 红灯：X 短期访问过多（HTTP 429）。`until` = 预计恢复时刻
        case rateLimited(until: Date?)
        /// Cookie 失效或权限不足（HTTP 401/403）→ 需重新导入登录
        case unauthenticated
        /// X 服务端异常（HTTP 5xx）
        case serverError(Int)
        /// 连接 X 超时（URLError.timedOut）—— 常见于代理不稳定
        case timedOut
        /// 无法连通 X（离线 / DNS 失败 / 拒绝连接 / 代理不可达）
        case offline
    }

    private(set) var health: Health = .normal
    /// 最近一次状态变更时间
    private(set) var changedAt: Date = .distantPast
    /// 网关层熔断是否正在生效（决定状态文案是否显示倒计时）
    var breakerOpen: Bool = false
    /// 手动探测进行中（按钮转圈用）
    private(set) var probing = false
    /// 媒体 CDN 探测进行中
    private(set) var probingCDN = false

    private init() {}

    /// 熔断关闭（拿不到真实截止时间）时的兜底显示窗口
    private let fallbackRateLimitedWindow: TimeInterval = 60

    // MARK: - 到期判定

    /// 限流是否已过恢复期限（读取时判定，避免展示过时的"限流中"）
    private var rateLimitExpired: Bool {
        if case .rateLimited(let until) = health {
            guard let until else { return false }
            return Date() >= until
        }
        return false
    }

    /// 对外可见的有效状态（限流到期后按正常处理）
    var effectiveHealth: Health { rateLimitExpired ? .normal : health }

    /// 限流状态的恢复时刻（视图据此安排一次到期刷新与倒计时）
    var rateLimitDeadline: Date? {
        if case .rateLimited(let until) = health, let until, !rateLimitExpired { return until }
        return nil
    }

    /// 到期后由视图调用一次，把状态落回正常
    func refreshExpiry() {
        guard rateLimitExpired else { return }
        health = .normal
        breakerOpen = false
        changedAt = Date()
        AppLogger.info("限流状态到期自动恢复", category: "NET")
    }

    /// 强制复位为正常（探测成功 / 单元测试隔离用）
    func reset() {
        health = .normal
        breakerOpen = false
        cdnRateLimitedUntil = nil
        cdnLastFailure = nil
        changedAt = Date()
    }

    // MARK: - 被动上报（O(1) 值比较，状态未变则零开销返回）

    /// 成功响应：按状态类型决定是否复位。
    /// - 限流：**未到恢复期限不复位** —— 别的端点成功不代表限流已解除
    ///   （否则启动时的 XClId、页面 HTML、关注态查询会把 429 状态瞬间抹掉）
    /// - 其余异常：可被下一次成功立即复位
    func noteSuccess() {
        switch health {
        case .normal:
            return // 热路径快返回：一次枚举比较
        case .rateLimited(let until):
            guard let until, Date() >= until else { return }
        case .unauthenticated, .serverError, .timedOut, .offline:
            break
        }
        health = .normal
        changedAt = Date()
        AppLogger.info("账号状态恢复正常", category: "NET")
    }

    /// 触发限流（429）
    /// - Parameter until: 熔断的实际截止时间。**非 nil 时按原样尊重**（含已过期的值——
    ///   调用方更清楚真实期限）；仅当拿不到期限（熔断关闭）时用兜底显示窗口，
    ///   避免状态因为没有期限而无法自动清除。
    func noteRateLimited(until: Date?) {
        let deadline = until ?? Date().addingTimeInterval(fallbackRateLimitedWindow)
        let next = Health.rateLimited(until: deadline)
        // 同状态：只延长不退步（并发 429 不应互相覆盖成更早的截止时间）
        if case .rateLimited(let oldUntil) = health {
            guard let oldUntil, deadline > oldUntil else { return }
        }
        health = next
        changedAt = Date()
        AppLogger.warn("账号状态:触发限流", category: "NET", [
            "holdSec": "\(Int(deadline.timeIntervalSinceNow))",
        ])
    }

    /// Cookie 失效（401/403）
    func noteUnauthenticated(status: Int) {
        guard health != .unauthenticated else { return }
        health = .unauthenticated
        changedAt = Date()
        AppLogger.warn("账号状态:Cookie 失效", category: "NET", ["status": "\(status)"])
    }

    /// X 端 5xx
    func noteServerError(status: Int) {
        let next = Health.serverError(status)
        guard health != next else { return }
        health = next
        changedAt = Date()
    }

    /// 网络层失败：按 URLError 分类（超时 / 无法连通 各自独立状态）
    func noteNetworkFailure(_ error: Error) {
        let next: Health
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                next = .timedOut
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .resourceUnavailable, .cannotLoadFromNetwork:
                next = .offline
            default:
                next = .offline
            }
        } else {
            next = .offline
        }
        guard health != next else { return }
        health = next
        changedAt = Date()
    }

    // MARK: - 手动探测（唯一的主动行为，仅由用户点击触发）

    /// 用户点「重试」：立刻结束熔断，并真的连一次 X 判断当前状态。
    ///
    /// 语义（对应需求）：
    /// 1. 无论是否处于熔断，都发起一次真实连接判断；
    /// 2. 若已处于熔断，立即结束熔断（用户明确要求"别再拦我"）；
    /// 3. 探测成功 → 刷新为正常；失败 → 落到对应状态（若又是 429，熔断会按新期限重开）。
    func probeAndRecover() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }

        // 1) 立即结束熔断，让探测请求真的能发出去
        await RequestGate.shared.resetBreakers()
        breakerOpen = false

        // 2) 真实探测（绕过闸门，避免被自己的限速拖住；短暂超时快速失败）
        do {
            let info = try await TwitterAPI.shared.probeConnection()
            // 3) 成功即刷新为正常（限流态也强制清除——这是用户主动验证的结果）
            reset()
            AppLogger.info("手动探测:连接正常", category: "NET", ["screenName": info.screenName])
        } catch is CancellationError {
            return
        } catch {
            // 失败状态由 NetworkClient 的被动上报写入；此处只补一个兜底分类
            if effectiveHealth == .normal, !(error is RequestGate.GateError) {
                noteNetworkFailure(error)
            }
            AppLogger.warn("手动探测:仍然异常", category: "NET", ["error": error.localizedDescription])
        }
    }

    // MARK: - 媒体 CDN 状态（与 GraphQL API 是不同域、不同配额，故独立跟踪）

    /// 媒体 CDN（pbs.twimg.com / video.twimg.com）的限流状态。
    /// 与上方 GraphQL 状态分开：CDN 限流只影响下载，不该把"能否翻页"也说成异常；
    /// 反之 API 正常而下载 429 也应能单独看出。
    private(set) var cdnRateLimitedUntil: Date?
    /// CDN 最近一次失败原因（非限流类）
    private(set) var cdnLastFailure: String?

    /// CDN 是否处于限流冷却中
    var cdnThrottled: Bool {
        guard let until = cdnRateLimitedUntil else { return false }
        return Date() < until
    }

    /// CDN 限流剩余秒数
    var cdnRemainingSeconds: Int {
        guard let until = cdnRateLimitedUntil else { return 0 }
        return max(0, Int(until.timeIntervalSinceNow))
    }

    /// CDN 行文案（nil = 正常）
    var cdnStatusText: String? {
        if cdnThrottled {
            return L("媒体 CDN 限流，%ds 后恢复").replacingOccurrences(of: "%d", with: "\(cdnRemainingSeconds)")
        }
        if let failure = cdnLastFailure {
            return L("媒体下载异常：") + failure
        }
        return nil
    }

    var cdnHelpText: String {
        if cdnThrottled {
            return L("媒体服务器（pbs.twimg.com / video.twimg.com）返回 429。已自动降低下载并发，倒计时结束或点右侧按钮重试。\n这与 X 的 API 限流是两个独立的配额。")
        }
        if let failure = cdnLastFailure {
            return L("最近一次媒体下载失败：") + failure
        }
        return L("媒体下载正常。")
    }

    /// CDN 异常（被下载路径调用）
    func noteCDNRateLimited(retryAfter: TimeInterval?) {
        let window = max(retryAfter ?? 0, TimeInterval(SettingsStore.shared.settings.cdnCooldownSeconds))
        let until = Date().addingTimeInterval(window)
        if let existing = cdnRateLimitedUntil, existing >= until { return } // 只延长不退步
        cdnRateLimitedUntil = until
        cdnLastFailure = nil
        changedAt = Date()
        AppLogger.warn("媒体 CDN 触发限流", category: "DL", ["holdSec": "\(Int(window))"])
    }

    func noteCDNFailure(_ message: String) {
        guard cdnLastFailure != message else { return }
        cdnLastFailure = message
    }

    func noteCDNSuccess() {
        guard cdnRateLimitedUntil != nil || cdnLastFailure != nil else { return }
        cdnRateLimitedUntil = nil
        cdnLastFailure = nil
    }

    /// 到期判定（视图调用，非轮询）
    func refreshCDNExpiry() {
        guard let until = cdnRateLimitedUntil, Date() >= until else { return }
        cdnRateLimitedUntil = nil
        AppLogger.info("媒体 CDN 限流到期恢复", category: "DL")
    }

    /// 用户点媒体 CDN 行的「重试」：结束 CDN 冷却并真的探一次媒体服务器。
    ///
    /// 探测方式：对一张公开的 X 媒体缩略图发一次极小的 HEAD/GET（只读首字节就断开），
    /// 比下载整个文件便宜得多，失败也只影响这一次探测。用固定的官方静态图，
    /// 避免依赖用户当前列表里恰好有可下载的媒体。
    func probeCDN() async {
        guard !probingCDN else { return }
        probingCDN = true
        defer { probingCDN = false }

        // 先解除冷却（用户明确要求"别再拦我"）
        cdnRateLimitedUntil = nil

        let probeURL = URL(string: "https://pbs.twimg.com/media/EV5m1XjXQAAEqUd?format=jpg&name=small")!
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.setValue(Self.cdnProbeUserAgent, forHTTPHeaderField: "User-Agent")
        // 只取首个分片即判定连通（不等整个文件；服务器不支持 Range 时会返回全量，
        // 但我们只检查状态码，data 体积由 URLSession 自行处理，不会阻塞判定）
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.timeoutInterval = 12
        // 只取极少量数据即判定连通（不等整个文件）
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                noteCDNRateLimited(retryAfter: after)
                AppLogger.warn("CDN 探测:仍被限流", category: "DL")
            } else if (200..<400).contains(status), !data.isEmpty {
                noteCDNSuccess()
                AppLogger.info("CDN 探测:连接正常", category: "DL", ["bytes": "\(data.count)"])
            } else {
                noteCDNFailure("HTTP \(status)")
                AppLogger.warn("CDN 探测:异常状态", category: "DL", ["status": "\(status)"])
            }
        } catch is CancellationError {
            return
        } catch {
            noteCDNFailure(error.localizedDescription)
            AppLogger.warn("CDN 探测失败", category: "DL", ["error": error.localizedDescription])
        }
    }

    private static let cdnProbeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

    // MARK: - 展示

    /// 状态栏文案
    var statusText: String {
        switch effectiveHealth {
        case .normal:
            return L("状态正常")
        case .rateLimited:
            // 熔断开启时附带倒计时（倒计时由视图按秒刷新）
            if breakerOpen {
                let seconds = max(0, Int(rateLimitDeadline?.timeIntervalSinceNow ?? 0))
                // 不用字符串插值当 key（那样永远命中不到翻译表，英文界面会显示中文）
                return L("429 限流，熔断倒计时 %d 秒").replacingOccurrences(of: "%d", with: "\(seconds)")
            }
            return L("429 限流")
        case .unauthenticated:
            return L("登录失效")
        case .serverError(let code):
            return L("X 服务异常 (\(code))")
        case .timedOut:
            return L("连接 X 超时")
        case .offline:
            return L("无法连接 X")
        }
    }

    /// 悬停说明（解释判定依据）
    var helpText: String {
        switch effectiveHealth {
        case .normal:
            return L("最近一次对 X 的请求正常。")
        case .rateLimited:
            if breakerOpen {
                return L("X 短期内访问过多已被限流。已自动暂停相关请求，倒计时结束自动恢复；也可点右侧按钮立即结束并重试。")
            }
            return L("X 短期内访问过多已被限流，稍后自动恢复。")
        case .unauthenticated:
            return L("Cookie 已失效（HTTP 401/403），请重新导入登录。")
        case .serverError(let code):
            return L("X 服务端返回异常（HTTP \(code)），通常稍后自行恢复。")
        case .timedOut:
            return L("请求 X 超时。常见于代理不稳定或网络拥塞。")
        case .offline:
            return L("无法连通 X：可能已离线、DNS 解析失败或代理不可达。")
        }
    }

    /// 状态灯配色语义
    var severity: Severity {
        switch effectiveHealth {
        case .normal: return .ok
        case .rateLimited: return .critical
        case .unauthenticated, .serverError, .timedOut, .offline: return .warning
        }
    }

    enum Severity { case ok, critical, warning }
}
