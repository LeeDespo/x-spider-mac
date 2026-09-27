import XCTest
@testable import XSpiderMac

/// 缓存**超限回收目标**：超过上限后回收，直到占用降到「上限 × 这个百分比」。
///
/// 与旧语义（「一次清掉已用容量的百分之几」）的区别：目标只由**上限**决定，
/// 与当前占用无关。例：上限 1 GB、目标 60% → 无论超到 2 GB 还是 5 GB，都回收到 600 MB。
final class CacheReclaimTargetTests: XCTestCase {

    /// 默认 60%，且钳在 0–90
    func testDefaultAndClamping() {
        var s = Settings()
        s.app.cacheReclaimTargetPercent = nil
        XCTAssertEqual(s.cacheReclaimTargetPercent, 60, "默认 60%")

        s.app.cacheReclaimTargetPercent = -5
        XCTAssertEqual(s.cacheReclaimTargetPercent, 0, "低于下限钳到 0%")

        s.app.cacheReclaimTargetPercent = 95
        XCTAssertEqual(s.cacheReclaimTargetPercent, 90, "高于上限钳到 90%")

        s.app.cacheReclaimTargetPercent = 45
        XCTAssertEqual(s.cacheReclaimTargetPercent, 45, "区间内原样返回")
    }

    /// 回收目标 = 上限 × 百分比（**不是**已用容量的百分比）
    func testTargetIsPercentOfLimit() {
        let limit: Int64 = 1_000_000_000   // 1 GB
        XCTAssertEqual(ImageCache.reclaimTargetBytes(limitBytes: limit, targetPercent: 60),
                       600_000_000, "上限 1 GB、60% → 回收到 600 MB")

        XCTAssertEqual(ImageCache.reclaimTargetBytes(limitBytes: 200_000_000, targetPercent: 60),
                       120_000_000, "上限 200 MB、60% → 回收到 120 MB")
    }

    /// 目标只与上限有关，和当前占用无关（用户给的例子：上限 1 GB、超到 2 GB → 收到 0.6 GB）
    func testTargetIgnoresCurrentUsage() {
        // 复刻 enforceLimit 的删除循环：从最旧开始删，删到剩余 <= 目标
        func remainingAfterReclaim(sizes: [Int64], limit: Int64, targetPercent: Int64) -> Int64 {
            var remaining = sizes.reduce(0, +)
            let target = ImageCache.reclaimTargetBytes(limitBytes: limit, targetPercent: targetPercent)
            for size in sizes {                      // 调用方已按最旧→最新排序
                guard remaining > target else { break }
                remaining -= size
            }
            return remaining
        }

        // 1 GB 上限、60% → 收到 600 MB；2 GB 占用（每个 100 MB）时删掉 14 个
        let usage2GB = Array(repeating: Int64(100_000_000), count: 20)
        XCTAssertEqual(remainingAfterReclaim(sizes: usage2GB, limit: 1_000_000_000, targetPercent: 60),
                       600_000_000)

        // 5 GB 占用时删到同样的 600 MB（旧语义会随占用越删越多）
        let usage5GB = Array(repeating: Int64(100_000_000), count: 50)
        XCTAssertEqual(remainingAfterReclaim(sizes: usage5GB, limit: 1_000_000_000, targetPercent: 60),
                       600_000_000)
    }

    /// 目标必须**低于上限**（区间上限 90%）——否则清完立刻又超限，反复全目录扫描
    func testTargetAlwaysStaysUnderLimit() {
        let limit: Int64 = 500_000_000
        for percent in [0, 30, 60, 90] {
            XCTAssertLessThan(ImageCache.reclaimTargetBytes(limitBytes: limit,
                                                            targetPercent: Int64(percent)),
                              limit)
        }
    }

    /// 0% = 全部清空
    func testZeroPercentClearsEverything() {
        XCTAssertEqual(ImageCache.reclaimTargetBytes(limitBytes: 1_000_000_000, targetPercent: 0), 0)
    }

    /// 越界值按区间钳制（防调用方传进 100 —— 那是旧语义的合法值）
    func testClampsOutOfRangeInput() {
        XCTAssertEqual(ImageCache.reclaimTargetBytes(limitBytes: 1_000_000_000, targetPercent: 200),
                       900_000_000, "100 以上钳到 90%")
        XCTAssertEqual(ImageCache.reclaimTargetBytes(limitBytes: 1_000_000_000, targetPercent: -10), 0)
    }
}

/// 缓存上限范围：**最低 100 MB**，可选「无上限」
final class CacheLimitRangeTests: XCTestCase {
    func testDefaultIs200MB() {
        var s = Settings()
        s.app.cacheLimitMB = nil
        XCTAssertEqual(s.cacheLimitMB, 200)
    }

    func testMinimumIs100MB() {
        var s = Settings()
        s.app.cacheLimitMB = 50
        XCTAssertEqual(s.cacheLimitMB, 100, "低于 100 MB 钳到 100 MB")
        s.app.cacheLimitMB = 5000
        XCTAssertEqual(s.cacheLimitMB, 5000, "上限不再封顶在 500 MB")
    }

    func testUnlimitedMeansNoCapacityControl() {
        var s = Settings()
        s.app.cacheLimitMB = Settings.unlimitedCacheLimitMB
        XCTAssertEqual(s.cacheLimitMB, Settings.unlimitedCacheLimitMB)
        XCTAssertNil(s.cacheLimitBytes, "无上限时没有可回收的目标")
    }

    /// 上限字节用**十进制** MB（与 ByteCountFormatter.file 的显示口径一致）
    func testLimitBytesAreDecimalMegabytes() {
        var s = Settings()
        s.app.cacheLimitMB = 300
        XCTAssertEqual(s.cacheLimitBytes, 300_000_000)
    }
}

/// 真实落盘验证：`enforceLimit` 从**最旧**的文件开始删，删到目标占用为止。
///
/// 上面几组只验算数；这一组跑真实删除路径（临时目录 + 真实文件），
/// 覆盖"排序方向"和"删到什么程度停"这两件容易写反的事。
final class CacheEvictionOnDiskTests: XCTestCase {

    private let fm = FileManager.default

    /// 造 20 个 10 MB 文件（占用合计 200 MB），越旧 = age 越大
    private func makeCacheDir(count: Int = 20, size: Int = 10_000_000) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xspider-cache-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            let url = dir.appendingPathComponent(String(format: "%02d.bin", i))
            try Data(count: size).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(count - i) * 3600)],
                                 ofItemAtPath: url.path)
        }
        return dir
    }

    private func totalBytes(_ dir: URL) -> Int64 {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    private func names(_ dir: URL) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    /// 超限即回收到「上限 × 目标百分比」，且留下的都是较新的文件
    func testDeletesOldestUntilTarget() throws {
        let dir = try makeCacheDir()
        defer { try? fm.removeItem(at: dir) }

        // 占用 200 MB > 上限 100 MB；目标 60% → 删到 60 MB
        ImageCache.enforceLimit(dir: dir, limitBytes: 100_000_000, targetPercent: 60)

        XCTAssertEqual(totalBytes(dir), 60_000_000, "上限 100 MB、目标 60% → 收到 60 MB")
        let left = names(dir)
        XCTAssertFalse(left.contains("00.bin"), "最旧的文件必须先删")
        XCTAssertEqual(left.count, 6, "10 MB 一个：剩 6 个刚好 60 MB")
    }

    /// 目标 0% → 清空
    func testZeroPercentEmptiesCache() throws {
        let dir = try makeCacheDir(count: 4, size: 1_000_000)
        defer { try? fm.removeItem(at: dir) }

        ImageCache.enforceLimit(dir: dir, limitBytes: 1_000_000, targetPercent: 0)
        XCTAssertEqual(totalBytes(dir), 0, "0% 表示全部清空")
    }

    /// 没超限就不动（避免每次写入都触发全目录删除）
    func testNoOpWhenUnderLimit() throws {
        let dir = try makeCacheDir(count: 4, size: 1_000_000)   // 4 MB
        defer { try? fm.removeItem(at: dir) }

        ImageCache.enforceLimit(dir: dir, limitBytes: 100_000_000, targetPercent: 60)
        XCTAssertEqual(names(dir).count, 4, "未超限时一个文件都不该删")
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
