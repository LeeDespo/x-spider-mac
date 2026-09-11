import Foundation
import os

/// 结构化应用日志：分类 + 级别 + 文件持久化。
/// - 分类：NET / DL / HOME / SETTINGS / APP（对齐上游 log.category）
/// - 持久化：~/Library/Logs/XSpiderMac/app-YYYY-MM-DD.log（按天滚动）
/// - 格式：时间 级别 [分类] 消息 {结构化字段}
enum AppLogger {
    private static let subsystem = "moe.keli.xspider.mac"
    private static let logger = Logger(subsystem: subsystem, category: "app")
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return f
    }()

    /// 是否写日志文件（设置项 app.logEnabled，默认 false）
    static var fileLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "app.logEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "app.logEnabled") }
    }

    // MARK: - 公开 API

    static func debug(_ message: String, category: String = "APP", _ fields: [String: String] = [:]) {
        log(.debug, message, category: category, fields)
    }

    static func info(_ message: String, category: String = "APP", _ fields: [String: String] = [:]) {
        log(.info, message, category: category, fields)
    }

    static func warn(_ message: String, category: String = "APP", _ fields: [String: String] = [:]) {
        log(.fault, message, category: category, fields)
    }

    static func error(_ message: String, category: String = "APP", _ fields: [String: String] = [:]) {
        log(.error, message, category: category, fields)
    }

    /// 下载/网络请求专用（带耗时）
    static func perf(_ message: String, category: String = "DL", ms: Double, _ fields: [String: String] = [:]) {
        log(.info, message, category: category, fields.merging(["ms": String(format: "%.0f", ms)]) { _, new in new })
    }

    // MARK: - 核心

    private static func log(_ level: OSLogType, _ message: String, category: String, _ fields: [String: String]) {
        let osLogger = Logger(subsystem: subsystem, category: category)
        let fieldsString = fields.isEmpty ? "" : " " + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let line = "\(isoFormatter.string(from: Date())) \(levelLabel(level)) [\(category)] \(message)\(fieldsString)"

        switch level {
        case .debug: osLogger.debug("\(line, privacy: .public)")
        case .info: osLogger.info("\(line, privacy: .public)")
        case .error: osLogger.error("\(line, privacy: .public)")
        default: osLogger.fault("\(line, privacy: .public)")
        }

        if fileLoggingEnabled {
            writeFile(line)
        }
    }

    private static func levelLabel(_ level: OSLogType) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .error: return "ERROR"
        default: return "WARN"
        }
    }

    // MARK: - 文件日志（按天滚动）

    static var logDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Logs/XSpiderMac", isDirectory: true)
    }

    static var currentLogFile: URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "app-'yyyy-MM-dd'.log'"
        return logDirectory.appendingPathComponent(f.string(from: Date()))
    }

    private static let writeQueue = DispatchQueue(label: "moe.keli.xspider.mac.logfile", qos: .utility)

    private static func writeFile(_ line: String) {
        writeQueue.async {
            let dir = logDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = (line + "\n").data(using: .utf8)!
            if let handle = try? FileHandle(forWritingTo: currentLogFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: currentLogFile)
            }
        }
    }

    // MARK: - 导出

    /// 导出全部日志到指定目录，返回导出文件路径列表
    static func exportLogs(to directory: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)) ?? []
        var exported: [URL] = []
        for file in files where file.pathExtension == "log" {
            let dest = directory.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: file, to: dest)
            exported.append(dest)
        }
        return exported
    }

    static var logFileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: logDirectory.path))?.filter { $0.hasSuffix(".log") }.count ?? 0
    }
}
