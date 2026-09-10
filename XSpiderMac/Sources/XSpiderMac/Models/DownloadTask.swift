import Foundation

enum DownloadStatus: String, Codable, Sendable {
    case waiting
    case active
    case paused
    case error
    case complete
    case removed
}

struct DownloadTask: Codable, Identifiable, Sendable {
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
}
