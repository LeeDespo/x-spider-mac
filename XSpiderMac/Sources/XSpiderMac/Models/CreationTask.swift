import Foundation

enum CreationTaskStatus: String, Codable, Sendable {
    case waiting
    case active
    case done
    case error
}

struct CreationTask: Codable, Identifiable, Sendable {
    var id: String
    var user: TwitterUser
    var filter: DownloadFilter
    var status: CreationTaskStatus = .waiting
    var completeCount: Int = 0
    var skipCount: Int = 0
}
