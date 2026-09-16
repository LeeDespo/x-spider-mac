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

    // MARK: - 上报（全部为 O(1) 值比较，状态未变则零开销返回）

    /// 成功响应：仅在非正常时才复位（热路径上的唯一开销是一次枚举比较）
    func noteSuccess() {
        guard health != .normal else { return }
        health = .normal
        changedAt = Date()
        AppLogger.info("账号状态恢复正常", category: "NET")
    }

    /// 触发限流（429）
    func noteRateLimited(retryAfter: TimeInterval?) {
        let until = retryAfter.map { Date().addingTimeInterval($0) }
        let next = Health.rateLimited(until: until)
        // 同状态且预计恢复时间未变 → 不重复写（429 会连续发生，避免每请求都重绘）
        if case .rateLimited(let oldUntil) = health, oldUntil == until { return }
        health = next
        changedAt = Date()
        AppLogger.warn("账号状态:触发限流", category: "NET", [
            "retryAfterSec": retryAfter.map { String(format: "%.0f", $0) } ?? "-",
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
        switch health {
        case .normal: return nil
        case .rateLimited: return L("429 限流")
        case .unauthenticated: return L("登录失效")
        case .serverError: return L("服务异常")
        case .networkError: return L("网络异常")
        }
    }

    /// 悬停说明
    var helpText: String {
        switch health {
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
        switch health {
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
        if case .unauthenticated = health { return true }
        return false
    }
}
