import Foundation

enum FileNameTemplate {
    static func resolve(template: String, data: FileNameTemplateData) -> String {
        let post = data.post
        var result = template
        result = result.replacingOccurrences(of: "%USER_SCREEN_NAME%", with: post.user.screenName)
        result = result.replacingOccurrences(of: "%USER_NAME%", with: post.user.name)
        result = result.replacingOccurrences(of: "%USER_ID%", with: post.user.id)
        result = result.replacingOccurrences(of: "%POST_TIME%", with: fmt(post.createdAt, format: "yyyy-MM-dd HH-mm-ss"))
        result = result.replacingOccurrences(of: "%POST_DATE%", with: fmt(post.createdAt, format: "yyyy-MM-dd"))
        result = result.replacingOccurrences(of: "%POST_ID%", with: post.id)
        result = result.replacingOccurrences(of: "%POST_TEXT%", with: post.fullText ?? "")
        result = result.replacingOccurrences(of: "%POST_VIEWS%", with: post.views.map(String.init) ?? "")
        result = result.replacingOccurrences(of: "%POST_RETWEET_COUNT%", with: post.retweetCount.map(String.init) ?? "")
        result = result.replacingOccurrences(of: "%POST_FAVORITE_COUNT%", with: post.favoriteCount.map(String.init) ?? "")
        result = result.replacingOccurrences(of: "%MEDIA_ID%", with: data.media.id ?? "")
        result = result.replacingOccurrences(of: "%MEDIA_INDEX%", with: "1")
        result = result.replacingOccurrences(of: "%MEDIA_WIDTH%", with: data.media.width.map(String.init) ?? "")
        result = result.replacingOccurrences(of: "%MEDIA_HEIGHT%", with: data.media.height.map(String.init) ?? "")
        result = result.replacingOccurrences(of: "%EXT%", with: data.media.type == .photo ? ".jpg" : ".mp4")
        return result.makeSafeFileName()
    }
}

struct FileNameTemplateData: Sendable {
    let post: TwitterPost
    let media: TwitterMedia
}

private func fmt(_ date: Date?, format: String) -> String {
    guard let date else { return "" }
    let f = DateFormatter()
    f.dateFormat = format
    return f.string(from: date)
}
