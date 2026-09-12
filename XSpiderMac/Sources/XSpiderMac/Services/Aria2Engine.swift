import Foundation

/// aria2c 进程引擎：每个任务启动一个 aria2c 子进程（多连接分块 + 断点续传）。
/// 优点：业界成熟的多连接下载器，弱网/大文件速度与稳定性远超单连接 URLSession。
/// 生命周期由 DownloadStore 控制；进度通过 --summary-interval 输出解析。
final class Aria2Engine: @unchecked Sendable {
    static let shared = Aria2Engine()

    private var processes: [String: Process] = [:]
    private let lock = NSLock()

    /// aria2c 可执行文件路径（bundle 内置优先，其次 homebrew）
    static let binaryURL: URL? = {
        let candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/aria2c"),
            URL(fileURLWithPath: "/opt/homebrew/bin/aria2c"),
            URL(fileURLWithPath: "/usr/local/bin/aria2c"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    static var isAvailable: Bool { binaryURL != nil }

    // MARK: - 系统代理探测（aria2c 进程不继承系统代理，必须显式传）

    /// 主路径 CFNetwork；App 内偶发取不到时回退解析 `scutil --proxy`。
    static func systemProxy() -> String? {
        if let viaCF = systemProxyViaCFNetwork() { return viaCF }
        return systemProxyViaScutil()
    }

    private static func systemProxyViaCFNetwork() -> String? {
        guard let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        func flag(_ key: String) -> Bool? {
            if let b = dict[key] as? Bool { return b }
            if let i = dict[key] as? Int { return i != 0 }
            if let n = dict[key] as? NSNumber { return n.boolValue }
            return nil
        }
        if flag("kCFNetworkProxiesHTTPSEnable") == true,
           let host = dict["kCFNetworkProxiesHTTPSProxy"] as? String,
           let port = dict["kCFNetworkProxiesHTTPSPort"] as? Int {
            return "http://\(host):\(port)"
        }
        if flag("kCFNetworkProxiesHTTPEnable") == true,
           let host = dict["kCFNetworkProxiesHTTPProxy"] as? String,
           let port = dict["kCFNetworkProxiesHTTPPort"] as? Int {
            return "http://\(host):\(port)"
        }
        if flag("kCFNetworkProxiesSOCKSEnable") == true,
           let host = dict["kCFNetworkProxiesSOCKSProxy"] as? String,
           let port = dict["kCFNetworkProxiesSOCKSPort"] as? Int {
            return "socks5://\(host):\(port)"
        }
        return nil
    }

    /// 回退：解析 scutil --proxy 文本（进程无关，可靠性最高）
    private static func systemProxyViaScutil() -> String? {
        guard let out = Process.runAndRead("/usr/sbin/scutil", args: ["--proxy"]) ?? Process.runAndRead("/usr/bin/scutil", args: ["--proxy"]) else { return nil }
        func value(_ key: String) -> String? {
            guard let range = out.range(of: "\(key) : ") else { return nil }
            let rest = out[range.upperBound...]
            return rest.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        }
        func enabled(_ key: String) -> Bool { value(key) == "1" }
        if enabled("HTTPSEnable"), let host = value("HTTPSProxy"), let port = Int(value("HTTPSPort") ?? "") {
            return "http://\(host):\(port)"
        }
        if enabled("HTTPEnable"), let host = value("HTTPProxy"), let port = Int(value("HTTPPort") ?? "") {
            return "http://\(host):\(port)"
        }
        if enabled("SOCKSEnable"), let host = value("SOCKSProxy"), let port = Int(value("SOCKSPort") ?? "") {
            return "socks5://\(host):\(port)"
        }
        return nil
    }

    // MARK: - 启动

    var progressHandler: ((String, Int64, Int64) -> Void)?
    var completionHandler: ((String, Result<URL, Error>) -> Void)?

    /// 启动 aria2c 下载
    func start(gid: String, urlString: String, destDir: String, fileName: String, proxy: String?, connections: Int = 8, minSplitSizeMB: Int = 1, fileAllocation: String = "none") {
        lock.lock()
        if processes[gid] != nil { lock.unlock(); return }
        lock.unlock()

        guard let binary = Self.binaryURL else {
            completionHandler?(gid, .failure(EngineError.binaryNotFound))
            return
        }

        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let destPath = (destDir as NSString).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(atPath: destPath)

        let perServer = min(16, max(1, connections))
        let p = Process()
        p.executableURL = binary
        p.arguments = [
            urlString,
            "--dir=\(destDir)",
            "--out=\(fileName)",
            "--split=\(perServer)",
            "--max-connection-per-server=\(perServer)",
            "--min-split-size=\(max(1, minSplitSizeMB))M",
            "--continue=true",
            "--summary-interval=1",
            "--console-log-level=warn",
            "--file-allocation=\(fileAllocation)",
            "--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
            "--referer=https://x.com/",
            "--auto-file-renaming=false",
            "--allow-overwrite=true",
            "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
        ]
        if let proxy, !proxy.isEmpty {
            p.arguments?.append("--all-proxy=\(proxy)")
        }

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: CharacterSet(charactersIn: "\n\r")) where !line.isEmpty {
                self?.parseProgressLine(line, gid: gid)
            }
        }

        p.terminationHandler = { [weak self] process in
            self?.lock.lock()
            self?.processes.removeValue(forKey: gid)
            self?.lock.unlock()

            let succeeded = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: destPath)
            if succeeded {
                self?.completionHandler?(gid, .success(URL(fileURLWithPath: destPath)))
            } else {
                self?.completionHandler?(gid, .failure(EngineError.failed("aria2c exit \(process.terminationStatus)")))
            }
        }

        do {
            try p.run()
            lock.lock()
            processes[gid] = p
            lock.unlock()
            AppLogger.info("aria2c 任务启动", category: "DL", [
                "gid": gid, "split": "\(perServer)", "proxy": proxy ?? "none",
            ])
        } catch {
            completionHandler?(gid, .failure(EngineError.failed("aria2c 启动失败: \(error.localizedDescription)")))
        }
    }

    // MARK: - 进度解析

    private func parseProgressLine(_ line: String, gid: String) {
        // 形如: [#a1b2c3 4.2MiB/12MiB(35%) 1.2MiB/sec]
        guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]") else { return }
        let body = line[line.index(after: open)..<close]
        let parts = body.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return }
        func bytes(_ s: String) -> Int64? {
            let units: [(String, Int64)] = [("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10), ("B", 1)]
            for (suffix, mult) in units where s.hasSuffix(suffix) {
                guard let v = Double(s.dropLast(suffix.count)) else { return nil }
                return Int64(v * Double(mult))
            }
            return Int64(s)
        }
        guard let done = bytes(parts[0]) else { return }
        var total: Int64 = 0
        if parts[1].contains("/") {
            let seg = parts[1].split(separator: "/").last.map(String.init) ?? ""
            let num = seg.prefix { $0.isNumber || $0 == "." || $0 == "%" }
            let trimmed = num.trimmingCharacters(in: CharacterSet(charactersIn: "%"))
            if !trimmed.isEmpty, let t = bytes(trimmed + "B") {
                total = t
            }
        }
        progressHandler?(gid, done, total)
    }

    // MARK: - 控制

    func pause(gid: String) {
        lock.lock()
        let p = processes.removeValue(forKey: gid)
        lock.unlock()
        p?.terminate()
    }

    func cancel(gid: String) {
        pause(gid: gid)
    }
}

enum EngineError: LocalizedError {
    case binaryNotFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "未找到 aria2c 可执行文件（请安装：brew install aria2）"
        case .failed(let msg): return msg
        }
    }
}

/// 简单的进程执行工具（供 scutil 代理探测）
extension Process {
    static func runAndRead(_ path: String, args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
