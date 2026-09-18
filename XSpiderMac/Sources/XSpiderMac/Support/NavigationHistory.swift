import SwiftUI

/// 应用级导航历史：记录"用户去过哪些界面"，供返回按钮逐层回退。
///
/// ## 为什么需要它
///
/// 跳转是多入口的，散落在各处，没有统一的"上一步"概念：
/// - 推文详情里点**引用推文** → 详情浮层换成被引用推文（`DetailOverlayCenter.open`）；
/// - 详情里点**头像** → 关闭浮层 + 主页搜索该用户；
/// - 主页搜索框 → 主页内容换成某个用户的时间线。
///
/// 用户在这些跳转之间需要"返回上一个界面"。各处各自维护会互相打架
/// （典型：从详情 A 跳到详情 B，B 的返回该回到 A 而不是直接关掉浮层），
/// 因此集中成一个显式栈。
///
/// ## 什么会入栈
///
/// 只有**跨越界面**的跳转才入栈；对称操作（打开详情 → 关闭，回到原位）不入栈：
/// - 详情点头像去搜用户 → 入栈 `detail(A)`；
/// - 主页时间线搜索某用户 → 入栈 `home(nil)`；
/// - 主页某次搜索里再搜索别的用户 → 入栈 `home(上一个快照)`。
///
/// ## 设计取舍
///
/// **记录"可重放的目标"而不是引入 NavigationStack**：现有跳转都是就地替换内容，
/// 没有 push/pop 语义；引入真正的导航栈要重写全部入口。这里记录目标 + 重放动作，
/// 改动面最小。
///
/// **主页搜索态用快照还原（零请求）**：重新 `loadUser` 会再打两个 GraphQL 请求，
/// 项目一直在对抗 429，为"回退一步"消耗配额不可接受，且重新加载会丢已翻的页。
///
/// **只在进程内**（不落盘）：与"浏览进度记忆"一致，重启后从干净状态开始。
@MainActor
@Observable
final class NavigationHistory {
    static let shared = NavigationHistory()

    /// 一个可回退的目标。
    enum Entry {
        /// 某条推文详情（按 ID 从详情缓存还原，零请求）
        case detail(postId: String)
        /// 主页状态。`state == nil` 表示主页时间线（非搜索态）。
        case home(HomepageStore.SearchState?)

        /// 去重用的身份标记（同一目标连续出现只保留一条）
        var key: String {
            switch self {
            case .detail(let id): return "detail:\(id)"
            case .home(let state): return "home:\(state?.keyword ?? "")"
            }
        }
    }

    /// 历史栈：最后一个元素 = 当前界面的**前一个**界面。
    private(set) var stack: [Entry] = []
    /// 上限：防止长时间浏览后无限增长（只需回到最近若干层）
    private let limit = 32

    /// 重放动作由 ContentView 在 onAppear 注入 —— 历史层不直接依赖视图。
    /// 两种目标的还原都需要视图/store 参与（详情要浮层，主页要 store），
    /// 因此统一交给注入的闭包。
    var replay: ((Entry) -> Void)?

    private init() {}

    /// 记录"即将离开的界面"。
    func push(_ entry: Entry) {
        if stack.last?.key == entry.key { return }   // 连续重复不入栈
        stack.append(entry)
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
    }

    /// 是否还有可返回的上一个界面
    var canGoBack: Bool { !stack.isEmpty }

    /// 当前栈深。浮层用它记住"进入时"的深度，退出时截断回去。
    var depth: Int { stack.count }

    /// 把栈截断到指定深度（丢弃更晚的记录）。
    ///
    /// 用途：推文详情浮层**关闭**时，这次详情会话里攒下的返回记录（引用链、头像跳转）
    /// 全部作废——用户是"关掉了详情"，不是"返回上一步"。
    /// 不截断的话会残留：关闭详情 A 后从主页打开详情 C，按返回会跳到 A（无关推文）。
    func truncate(to depth: Int) {
        guard stack.count > depth else { return }
        stack.removeLast(stack.count - depth)
    }

    /// 返回上一个界面：弹出并重放。
    /// - Returns: true 表示已回到上一个界面；false 表示栈空（调用方自行兜底）。
    @discardableResult
    func back() -> Bool {
        guard let entry = stack.popLast() else { return false }
        replay?(entry)
        return true
    }

    /// 清空（登出/切账户等：历史里的用户态已失效）
    func reset() {
        stack.removeAll()
    }
}

extension NavigationHistory {
    /// 当前主页状态快照（用于压栈）。非搜索态返回 `.home(nil)`。
    static func currentHomeEntry() -> Entry {
        .home(HomepageStore.shared.snapshotSearchState())
    }
}
