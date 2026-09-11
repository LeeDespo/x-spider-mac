import Foundation

struct TwitterUser: Sendable {
    let screenName: String
    let avatar: String
    let name: String
    let id: String
    let mediaCount: Int?
    let registerTime: Date?
}
