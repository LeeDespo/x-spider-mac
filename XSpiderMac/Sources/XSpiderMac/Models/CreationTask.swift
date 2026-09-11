import Foundation

struct CreationTask: Identifiable, Sendable {
    var id: String
    var user: TwitterUser
    var filter: DownloadFilter
    var status: CreationTaskStatus = .waiting
    var completeCount: Int = 0
    var skipCount: Int = 0
}

enum CreationTaskStatus: String, Sendable {
    case waiting
    case active
    case done
    case error
}
