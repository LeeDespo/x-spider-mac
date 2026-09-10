import Foundation

struct ProxySettings: Codable, Sendable {
    var enable: Bool = true
    var url: String = "http://127.0.0.1:7890"
    var useSystem: Bool = true
}

struct DownloadSettings: Codable, Sendable {
    var saveDirBase: String = ""
    var dirTemplate: String = ""
    var fileNameTemplate: String = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%"
    var sameFileSkip: Bool = true
}

struct AppSettings: Codable, Sendable {
    var autoCheckUpdate: Bool = true
    var acceptPrerelease: Bool = false
    var writeLogs: Bool = false
}

struct Settings: Codable, Sendable {
    var proxy: ProxySettings = ProxySettings()
    var download: DownloadSettings = DownloadSettings()
    var app: AppSettings = AppSettings()

    static let currentVersion = 2
}
