import Foundation
import IOKit.pwr_mgt

/// 下载期间阻止系统休眠（规范做法：IOKit 电源断言）。
/// 不用 caffeinate 子进程、不改系统设置，系统仅在应用持有断言期间保持唤醒，
/// 退出/崩溃时自动释放，不会被判定为异常。
final class SleepPreventer: @unchecked Sendable {
    static let shared = SleepPreventer()

    /// 设置项：有下载任务时阻止休眠（默认开）
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "app.preventSleepDuringDownload") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "app.preventSleepDuringDownload") }
    }

    private var assertionID: IOPMAssertionID = 0
    private var active = false
    private let lock = NSLock()

    /// 有活跃下载任务时调用
    func beginPreventing() {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, !active else { return }
        let reason = "X-Spider 正在下载媒体文件" as NSString
        var newAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as NSString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newAssertionID
        )
        if result == kIOReturnSuccess {
            assertionID = newAssertionID
            active = true
            AppLogger.info("电源断言已创建（阻止休眠）", category: "APP")
        } else {
            AppLogger.error("电源断言创建失败", category: "APP", ["kr": String(result)])
        }
    }

    /// 下载全部结束/暂停时调用
    func endPreventing() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        let result = IOPMAssertionRelease(assertionID)
        active = false
        if result == kIOReturnSuccess {
            AppLogger.info("电源断言已释放", category: "APP")
        } else {
            AppLogger.warn("电源断言释放失败", category: "APP", ["kr": String(result)])
        }
    }

    /// 下载任务数变化时统一入口
    func update(activeDownloadCount: Int) {
        if activeDownloadCount > 0 { beginPreventing() } else { endPreventing() }
    }
}
