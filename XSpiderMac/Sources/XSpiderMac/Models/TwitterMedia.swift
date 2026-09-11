import Foundation

struct VideoVariant: Sendable {
    let bitrate: Int?
    let contentType: String?
    let url: String?
}

struct VideoInfo: Sendable {
    /// GIF 的直接播放地址（上游 animated_gif 的 videoInfo.url）
    let url: String?
    /// 视频时长（毫秒）
    let duration: Double?
    /// 视频清晰度列表（按码率）
    let variants: [VideoVariant]?
    let aspectRatio: [Int]?
}

struct TwitterMedia: Sendable {
    let id: String?
    /// 缩略图 / 原图地址（photo 的下载源）
    let url: String?
    let width: Int?
    let height: Int?
    let type: MediaType
    let videoInfo: VideoInfo?
}

enum MediaType: String, Sendable {
    case photo = "photo"
    case video = "video"
    case gif = "animated_gif"
}
