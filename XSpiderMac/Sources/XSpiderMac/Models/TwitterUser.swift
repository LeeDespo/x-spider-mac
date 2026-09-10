import Foundation

struct TwitterUser: Codable, Sendable {
    let screenName: String
    let avatar: String
    let name: String
    let id: String
    let mediaCount: Int?
    let registerTime: Date?
}
