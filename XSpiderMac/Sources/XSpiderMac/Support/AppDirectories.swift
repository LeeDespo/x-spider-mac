import Foundation

/// 应用数据目录规范（所有应用产生的文件都收拢在这里，便于一键清理）：
///   ~/Library/Application Support/XSpiderMac/   数据根目录
///     ├── Temp/                                 下载暂存（跨引擎统一）
///     └── aria2/                                aria2 会话/控制文件
///   ~/Library/Caches/XSpiderMac/                URL 缓存（URLSession 自动使用）
///   ~/Library/Logs/XSpiderMac/                  日志（xspider.log + 轮转）
/// 下载媒体文件由用户选择保存位置，不属于应用数据，清理时永远不碰。
enum AppDirectories {
    /// Application Support/XSpiderMac（数据根）
    static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("XSpiderMac", isDirectory: true)
    }

    /// 数据文件（下载历史 JSON 等小文件）
    static var support: URL { supportRoot }

    /// 下载暂存目录（暂存完成文件再落盘）
    static var staging: URL {
        supportRoot.appendingPathComponent("Temp", isDirectory: true)
    }

    /// aria2 会话目录
    static var aria2: URL {
        supportRoot.appendingPathComponent("aria2", isDirectory: true)
    }

    /// aria2Next 续传状态目录（`--state-dir`）。
    ///
    /// aria2Next 不再在下载目录旁生成 `.aria2` 控制文件，HTTP 续传状态改存
    /// `state-dir/stream/state.db`（SQLite）。默认落在
    /// `~/Library/Application Support/aria2-next`，这里显式指到本应用数据目录，
    /// 便于随应用数据一起管理与清理。
    static var aria2State: URL {
        aria2.appendingPathComponent("state", isDirectory: true)
    }

    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("XSpiderMac", isDirectory: true)
    }

    /// 图片缓存目录（Application Support/XSpiderMac/Cache/images，便于与媒体数据一起管理）
    static var cacheRoot: URL {
        supportRoot.appendingPathComponent("Cache", isDirectory: true)
    }

    /// 集中式媒体记录目录（`MEDIA_RECORDS.md` §3）：
    ///   records/downloads/<账号 id>.json   下载记录（一账号一文件）
    ///   records/sync.json                  同步记录（所有账号一个文件）
    ///
    /// **"清理数据"不删这里**：记录是"重启后能不能对账"的依据，
    /// 一键清理把用户媒体文件留下了、却把判定用的记录清空，比不清理更坏
    /// （表现为整库重下）。见 `cleanupTargets` 的排除说明。
    static var recordsRoot: URL {
        supportRoot.appendingPathComponent("records", isDirectory: true)
    }

    static var logs: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Logs/XSpiderMac", isDirectory: true)
    }

    /// 确保目录存在（应用启动时调用）
    static func ensureAll() {
        for dir in [supportRoot, staging, aria2, aria2State, cacheRoot, recordsRoot] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 清理目标清单（供确认弹窗展示 + 执行删除）
    /// 只包含应用自己创建的目录，绝不含用户媒体保存位置和系统目录。
    ///
    /// 注意 `supportRoot` 是**逐个删除子目录**而不是整目录删除：
    /// `records/` 必须留下（见 `recordsRoot` 的说明）。
    static var cleanupTargets: [(url: URL, label: String)] {
        [
            (supportRoot, "应用数据（下载暂存、aria2 会话、图片缓存）"),
            (caches, "缓存（URL 缓存数据库）"),
            (logs, "日志（xspider.log 及历史）"),
        ]
    }

    /// 执行清理：删除应用创建的所有数据/缓存/日志目录
    static func cleanupAll() {
        let fm = FileManager.default
        for (dir, _) in cleanupTargets {
            if dir == supportRoot {
                // 记录目录不能被一键清理带走：只删 supportRoot 下的其它子目录，
                // 最后再尝试删空后 supportRoot 本身（有 records 时它非空，自然失败）。
                // 按 **path** 比较而不是 URL 相等：`contentsOfDirectory` 给出的子项 URL
                // 不带目录尾斜杠，而 `appendingPathComponent(_:isDirectory:)` 带。
                let keep = recordsRoot.standardizedFileURL.path
                let children = (try? fm.contentsOfDirectory(at: supportRoot,
                                                            includingPropertiesForKeys: nil)) ?? []
                for child in children where child.standardizedFileURL.path != keep {
                    try? fm.removeItem(at: child)
                }
                try? fm.removeItem(at: supportRoot)
            } else {
                try? fm.removeItem(at: dir)
            }
        }
        // 同步清掉 UserDefaults（偏好设置也属于应用数据；媒体文件不受影响）
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}


// MARK: - 通用日期格式化（记录文件锚点用）

extension DateFormatter {
    /// yyyy-MM-dd（本地时区）
    static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static var fallback: DateFormatter { dayOnly }
}
