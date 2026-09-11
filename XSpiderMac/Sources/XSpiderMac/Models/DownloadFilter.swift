import Foundation

struct DownloadFilter: Sendable {
    enum Source: String, CaseIterable, Sendable {
        case medias, tweets
    }

    struct DateRange: Sendable {
        var start: Date
        var end: Date
    }

    var dateRange: DateRange?
    var mediaTypes: [MediaType]?
    var source: Source = .medias
}
