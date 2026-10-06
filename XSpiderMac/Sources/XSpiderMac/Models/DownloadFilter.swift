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

// MARK: - 契约日期串（与 `DateRange` 同源：本地日历 ↔ 组件的日期参数）

extension Date {
    /// 日期 → `yyyy-MM-dd`（**本地时区**，与 DatePicker 的日历一致）。
    ///
    /// 契约的 `since` / `until`（`fetch.search_timeline`）与爬虫策略的同名参数
    /// 都按**本地日历**理解且**含当天**（组件内部再按排他语义 +1 天，外壳不要再加）。
    /// 这里必须按本地时区格式化：用 UTC 会在东八区得到"前一天"的日期串，
    /// 把整个范围偏移一天（实测踩过）。
    var searchDateString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }

    /// 次日（按本地日历，处理跨月/跨年）。
    ///
    /// 爬虫策略用它把「至」放宽到次日：组件按 **UTC 天**粗筛，
    /// 精确边界由 `CreationTaskStore.decide` 再按本地日历判一次。
    var nextDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: self) ?? self.addingTimeInterval(86400)
    }
}
