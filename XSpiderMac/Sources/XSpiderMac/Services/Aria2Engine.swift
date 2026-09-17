import Foundation

/// aria2c 进程引擎。
///
/// **首选路径：常驻 aria2Next + JSON-RPC**（对齐上游 `src/utils/aria2.ts`）。
/// 任务通过 `aria2.addUri(url, {dir, out})` 下发——RPC 完全支持指定下载路径，
/// 进度用 `tellStatus` 结构化获取，暂停/恢复是引擎内部操作（不存在 kill 竞态）。
/// 端口由设置决定（固定 6801 / 随机空闲端口），并在本进程内做占用诊断。
///
/// **回退路径：每任务一个子进程**（RPC 启动失败时自动降级，保证仍能下载），
/// 进度靠解析 stdout summary，语义较弱但可用。
final class Aria2Engine: @unchecked Sendable {
    static let shared = Aria2Engine()

    /// 常驻 RPC 客户端
    let rpc = Aria2RPCClient()
    /// RPC 是否可用（首任务启动时确定；失败则后续走回退路径）
    private var rpcAvailable: Bool?
    private var rpcGids: Set<String> = []
    private var progressTasks: [String: Task<Void, Never>] = [:]
    /// 我们的 gid → aria2 RPC gid
    private var rpcGidMap: [String: String] = [:]

    // MARK: - 锁保护的同步状态访问
    // NSLock 不能直接在 async 上下文里 lock/unlock（Swift 6 检查），
    // 因此把状态变更收敛到这些**同步**小函数里。

    private func markRPCStarted(gid: String) {
        lock.lock(); defer { lock.unlock() }
        rpcAvailable = true
        rpcGids.insert(gid)
    }

    private func markRPCUnavailable(gid: String) {
        lock.lock(); defer { lock.unlock() }
        rpcAvailable = false
        rpcGids.remove(gid)
        rpcGidMap.removeValue(forKey: gid)
        progressTasks[gid]?.cancel()
        progressTasks.removeValue(forKey: gid)
    }

    private func bindRPCGid(_ gid: String, _ rpcGid: String) {
        lock.lock(); defer { lock.unlock() }
        rpcGidMap[gid] = rpcGid
    }

    private func registerProgressTask(_ gid: String, _ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        progressTasks[gid] = task
    }

    private func rpcGid(for gid: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return rpcGidMap[gid]
    }

    private func isRPCGid(_ gid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rpcGids.contains(gid)
    }

    private var processes: [String: Process] = [:]
    /// 每任务输出缓冲（aria2c summary 用 \r 覆盖刷新，需累积后正则提取）
    private var outputBuffers: [String: String] = [:]
    private let lock = NSLock()

    /// aria2Next 可执行文件路径（bundle 内置优先，其次 homebrew;不回退老 aria2c）
    static let binaryURL: URL? = {
        var candidates: [URL] = [
            // 内置:Contents/Resources/aria2next(随应用分发,自动签名)
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/aria2next"),
            // 开发时直接跑源码树
            URL(fileURLWithPath: "Resources/Binaries/aria2next"),
            // homebrew 安装
            URL(fileURLWithPath: "/opt/homebrew/bin/aria2next"),
            URL(fileURLWithPath: "/usr/local/bin/aria2next"),
        ]
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.insert(execURL.appendingPathComponent("aria2next"), at: 0)
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

    /// 下载请求的 User-Agent（RPC 选项与子进程参数共用）
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

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

    /// 启动 aria2c 下载。
    /// 优先走常驻 RPC 进程；RPC 不可用（启动失败/端口被占）时回退到每任务子进程。
    func start(gid: String, urlString: String, destDir: String, fileName: String, proxy: String?, connections: Int = 8, minSplitSizeMB: Int = 1, fileAllocation: String = "none") {
        lock.lock()
        if processes[gid] != nil || rpcGids.contains(gid) { lock.unlock(); return }
        lock.unlock()

        guard let binary = Self.binaryURL else {
            completionHandler?(gid, .failure(EngineError.binaryNotFound))
            return
        }

        // 先尝试常驻 RPC（设置里的端口策略在此生效）
        if rpcAvailable != false {
            Task { [weak self] in
                guard let self else { return }
                // 设置只在主线程读（SettingsStore 是 MainActor 隔离）
                let (preferredPort, randomPort) = await MainActor.run {
                    (SettingsStore.shared.settings.aria2Port,
                     SettingsStore.shared.settings.aria2PortMode == .random)
                }
                do {
                    try await self.rpc.start(
                        binary: binary,
                        preferredPort: preferredPort,
                        randomPort: randomPort
                    )
                    self.markRPCStarted(gid: gid)
                    try await self.startViaRPC(
                        gid: gid, urlString: urlString, destDir: destDir, fileName: fileName,
                        proxy: proxy, connections: connections,
                        minSplitSizeMB: minSplitSizeMB, fileAllocation: fileAllocation
                    )
                } catch {
                    // RPC 启动/下发失败 → 标记不可用并回退到子进程路径（本次任务立即重试一次）
                    AppLogger.warn("aria2 RPC 不可用,回退子进程模式", category: "DL", [
                        "gid": gid, "error": error.localizedDescription,
                    ])
                    self.markRPCUnavailable(gid: gid)
                    self.startViaSubprocess(
                        gid: gid, urlString: urlString, destDir: destDir, fileName: fileName,
                        proxy: proxy, connections: connections,
                        minSplitSizeMB: minSplitSizeMB, fileAllocation: fileAllocation
                    )
                }
            }
            return
        }

        startViaSubprocess(
            gid: gid, urlString: urlString, destDir: destDir, fileName: fileName,
            proxy: proxy, connections: connections,
            minSplitSizeMB: minSplitSizeMB, fileAllocation: fileAllocation
        )
    }

    /// RPC 方式下发任务并轮询进度
    private func startViaRPC(gid: String, urlString: String, destDir: String, fileName: String, proxy: String?, connections: Int, minSplitSizeMB: Int, fileAllocation: String) async throws {
        var options: [String: String] = [
            "split": "\(min(16, max(1, connections)))",
            "max-connection-per-server": "\(min(16, max(1, connections)))",
            "min-split-size": "\(max(1, minSplitSizeMB))M",
            "file-allocation": fileAllocation,
            "user-agent": Self.userAgent,
            "referer": "https://x.com/",
            "continue": "true",
            "auto-file-renaming": "false",
            "allow-overwrite": "true",
        ]
        if let proxy, !proxy.isEmpty {
            options["all-proxy"] = proxy
            if let cred = Self.proxyCredential, !cred.username.isEmpty {
                options["all-proxy-user"] = cred.username
                if !cred.password.isEmpty { options["all-proxy-pass"] = cred.password }
            }
        }
        // dir/out 通过 RPC 指定（与上游一致）
        let rpcGid = try await rpc.addURI(url: urlString, dir: destDir, out: fileName, options: options)
        bindRPCGid(gid, rpcGid)
        AppLogger.info("aria2 RPC 任务已下发", category: "DL", ["gid": gid, "rpcGid": rpcGid])
        startProgressPolling(gid: gid, rpcGid: rpcGid, destDir: destDir, fileName: fileName)
    }

    /// 1Hz 轮询 RPC 进度与终态（结构化字段，不再解析 stdout 文本）
    private func startProgressPolling(gid: String, rpcGid: String, destDir: String, fileName: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let status = try await self.rpc.tellStatus(gid: rpcGid)
                    if status.totalLength > 0 || status.completedLength > 0 {
                        self.progressHandler?(gid, status.completedLength, status.totalLength)
                    }
                    if status.isComplete {
                        self.finishRPC(gid: gid, rpcGid: rpcGid, result: .success(URL(fileURLWithPath: (destDir as NSString).appendingPathComponent(fileName))))
                        return
                    }
                    if status.isError {
                        let message = status.errorMessage.isEmpty ? "aria2 报告错误" : status.errorMessage
                        self.finishRPC(gid: gid, rpcGid: rpcGid, result: .failure(EngineError.failed(message)))
                        return
                    }
                    if status.isPausedOrRemoved {
                        self.finishRPC(gid: gid, rpcGid: rpcGid, result: nil) // 暂停走 pauseHandler
                        return
                    }
                } catch {
                    AppLogger.warn("aria2 进度轮询失败,停止轮询", category: "DL", [
                        "gid": gid, "error": error.localizedDescription,
                    ])
                    return
                }
            }
        }
        registerProgressTask(gid, task)
    }

    private func finishRPC(gid: String, rpcGid: String, result: Result<URL, Error>?) {
        lock.lock()
        rpcGids.remove(gid)
        rpcGidMap.removeValue(forKey: gid)
        progressTasks[gid]?.cancel()
        progressTasks.removeValue(forKey: gid)
        lock.unlock()
        guard let result else {
            pauseHandler?(gid)
            return
        }
        completionHandler?(gid, result)
    }

    /// 回退路径：每任务一个子进程（RPC 不可用时）
    private func startViaSubprocess(gid: String, urlString: String, destDir: String, fileName: String, proxy: String?, connections: Int, minSplitSizeMB: Int, fileAllocation: String) {
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
            "--user-agent=\(Self.userAgent)",
            "--referer=https://x.com/",
            "--auto-file-renaming=false",
            "--allow-overwrite=true",
            // 不读 ~/.aria2/aria2.conf：用户若装了其它 aria2 工具，其配置（RPC 端口、
            // 密钥、限速、默认目录）会悄悄污染我们的实例
            "--conf-path=/dev/null",
            "--no-conf",
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
            if status == 7 {
                // aria2 exit 7 = 用户暂停（SIGINT 优雅退出,控制文件已保存）
                self?.pauseHandler?(gid)
                return
            }
            // 重要：**不得**以"文件存在"作为成功判据。实测失败时 aria2 会留下 0 字节文件，
            // 且失败码不止一种（1=未知错误、2=超时），按码值白名单永远堵不住。
            // 这里只负责把"引擎退出"如实上报，成功与否由 DownloadStore 的完整性校验裁定。
            if status == 0 {
                self?.completionHandler?(gid, .success(URL(fileURLWithPath: destPath)))
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

    /// 暂停：RPC 任务走引擎内部暂停（真正的暂停，无 kill 竞态）；
    /// 子进程任务发 SIGINT 让 aria2 优雅保存控制文件。
    func pause(gid: String) {
        if isRPCGid(gid) {
            Task { [weak self] in await self?.pauseRPC(gid: gid) }
            return
        }
        lock.lock()
        let p = processes.removeValue(forKey: gid)
        lock.unlock()
        guard let p else { return }
        if let pid = p.isRunning ? p.processIdentifier : nil {
            kill(pid, SIGINT)
        }
    }

    /// 暂停 RPC 任务（引擎内部暂停，控制文件由 aria2 自行维护）
    private func pauseRPC(gid: String) async {
        guard let rpcGid = rpcGid(for: gid) else { return }
        do {
            try await rpc.pause(gid: rpcGid)
        } catch {
            AppLogger.warn("aria2 RPC 暂停失败", category: "DL", ["gid": gid, "error": error.localizedDescription])
        }
    }

    func cancel(gid: String) {
        lock.lock()
        let trackedRPCGid = rpcGidMap[gid]
        progressTasks[gid]?.cancel()
        progressTasks.removeValue(forKey: gid)
        rpcGids.remove(gid)
        rpcGidMap.removeValue(forKey: gid)
        let p = processes.removeValue(forKey: gid)
        lock.unlock()

        if let trackedRPCGid {
            Task { [rpc] in
                try? await rpc.remove(gid: trackedRPCGid)
            }
            return
        }
        if let p, p.isRunning { kill(p.processIdentifier, SIGINT) }
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
