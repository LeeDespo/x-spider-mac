import Foundation

struct VideoVariant: Codable, Sendable {
    let bitrate: Int?
    let contentType: String?
    let url: String?
}

struct VideoInfo: Codable, Sendable {
    /// GIF 的直接播放地址（上游 animated_gif 的 videoInfo.url）
    let url: String?
    /// 视频时长（毫秒）
    let duration: Double?
    /// 视频清晰度列表（按码率）
    let variants: [VideoVariant]?
    let aspectRatio: [Int]?
}

struct TwitterMedia: Codable, Sendable {
    let id: String?
    /// 缩略图 / 原图地址（photo 的下载源）
    let url: String?
    let width: Int?
    let height: Int?
    let type: MediaType
    let videoInfo: VideoInfo?
    /// 该媒体所属推文的发布时间（记录文件时间锚定判定用；不参与编解码）
    var createdTime: Date?

    /// 展示用宽高比（宽/高）。
    ///
    /// 优先用 `original_info` 的宽高（图片/视频封面都有），
    /// 缺失时回落到视频自带的 `aspect_ratio`，都没有则按 16:9——
    /// 调用方拿到的是**必定可用**的值，不必自己处理 nil。
    ///
    /// 评论缩略图靠它保持比例：@leoakok 那张 947×2048 的竖长图若按 1:1 裁切，
    /// 只会剩下中间一条。
    var aspectRatioValue: CGFloat {
        if let width, let height, width > 0, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        if let ar = videoInfo?.aspectRatio, ar.count == 2, ar[0] > 0, ar[1] > 0 {
            return CGFloat(ar[0]) / CGFloat(ar[1])
        }
        return 16.0 / 9.0
    }
}

enum MediaType: String, Codable, Sendable {
    case photo = "photo"
    case video = "video"
    case gif = "animated_gif"
}
