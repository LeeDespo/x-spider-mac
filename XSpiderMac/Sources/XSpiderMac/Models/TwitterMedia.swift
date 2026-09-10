import Foundation

struct VideoVariant: Codable, Sendable {
    let bitrate: Int?
    let contentType: String?
    let url: String?
}

struct VideoInfo: Codable, Sendable {
    let duration: Int?
    let variants: [VideoVariant]?
    let aspectRatio: [Int]?
}

struct TwitterMedia: Codable, Sendable {
    let id: String?
    let url: String?
    let width: Int?
    let height: Int?
    let type: MediaType
    let videoInfo: VideoInfo?
}
