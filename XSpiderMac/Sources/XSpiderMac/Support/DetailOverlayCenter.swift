import SwiftUI

/// 推文详情浮层的全局中枢：任何页面都能打开；ContentView 在 NavigationSplitView 之上挂全窗浮层。
/// 挂在全窗层级 = 浮层覆盖边栏,点击边栏/任何非卡区都会命中浮层命中层 → 退出。
///
/// ## 返回语义
///
/// 详情浮层内部可以继续跳转：点**引用推文**打开被引用推文、点**头像**去搜该用户。
/// 这两种跳转都记进 `NavigationHistory`，由「返回」按钮逐层回退：
/// - 详情 A →（点引用）→ 详情 B：返回回到 A，再返回才关闭浮层；
/// - 详情 A →（点头像）→ 用户搜索页：返回回到 A 的详情。
///
/// 谁该被记进历史由调用方声明：从主页/网格**新开**详情是进入浮层，不记；
/// 在浮层**内部**跳转才记（`openFromDetail` / `searchUser`）。
@MainActor
@Observable
final class DetailOverlayCenter {
    static let shared = DetailOverlayCenter()

    var post: TwitterPost?
    var initialMediaIndex: Int = 0

    /// 点击头像 → 搜索该用户(由 ContentView 注入,内部转通知)
    var onSearchUser: ((String) -> Void)?

    /// 已打开过的推文缓存（按 ID）：返回还原时取用，**不再发请求**。
    private var cache: [String: TwitterPost] = [:]
    private let cacheLimit = 64

    /// 进入浮层时的导航栈深度。关闭浮层时截断回这里，
    /// 丢弃本次详情会话里攒下的返回记录（理由见 `NavigationHistory.truncate`）。
    private var entryDepth = 0

    /// 从主页/媒体网格打开详情（进入浮层，不入历史）。
    func open(_ post: TwitterPost, mediaIndex: Int = 0) {
        noteEntryIfNeeded()
        remember(post)
        initialMediaIndex = mediaIndex
        self.post = post
    }

    /// 在浮层内部跳转（点引用推文 / 评论里点开某条）：把当前推文记入历史，
    /// 这样「返回」会回到它。
    func openFromDetail(_ post: TwitterPost, mediaIndex: Int = 0) {
        if let current = self.post, current.id != post.id {
            NavigationHistory.shared.push(.detail(postId: current.id))
        }
        open(post, mediaIndex: mediaIndex)
    }

    /// 浮层从"关闭"变为"打开"时记住当时的栈深（浮层内部的多次跳转不再刷新它）。
    private func noteEntryIfNeeded() {
        if post == nil {
            entryDepth = NavigationHistory.shared.depth
        }
    }

    /// 返回：先走导航历史（上一条推文 / 上一个主页状态），栈空才关闭浮层。
    func back() {
        if !NavigationHistory.shared.back() {
            close()
        }
    }

    /// 点击头像 → 搜索该用户。
    ///
    /// **入栈顺序很关键**：先压主页状态（更早的界面），再压详情（上一个界面）。
    /// 于是用户在搜索界面按返回会依次回到：详情 → 主页，
    /// 正好对应"我点进了一个用户，之前在看这条推文，再之前在看主页"。
    /// 顺序反了的话，第一次返回会跳过详情直接回主页。
    ///
    /// **注意**：这里的"关闭浮层"用 `dismissOverlay()`（只清 post），
    /// 不能用 `close()`——后者会截断历史，把刚压进去的两条返回记录一起丢掉。
    func searchUser(_ screenName: String) {
        if let current = post {
            NavigationHistory.shared.push(NavigationHistory.currentHomeEntry())
            NavigationHistory.shared.push(.detail(postId: current.id))
        }
        dismissOverlay()
        onSearchUser?(screenName)
    }

    /// 由导航历史还原到某条推文详情（零请求）。
    /// - Returns: false 表示缓存里没有该推文（调用方兜底关闭浮层）。
    @discardableResult
    func restore(id: String) -> Bool {
        guard let cached = cache[id] else { return false }
        initialMediaIndex = 0
        post = cached
        return true
    }

    /// 取缓存里的推文（供外部判断/还原用）
    func cachedPost(id: String) -> TwitterPost? { cache[id] }

    /// 关闭浮层（用户明确离开详情，而非逐层返回）。
    ///
    /// **必须截断历史**：本次会话里攒的返回记录（引用链、头像跳转）此时全部作废。
    /// 不截断会残留——关闭详情 A 后从主页打开详情 C，按返回会跳到无关的 A。
    /// 缓存（`cache`）保留：头像跳转的「返回」要靠它取回原详情。
    func close() {
        NavigationHistory.shared.truncate(to: entryDepth)
        dismissOverlay()
    }

    /// 只收起浮层，**不动历史**。
    ///
    /// 供两条路径使用：
    /// - `searchUser`（跳去搜索，但要保留"返回回详情"的记录）；
    /// - ContentView 重放 `.home` 历史（back 已经弹好栈，这里不能再截断，
    ///   否则会把更早的返回记录一起丢掉）。
    func dismissOverlay() {
        post = nil
        initialMediaIndex = 0
    }

    private func remember(_ post: TwitterPost) {
        cache[post.id] = post
        guard cache.count > cacheLimit else { return }
        // 简单淘汰：优先丢最旧的（字典无序，取一个非当前项即可——缓存只为加速）
        if let stale = cache.keys.first(where: { $0 != post.id }) {
            cache.removeValue(forKey: stale)
        }
    }
}
