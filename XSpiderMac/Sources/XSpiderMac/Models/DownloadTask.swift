import Foundation

struct DownloadTask: Identifiable, Sendable {
    var id: String { gid }
    var gid: String
    var post: TwitterPost
    var media: TwitterMedia
    var fileName: String
    var dir: String
    var totalSize: Int64
    var completeSize: Int64
    var status: DownloadStatus
    var error: String?
    var updatedAt: Date
    var downloadUrl: String
    var retryCountRemains: Int
    /// 实际使用的引擎（auto 模式下按大小分流后落定）。
    /// 恢复任务时用于判断"引擎是否已变更"——变了就丢弃断点重下，
    /// 避免 URLSession 的 resumeData 与 aria2 的半成品拼出损坏文件。
    var engine: DownloadEngine?
}

enum DownloadStatus: String, Sendable {
    case waiting
    case active
    case paused
    case error
    case complete
    case removed
}
