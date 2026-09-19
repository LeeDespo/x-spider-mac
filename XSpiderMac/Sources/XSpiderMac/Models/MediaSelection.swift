import Foundation

/// 媒体选择状态：**勾选 = 要下载**。
///
/// ## 为什么需要两种模式
///
/// 需求核心：**「全选」必须表示"全部"，而不是"已加载的那些"**。
/// 若全选只覆盖已加载部分，用户无法确定自己到底选了什么
/// （需求原文：全选状态下取消几个，创建任务时**跳过取消的这几个**）。
///
/// 而"全部"里的未加载部分只能靠爬虫补齐，因此"全选"无法用一个明确的
/// ID 集合表示——**排除法**才是正确表示：
///
/// - `.include`：`keys` = 已勾选，要下载的就是它们（用户逐个点选）；
/// - `.exclude`：`keys` = 已取消，**除它们之外全部**要下载（"全选"态）。
///
/// 两者可以互相切换（`invert()` 就是如此），因为"补集"恰好是换模式而集合不变。
struct MediaSelection: Equatable {
    enum Mode: Equatable {
        case include   // 勾选集合 = 要下载
        case exclude   // 排除集合 = 不要下载（其余全部要）
    }

    private(set) var mode: Mode = .include
    private(set) var keys: Set<String> = []

    /// 是否处于「全选」态（除排除项外全部要下载）
    var isAllSelected: Bool { mode == .exclude }

    /// 某项是否被勾选
    func isSelected(_ key: String) -> Bool {
        mode == .include ? keys.contains(key) : !keys.contains(key)
    }

    /// 勾选数量。
    ///
    /// `.include` 直接是集合大小；`.exclude` 需要**总数**才能算——
    /// 未加载完时总数未知，返回 nil（需求：不知道有多少就不显示「已选 n/m」）。
    func selectedCount(knownTotal: Int?) -> Int? {
        switch mode {
        case .include:
            return keys.count
        case .exclude:
            guard let knownTotal else { return nil }
            return max(0, knownTotal - keys.count)
        }
    }

    /// 下载时要**排除**的键（只有全选态有值），交给爬虫跳过
    var excludedKeys: Set<String> { mode == .exclude ? keys : [] }

    /// 显式勾选的键（只有 include 态有值），用于"只下载眼前这些"
    var includedKeys: Set<String> { mode == .include ? keys : [] }

    /// 点一下某项：切换它的勾选状态。
    /// `.exclude` 态下取消一项 = 把它加进排除集合。
    mutating func toggle(_ key: String) {
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
    }

    /// 全选：排除集合清空 = 全部都下载
    mutating func selectAll() {
        mode = .exclude
        keys = []
    }

    /// 全不选：勾选集合清空 = 一个都不下载
    mutating func selectNone() {
        mode = .include
        keys = []
    }

    /// 反选。两种模式下的补集都恰好是「换模式而集合不变」：
    /// - `.include{K}`（要 K）→ `.exclude{K}`（除 K 外全部）
    /// - `.exclude{K}`（除 K 外全部）→ `.include{K}`（只要 K）
    mutating func invert() {
        mode = (mode == .include) ? .exclude : .include
    }

    mutating func reset() {
        mode = .include
        keys = []
    }
}

/// 媒体选择键。
///
/// **必须稳定且可复现**：爬虫要用同一个键判断"这条要不要跳过"，
/// 所以不能掺入 `UUID`（旧实现用 `UUID().uuidString` 兜底，
/// 导致勾选态无法与爬虫侧的键对应上）。
enum MediaSelectionKey {
    /// `postId/mediaId`；mediaId 缺失时用 url 兜底（两者都缺的媒体本就无法下载）
    static func make(post: TwitterPost, media: TwitterMedia) -> String {
        "\(post.id)/\(media.id ?? media.url ?? "")"
    }
}
