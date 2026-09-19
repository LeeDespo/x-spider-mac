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

    /// 网络类异常（连不上/超时）的自动过期时间。
    ///
    /// 为什么需要：这两种状态**只能靠"下一次请求成功"清除**（见 noteSuccess），
    /// 但网络已断时不会有成功请求 —— 形成死锁，且 `CreationTaskStore.waitWhileThrottled`
    /// 与下载并发降级都依赖这些状态，会把挂起无限延长（"代理恢复后应用仍卡很久，除非重启"）。
    ///
    /// 到期后**不再视为异常**，让后续请求真的发出去由真实结果重新判定。
    /// 这与 rateLimited 用 `until` 到期判定是同一套语义，当时漏了这两个状态。
    private let networkErrorTTL: TimeInterval = 30

    /// 网络类异常是否已过 TTL（读取时判定，非轮询）
    private var networkErrorExpired: Bool {
        switch health {
        case .offline, .timedOut:
            return Date().timeIntervalSince(changedAt) >= networkErrorTTL
        default:
            return false
        }
    }

    /// 对外可见的有效状态（**仅用于展示**）。
    /// 限流到期后按正常显示（deadline 是"预计恢复时刻"，到期即表示该提示过期）。
    /// 网络类异常**不在此处过期**：那是关于现实的一次观测，过期不代表已恢复，
    /// 让徽标改口说"正常"是撒谎（见 noteSuccess —— 真恢复会由成功请求清除）。
    var effectiveHealth: Health { rateLimitExpired ? .normal : health }

    /// 是否应**暂停发起新工作**（爬虫挂起、下载并发降级等）。
    ///
    /// 与展示解耦的原因：网络类异常只能靠"下一次成功请求"清除，而断网时不会有成功请求，
    /// 若用它来长期阻断，就形成死锁（"代理恢复后仍卡很久，除非重启"）。
    /// 因此这里带 TTL：过期后**放行一次**新请求，让真实结果重新判定状态。
    /// 注意这与"主动探测"不同 —— 只是不再拦用户的正常操作。
    var shouldSuspendNewWork: Bool {
        if rateLimitExpired { return false }
        if networkErrorExpired { return false }   // TTL 到期 → 放行，让真实请求判定
        switch health {
        case .rateLimited, .timedOut, .offline, .unauthenticated: return true
        case .normal, .serverError: return false
        }
    }

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

    // MARK: - 主动检测（可开关，默认开启，间隔默认 30 秒）

    /// 主动检测的循环任务（开启时存在，关闭时取消）
    private var probeLoop: Task<Void, Never>?
    /// 上次主动检测时间（设置界面展示"最近检测"用）
    private(set) var lastActiveProbeAt: Date?

    /// 启动/停止主动检测。由设置变化驱动（`SettingsStore` 在开关或间隔改变时调用）。
    ///
    /// ## 与「被动检测」的关系
    ///
    /// 被动检测一直是**唯一自动采集口**（`NetworkClient` 上报），
    /// 这条主动检测只是**额外**按间隔探一次连通性：
    /// - 好处：状态更快反映现实（断网后不必等下次操作才发现）；
    /// - 代价：**会消耗 X 的请求配额**（探测走 `getAccountInfo`，是真实请求）。
    ///   因此做成可关闭，且间隔有下限（默认 30s，最低 5s）——
    ///   间隔太短会被 X 视为异常流量，反而加剧限流。
    func restartActiveProbeIfNeeded() {
        probeLoop?.cancel()
        probeLoop = nil

        let settings = SettingsStore.shared.settings
        // 开关默认**打开**（nil = 开）
        guard settings.activeStatusProbeEnabled else { return }
        let interval = max(5, settings.activeStatusProbeIntervalSeconds)

        probeLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.runActiveProbe()
            }
        }
        AppLogger.info("主动状态检测已启动", category: "NET", ["intervalSec": "\(interval)"])
    }

    /// 探一次连通性。**不做熔断复位**——那是用户点「重试」的语义（见 `probeAndRecover`）。
    /// 这里只是"看看现在通不通"，结果由真实请求的被动上报写入。
    private func runActiveProbe() async {
        lastActiveProbeAt = Date()
        guard !probing else { return }
        probing = true
        defer { probing = false }
        do {
            _ = try await TwitterAPI.shared.probeConnection()
            // 探测成功且当前是"网络类异常"时才复位：限流态不该被探测悄悄清掉
            // （限流是 X 明确告知的，应等它的 until 到期或用户点重试）
            switch effectiveHealth {
            case .offline, .timedOut:
                reset()
            default:
                break
            }
        } catch {
            // 失败状态由 NetworkClient 的被动上报写入，这里不重复写
        }
    }

    /// 停止主动检测（应用退出/关闭开关时）
    func stopActiveProbe() {
        probeLoop?.cancel()
        probeLoop = nil
    }

    // MARK: - 手动探测（由用户点击触发）

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

    /// CDN 限流解除时的回调（由 DownloadStore 注册 → 唤醒等待队列）。
    /// 用回调而不是让状态层直接依赖下载层，避免两个 store 循环引用。
    /// **必须存在**：限流期间并发被压到 1，若解除时无人唤醒队列，
    /// 等待中的任务会静默卡住（要等下次用户操作才恢复）。
    var onCDNRecovered: (() -> Void)?

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
        let wasThrottled = cdnRateLimitedUntil != nil
        cdnRateLimitedUntil = nil
        cdnLastFailure = nil
        // 限流解除 → 通知下载队列恢复并发（否则等待中的任务静默卡住）
        if wasThrottled { onCDNRecovered?() }
    }

    /// 到期判定（视图调用，非轮询）
    func refreshCDNExpiry() {
        guard let until = cdnRateLimitedUntil, Date() >= until else { return }
        cdnRateLimitedUntil = nil
        AppLogger.info("媒体 CDN 限流到期恢复", category: "DL")
        // 同样必须唤醒队列：到期只是"标记清了"，不唤醒的话并发上限虽恢复，
        // 却没有任务会被重新拉起
        onCDNRecovered?()
    }

    /// 测试辅助：把 CDN 限流截止时间设为指定值（构造"已过期"等边界）
    func setCDNThrottleDeadlineForTesting(_ deadline: Date?) {
        cdnRateLimitedUntil = deadline
    }

    /// 测试辅助：构造限流截止时间（用于验证到期判定）
    func setRateLimitDeadlineForTesting(_ deadline: Date?) {
        health = .rateLimited(until: deadline)
        changedAt = Date()
    }

    /// 测试辅助：构造网络异常的发生时刻（用于验证 TTL 边界）
    func setChangedAtForTesting(_ date: Date) {
        changedAt = date
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

        // 用户明确要求"别再拦我" → 立即解除冷却并唤醒队列。
        // 注意顺序：必须**先**记录并触发回调，再清标记——否则 noteCDNSuccess()
        // 会认为"本来就没限流"，回调不触发，队列仍然卡着。
        let wasThrottled = cdnRateLimitedUntil != nil
        cdnRateLimitedUntil = nil
        if wasThrottled { onCDNRecovered?() }

        // 探测 URL 必须属于媒体 CDN 域（pbs.twimg.com）。
        // 早前用的 /media/EV5m1XjXQAAEqUd 实测已 404，会把正常网络误报成异常。
        let probeURL = URL(string: "https://pbs.twimg.com/profile_images/1683325380441128960/yRsRRjGO.jpg")!
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.setValue(Self.cdnProbeUserAgent, forHTTPHeaderField: "User-Agent")
        // 只取首个分片即判定连通（服务器不支持 Range 时会返回全量，但我们只看状态码）
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                noteCDNRateLimited(retryAfter: after)
                AppLogger.warn("CDN 探测:仍被限流", category: "DL")
            } else if (200..<400).contains(status), !data.isEmpty {
                // 已在上方清过限流标记，这里只需清失败原因（不再依赖 noteCDNSuccess 触发回调）
                cdnLastFailure = nil
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

    // MARK: - 精简标签（侧边栏用）

    /// 状态**简称**：侧边栏只显示这几个字，详细原因放 `helpText` 悬停查看。
    ///
    /// 需求：边栏位置窄，直接显示完整状态文案（如"429 限流，熔断倒计时 37 秒"）
    /// 会被截断、看不全。因此标签化：只有「正常 / 异常 / 限流」三档，
    /// 具体原因（超时、登录失效、服务端 5xx…）都进悬停说明。
    ///
    /// 三档与灯色一一对应：
    /// - 绿灯「正常」
    /// - 黄灯「异常」（超时 / 离线 / 登录失效 / 服务端错误）
    /// - 红灯「限流」（X 明确返回 429，最需要用户注意——它会暂停后续工作）
    var shortLabel: String {
        switch severity {
        case .ok: return L("正常")
        case .warning: return L("异常")
        case .critical: return L("限流")
        }
    }

    /// CDN 的简称（与 X API 分开，两者配额独立）
    var cdnShortLabel: String {
        if cdnThrottled { return L("限流") }
        if cdnLastFailure != nil { return L("异常") }
        return L("正常")
    }
}
