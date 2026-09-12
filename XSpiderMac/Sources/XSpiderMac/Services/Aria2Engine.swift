import Foundation

/// aria2c 进程引擎：每个任务启动一个 aria2c 子进程（多连接分块 + 断点续传）。
/// 优点：业界成熟的多连接下载器，弱网/大文件速度与稳定性远超单连接 URLSession。
/// 生命周期由 DownloadStore 控制：pause → SIGSTOP 不可靠，改用 terminate + 重试机制；
/// 进度通过 aria2c 的 --summary-interval 输出解析（`[#id SIZE/FILE_SIZE(sec) AVG_SPEED]`）。
final class Aria2Engine: @unchecked Sendable {
    static let shared = Aria2Engine()

    private var processes: [String: Process] = [:]
    private let lock = NSLock()

    /// aria2c 可执行文件路径（bundle 内置优先，其次 homebrew）
    static func binaryURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/aria2c"),
            URL(fileURLWithPath: "/opt/homebrew/bin/aria2c"),
            URL(fileURLWithPath: "/usr/local/bin/aria2c"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { binaryURL() != nil }

    /// 读取 macOS 系统代理（aria2c 是独立进程，不会自动继承系统代理）
    static func systemProxy() -> String? {
        guard let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        if let httpsEnable = dict["kCFNetworkProxiesHTTPSEnable"] as? Bool ?? (dict["kCFNetworkProxiesHTTPSEnable"] as? Int).map({ $0 != 0 }), httpsEnable,
           let host = dict["kCFNetworkProxiesHTTPSProxy"] as? String,
           let port = dict["kCFNetworkProxiesHTTPSPort"] as? Int {
            return "http://\(host):\(port)"
        }
        if let httpEnable = dict["kCFNetworkProxiesHTTPEnable"] as? Bool ?? (dict["kCFNetworkProxiesHTTPEnable"] as? Int).map({ $0 != 0 }), httpEnable,
           let host = dict["kCFNetworkProxiesHTTPProxy"] as? String,
           let port = dict["kCFNetworkProxiesHTTPPort"] as? Int {
            return "http://\(host):\(port)"
        }
        if let socksEnable = dict["kCFNetworkProxiesSOCKSEnable"] as? Bool ?? (dict["kCFNetworkProxiesSOCKSEnable"] as? Int).map({ $0 != 0 }), socksEnable,
           let host = dict["kCFNetworkProxiesSOCKSProxy"] as? String,
           let port = dict["kCFNetworkProxiesSOCKSPort"] as? Int {
            return "socks5://\(host):\(port)"
        }
        return nil
    }

    var progressHandler: ((String, Int64, Int64) -> Void)?
    var completionHandler: ((String, Result<URL, Error>) -> Void)?

    /// 启动 aria2c 下载
    /// - Parameters:
    ///   - gid: 任务 ID
    ///   - urlString: 下载 URL
    ///   - destDir: 目标目录
    ///   - fileName: 目标文件名
    ///   - proxy: 代理地址（可选，如 http://127.0.0.1:7897）
    ///   - connections: 单文件分块连接数（aria2 --split）
    func start(gid: String, urlString: String, destDir: String, fileName: String, proxy: String?, connections: Int = 8, minSplitSizeMB: Int = 1, fileAllocation: String = "none") {
        lock.lock()
        if processes[gid] != nil { lock.unlock(); return }
        lock.unlock()

        guard let binary = Self.binaryURL() else {
            completionHandler?(gid, .failure(EngineError.binaryNotFound))
            return
        }

        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        // aria2 会自动避免覆盖，先清掉同名文件（上层 sameFileSkip 已挡过一轮）
        let destPath = (destDir as NSString).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(atPath: destPath)

        let p = Process()
        p.executableURL = binary
        p.arguments = [
            urlString,
            "--dir=\(destDir)",
            "--out=\(fileName)",
            "--split=\(max(1, connections))",
            "--max-connection-per-server=\(max(1, connections))",
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
        // 每服务器连接上限是 aria2 硬顶（16），split 不应超过它
        let perServer = min(16, max(1, connections))
        if let idx = p.arguments?.firstIndex(of: "--max-connection-per-server=\(max(1, connections))") {
            p.arguments?[idx] = "--max-connection-per-server=\(perServer)"
        }
        // proxy 参数由调用方解析（系统代理/手动代理），aria2c 进程不继承系统代理
        if let proxy, !proxy.isEmpty {
            p.arguments?.append("--all-proxy=\(proxy)")
        }

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            // aria2 的进度行以 \r 分隔刷新（单行更新），按行 + \r 拆开解析
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
                let reason = "aria2c exit \(process.terminationStatus)"
                self?.completionHandler?(gid, .failure(EngineError.failed(reason)))
            }
        }

        do {
            try p.run()
            lock.lock()
            processes[gid] = p
            lock.unlock()
            AppLogger.info("aria2c 任务启动", category: "DL", [
                "gid": gid, "split": "\(connections)", "proxy": proxy ?? "none",
            ])
        } catch {
            completionHandler?(gid, .failure(EngineError.failed("aria2c 启动失败: \(error.localizedDescription)")))
        }
    }

    private func parseProgressLine(_ line: String, gid: String) {
        // 形如: [#a1b2c3 4.2MiB/12MiB(35%) 1.2MiB/sec]
        guard let open = line.firstIndex(of: "["),
              let close = line.lastIndex(of: "]") else { return }
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
            if !trimmed.isEmpty, let t = bytes(trimmed.isEmpty ? "0B" : trimmed + "B") {
                total = t
            }
        }
        progressHandler?(gid, done, total)
    }

    func pause(gid: String) {
        lock.lock()
        let p = processes.removeValue(forKey: gid)
        lock.unlock()
        p?.terminate()
    }

    func cancel(gid: String) {
        pause(gid: gid)
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
}
