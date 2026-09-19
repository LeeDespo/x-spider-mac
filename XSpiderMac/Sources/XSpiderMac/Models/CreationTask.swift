import Foundation

struct CreationTask: Identifiable, Sendable {
    var id: String
    var user: TwitterUser
    var filter: DownloadFilter
    var status: CreationTaskStatus = .waiting
    var completeCount: Int = 0
    var skipCount: Int = 0

    /// 要**跳过**的媒体键（`MediaSelectionKey` 生成）。
    ///
    /// 用于「全选后取消几个」：全选态下用户取消的项记在这里，爬虫遇到就跳过。
    /// 为什么不用"要下载的集合"表示全选：未加载部分不在前端，
    /// 只有排除法能表达"除这几个之外全部要"。
    var excludedKeys: Set<String> = []

    /// 只处理这些媒体键（用户只勾了几个的 include 态）；为空则按 filter 全量。
    var includedKeys: Set<String> = []
}

enum CreationTaskStatus: String, Sendable {
    case waiting
    case active
    case done
    case error
}
