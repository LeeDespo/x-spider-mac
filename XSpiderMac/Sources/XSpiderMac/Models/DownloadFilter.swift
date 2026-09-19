import Foundation

struct DownloadFilter: Sendable {
    enum Source: String, CaseIterable, Sendable {
        case medias, tweets
    }

    struct DateRange: Sendable {
        var start: Date
        var end: Date

        /// 「至」当天的**结束时刻**（本地 23:59:59.999）。
        ///
        /// **为什么需要它**：`DatePicker` 给的 `end` 是**当天零点**，
        /// 直接用 `createdAt <= end` 会把「至」那天的内容**整天排除**——
        /// 而用户视角的「至 8-31」显然包含 8-31 全天。
        ///
        /// 两处判定都必须用它：展示过滤（`applyDisplayFilter`）与爬虫
        /// （`CreationTaskStore` 的 `until`），否则两边的边界语义会不一致。
        var inclusiveEnd: Date {
            Calendar.current.date(byAdding: .day, value: 1, to: end)?
                .addingTimeInterval(-0.001) ?? end
        }
    }

    var dateRange: DateRange?
    var mediaTypes: [MediaType]?
    var source: Source = .medias
}
