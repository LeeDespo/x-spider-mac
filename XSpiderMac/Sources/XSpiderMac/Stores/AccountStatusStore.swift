import Foundation

/// 账号健康状态的**被动**采集与展示（不做主动探测、不发额外请求）。
///
/// 设计要点：
/// - 唯一采集口是 `NetworkClient`（所有 X 请求的汇聚点），由它调用 `note*` 上报；
/// - 只在真实操作遇阻时变更状态，成功响应时用一次 `if` 快速复位；
/// - 状态值 `Equatable`，相同则直接返回，不触发 `@Observable` 重绘；
/// - 不写日志（仅状态迁移那一次），避免热路径 I/O。
@Observable
@MainActor
final class AccountStatusStore {
    static let shared = AccountStatusStore()

    enum Health: Equatable {
        case normal
        /// 429：X 短期访问过多。`until` 为预计恢复时间（来自 Retry-After，缺失则用默认冷却）
        case rateLimited(until: Date?)
        /// 401/403：Cookie 失效或权限不足
        case unauthenticated
        /// 5xx：X 端服务异常
        case serverError(Int)
        /// 网络层失败（超时/离线/代理不可达）
        case networkError(String)
    }

    private(set) var health: Health = .normal
    /// 最近一次状态变更时间（供 UI 判新鲜度，避免展示过时信息）
    private(set) var changedAt: Date = .distantPast
    /// 网关层熔断是否正在生效（由 RequestGate 写入，供 UI 说明"已暂停请求"）
    var breakerOpen: Bool = false

    private init() {}

    /// 限流状态是否已过恢复期限（读取时判定，避免展示过时的"限流中"）
    private var rateLimitExpired: Bool {
        if case .rateLimited(let until) = health {
            guard let until else { return false }
            return Date() >= until
        }
        return false
    }

    /// 对外可见的有效状态（限流到期后按正常处理）
    var effectiveHealth: Health { rateLimitExpired ? .normal : health }

    /// 限流状态的恢复时刻（视图用它安排一次到期刷新；nil = 无待到期状态）
    var rateLimitDeadline: Date? {
        if case .rateLimited(let until) = health, let until, !rateLimitExpired { return until }
        return nil
    }

    /// 到期后由视图调用一次，把状态真正落回正常（触发一次重绘让标签消失）。
    /// 被动语义：这不是探测，只是本地到期判定。
    func refreshExpiry() {
        guard rateLimitExpired else { return }
        health = .normal
        breakerOpen = false
        changedAt = Date()
        AppLogger.info("限流状态到期自动恢复", category: "NET")
    }

    /// 熔断关闭（拿不到真实截止时间）时的最小保留窗口。
    /// 有真实截止时间时**不用**这个下限：否则 X 只要求退避 3 秒、标签却留 60 秒，
    /// 会出现"请求已恢复但标签还在"。
    private let fallbackRateLimitedWindow: TimeInterval = 60

    // MARK: - 上报（全部为 O(1) 值比较，状态未变则零开销返回）

    /// 成功响应：按状态类型决定是否复位。
    /// - 限流：**未到恢复期限不复位** —— 别的端点成功不代表限流已解除
    /// - 登录失效/服务异常/网络错误：可被下一次成功立即复位
    func noteSuccess() {
        switch health {
        case .normal:
            return // 热路径快返回：一次枚举比较
        case .rateLimited(let until):
            // 只有过了恢复期限，成功响应才意味着真正恢复
            guard let until, Date() >= until else { return }
        case .unauthenticated, .serverError, .networkError:
            break
        }
        health = .normal
        changedAt = Date()
        AppLogger.info("账号状态恢复正常", category: "NET")
    }

    /// 触发限流（429）。
    /// - Parameter until: 熔断的实际截止时间。有值时**以它为准**（来自 Retry-After 或用户
    ///   设置的暂停时长），保证"标签消失"与"请求恢复"同时发生；熔断关闭时用兜底窗口，
    ///   避免状态因为没有期限而无法自动清除。
    func noteRateLimited(until: Date?) {
        let deadline: Date
        if let until, until > Date() {
            deadline = until
        } else {
            deadline = Date().addingTimeInterval(fallbackRateLimitedWindow)
        }
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
        let next = Health.unauthenticated
        guard health != next else { return }
        health = next
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

    /// 网络层失败
    func noteNetworkError(_ message: String) {
        let next = Health.networkError(message)
        guard health != next else { return }
        health = next
        changedAt = Date()
    }

    // MARK: - 展示

    /// 侧边栏标签文案（nil = 正常，不显示标签）
    var badgeText: String? {
        switch effectiveHealth {
        case .normal: return nil
        case .rateLimited: return L("429 限流")
        case .unauthenticated: return L("登录失效")
        case .serverError: return L("服务异常")
        case .networkError: return L("网络异常")
        }
    }

    /// 悬停说明
    var helpText: String {
        switch effectiveHealth {
        case .normal:
            return L("一切正常")
        case .rateLimited(let until):
            if breakerOpen {
                return L("X 短期内访问过多已被限流。已自动暂停相关请求，稍后自动恢复。")
            }
            if let until {
                let mins = max(1, Int(until.timeIntervalSinceNow / 60))
                return L("X 短期内访问过多已被限流，预计约 \(mins) 分钟后恢复。")
            }
            return L("X 短期内访问过多已被限流，稍后自动恢复。")
        case .unauthenticated:
            return L("Cookie 已失效，请重新导入登录。")
        case .serverError(let code):
            return L("X 服务端返回异常（HTTP \(code)），稍后重试。")
        case .networkError(let message):
            return L("网络请求失败：\(message)")
        }
    }

    /// 标签配色语义（视图侧映射为具体颜色）
    var severity: Severity {
        switch effectiveHealth {
        case .normal: return .normal
        case .rateLimited: return .critical
        case .unauthenticated: return .warning
        case .serverError: return .warning
        case .networkError: return .muted
        }
    }

    enum Severity { case normal, critical, warning, muted }

    /// 登录失效时点击标签跳 Cookie 导入
    var suggestsReLogin: Bool {
        if case .unauthenticated = effectiveHealth { return true }
        return false
    }
}
