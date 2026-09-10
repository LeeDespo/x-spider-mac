import Foundation

struct DownloadFilter: Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case medias, tweets
    }

    struct DateRange: Codable, Sendable {
        var start: Date
        var end: Date
    }

    var dateRange: DateRange?
    var mediaTypes: [MediaType]?
    var source: Source = .medias
}
