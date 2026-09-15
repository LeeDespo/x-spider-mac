import Foundation

/// aria2c 进程引擎：每个任务启动一个 aria2c 子进程（多连接分块 + 断点续传）。
/// 优点：业界成熟的多连接下载器，弱网/大文件速度与稳定性远超单连接 URLSession。
/// 生命周期由 DownloadStore 控制；进度通过 --summary-interval 输出解析。
final class Aria2Engine: @unchecked Sendable {
    static let shared = Aria2Engine()

    private var processes: [String: Process] = [:]
    /// 每任务输出缓冲（aria2c summary 用 \r 覆盖刷新，需累积后正则提取）
    private var outputBuffers: [String: String] = [:]
    private let lock = NSLock()

    /// aria2Next 可执行文件路径（bundle 内置优先，其次 homebrew;不回退老 aria2c）
    static let binaryURL: URL? = {
        var candidates: [URL] = []
        for name in ["aria2next"] {
            candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)"))
            candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
            candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(name)"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// 当前二进制是否为 aria2Next（设置页显示连接状态子项用）
    static var isNext: Bool {
        guard let url = binaryURL else { return false }
        return url.lastPathComponent.lowercased().contains("next")
    }

    /// 代理身份验证凭证（DownloadStore 在引擎设置时注入；底层锁保护并发安全）
    private static let credLock = NSLock()
    private nonisolated(unsafe) static var _proxyCredential: (username: String, password: String)?
    static var proxyCredential: (username: String, password: String)? {
        get { credLock.lock(); defer { credLock.unlock() }; return _proxyCredential }
        set { credLock.lock(); _proxyCredential = newValue; credLock.unlock() }
    }

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
    /// 优雅暂停回调（aria2 exit 7）
    var pauseHandler: ((String) -> Void)?

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
        // 控制文件存在 = 上次优雅暂停 → 保留以便续传；否则清掉同名残留（避免 --continue 读到旧控制文件"假完成"）
        if !FileManager.default.fileExists(atPath: destPath + ".aria2") {
            try? FileManager.default.removeItem(atPath: destPath)
            try? FileManager.default.removeItem(atPath: destPath + ".aria2")
        }

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
            // aria2Next 显式代理认证参数
            if let cred = Self.proxyCredential, !cred.username.isEmpty {
                p.arguments?.append("--all-proxy-user=\(cred.username)")
            }
            if let cred = Self.proxyCredential, !cred.password.isEmpty {
                p.arguments?.append("--all-proxy-pass=\(cred.password)")
            }
        }

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // aria2c 的 summary 用 \r 覆盖刷新，不能按行 split——累积缓冲后用正则提取进度
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            self.lock.lock()
            var buf = self.outputBuffers[gid] ?? ""
            buf += text
            // 只保留尾部（进度行是覆盖式的，旧数据无意义），避免无限增长
            if buf.count > 8192 { buf = String(buf.suffix(4096)) }
            self.outputBuffers[gid] = buf
            self.lock.unlock()
            self.extractProgress(from: buf, gid: gid)
        }

        p.terminationHandler = { [weak self] process in
            self?.lock.lock()
            self?.processes.removeValue(forKey: gid)
            self?.outputBuffers.removeValue(forKey: gid)
            self?.lock.unlock()

            let status = process.terminationStatus
            // exit 1 常见于极小文件：还没输出 summary 就下完了。只要目标文件存在就按成功收尾
            if (status == 0 || status == 1) && FileManager.default.fileExists(atPath: destPath) {
                self?.completionHandler?(gid, .success(URL(fileURLWithPath: destPath)))
            } else if status == 7 {
                // aria2 exit 7 = 用户暂停（SIGINT 优雅退出,控制文件已保存）
                self?.pauseHandler?(gid)
            } else {
                self?.completionHandler?(gid, .failure(EngineError.failed("aria2c exit \(status)")))
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

    /// 重启内核：终止全部活跃 aria2Next 子进程并清空会话状态。
    /// 下载中的任务由 DownloadStore 的错误回调重排队；下次任务启动时自动拉起新内核。
    func restart() {
        lock.lock()
        let procs = Array(processes.values)
        processes.removeAll()
        outputBuffers.removeAll()
        lock.unlock()
        for p in procs {
            if p.isRunning {
                // 先 SIGINT(优雅暂停语义)兜底,600ms 后强制终止
                kill(p.processIdentifier, SIGINT)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                    if p.isRunning { p.terminate() }
                }
            }
        }
        AppLogger.info("aria2Next 内核已重启", category: "DL", ["procs": "\(procs.count)"])
    }

    // MARK: - 进度解析

    /// 从输出缓冲提取 aria2 进度（\r 覆盖式输出 → 正则匹配最后一个 `[#gid done/total(%) CN:x DL:speed]`）
    private func extractProgress(from text: String, gid: String) {
        // done/total 形如 640KiB/52MiB；GiB/MiB/KiB/B
        let regex = try? NSRegularExpression(pattern: #"\[#\w+ ([\d.]+)(GiB|MiB|KiB|B)/([\d.]+)(GiB|MiB|KiB|B)\("#)
        guard let regex else { return }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last, last.numberOfRanges >= 4 else { return }

        func bytes(_ value: String, _ unit: String) -> Int64 {
            let v = Double(value) ?? 0
            let mult: Double
            switch unit {
            case "GiB": mult = 1_073_741_824
            case "MiB": mult = 1_048_576
            case "KiB": mult = 1024
            default: mult = 1
            }
            return Int64(v * mult)
        }

        let done = bytes(ns.substring(with: last.range(at: 1)), ns.substring(with: last.range(at: 2)))
        let total = bytes(ns.substring(with: last.range(at: 3)), ns.substring(with: last.range(at: 4)))
        progressHandler?(gid, done, total)
    }

    // MARK: - 控制

    /// 暂停：发 SIGINT 让 aria2 优雅保存控制文件（SIGTERM 会留下混乱状态:进度归零+红字报错）
    func pause(gid: String) {
        lock.lock()
        let p = processes.removeValue(forKey: gid)
        lock.unlock()
        guard let p else { return }
        if let pid = p.isRunning ? p.processIdentifier : nil {
            kill(pid, SIGINT)
        }
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
