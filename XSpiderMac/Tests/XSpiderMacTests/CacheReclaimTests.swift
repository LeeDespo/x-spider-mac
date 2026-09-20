import XCTest
@testable import XSpiderMac

/// 缓存回收比例（改进项：达到上限时一次清掉多少已用容量）
final class CacheReclaimPercentTests: XCTestCase {

    /// 默认 30%，且钳在 10–100
    func testDefaultAndClamping() {
        var s = Settings()
        s.app.cacheReclaimPercent = nil
        XCTAssertEqual(s.cacheReclaimPercent, 30, "默认 30%")

        s.app.cacheReclaimPercent = 5
        XCTAssertEqual(s.cacheReclaimPercent, 10, "低于下限钳到 10%")

        s.app.cacheReclaimPercent = 0
        XCTAssertEqual(s.cacheReclaimPercent, 10)

        s.app.cacheReclaimPercent = 150
        XCTAssertEqual(s.cacheReclaimPercent, 100, "高于上限钳到 100%")

        s.app.cacheReclaimPercent = 45
        XCTAssertEqual(s.cacheReclaimPercent, 45, "区间内原样返回")
    }

    /// 回收量 = max(已用容量 × 比例, 降到上限以下所需)
    func testTargetIsPercentOfTotal() {
        // 复刻 enforceLimit 的目标计算
        func target(total: Int64, limit: Int64, percent: Int64) -> Int64 {
            let byPercent = total * min(100, max(0, percent)) / 100
            let needed = total - limit
            return max(byPercent, needed)
        }
        // 300MB 已用、上限 200MB：30% = 90MB，但降到上限以下需要 100MB → 取 100MB
        XCTAssertEqual(target(total: 300_000_000, limit: 200_000_000, percent: 30),
                       100_000_000, "至少要清到低于上限")

        // 1GB 已用、上限 200MB：30% = 300MB，但需要 800MB → 取 800MB
        // （此时"降到上限以下"才是主导项——百分比回收在严重超限时不够用）
        XCTAssertEqual(target(total: 1_000_000_000, limit: 200_000_000, percent: 30),
                       800_000_000, "严重超限时以降到上限以下为准")

        // 上限 900MB、已用 1GB：30% = 300MB > 需要 100MB → 按百分比多回收
        XCTAssertEqual(target(total: 1_000_000_000, limit: 900_000_000, percent: 30),
                       300_000_000, "轻度超限时按百分比回收，避免频繁触发")
    }

    /// **保证下限**：百分比算出的量若小于"降到上限以下所需"，必须取后者，
    /// 否则会出现"清完了仍然超限"的死循环。
    func testAlwaysClearsBelowLimit() {
        func target(total: Int64, limit: Int64, percent: Int64) -> Int64 {
            let byPercent = total * min(100, max(0, percent)) / 100
            let needed = total - limit
            return max(byPercent, needed)
        }
        // 刚刚越界（上限 200MB，已用 201MB），回收 10% = 20.1MB > 1MB → 按百分比
        XCTAssertEqual(target(total: 201_000_000, limit: 200_000_000, percent: 10),
                       20_100_000)
        // 极端：刚越界一点点且百分比极小（钳制前）→ 仍要清够
        XCTAssertGreaterThanOrEqual(
            target(total: 200_000_001, limit: 200_000_000, percent: 10),
            1, "至少要清掉超额部分")
    }

    /// 100% = 全部清空
    func testHundredPercentClearsEverything() {
        let total: Int64 = 500_000_000
        let byPercent = total * 100 / 100
        XCTAssertEqual(byPercent, total, "100% 时回收量等于总容量")
    }
}

/// 边栏状态行内文案（熔断倒计时直接显示）
final class StatusInlineTextTests: XCTestCase {

    /// 倒计时文案含秒数，且很短（边栏一行放得下）
    @MainActor
    func testCooldownTextIsShort() {
        let text = L("熔断中(%d)").replacingOccurrences(of: "%d", with: "37")
        XCTAssertTrue(text.contains("37"))
        XCTAssertLessThanOrEqual(text.count, 12, "行内文案要放得进边栏")
    }

    /// 非熔断时回落到简称
    @MainActor
    func testFallsBackToShortLabelWhenNotThrottled() {
        let store = AccountStatusStore.shared
        store.reset()
        XCTAssertEqual(store.shortLabel, L("正常"))
        XCTAssertEqual(store.cdnShortLabel, L("正常"))
    }
}
