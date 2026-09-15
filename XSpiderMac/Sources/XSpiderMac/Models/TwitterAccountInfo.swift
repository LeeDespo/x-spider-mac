import Foundation

struct TwitterAccountInfo: Equatable, Codable, Sendable {
    let screenName: String
    let avatar: String
    /// 账户 restId(旧持久化数据可能没有)
    var id: String? = nil
}
