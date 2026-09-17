import Foundation
import Darwin

/// aria2Next 常驻进程 + JSON-RPC 客户端（对齐上游 `src/utils/aria2.ts` 的做法）。
///
/// 为什么改常驻：旧的"每任务一个子进程"方案有三处硬伤——
/// 1. 进度靠正则解析 stdout（`\r` 覆盖式输出，脆弱且无法区分本次/上次）；
/// 2. 暂停靠发 SIGINT 后等进程自己保存控制文件，时序上无法确认已完整落盘
///    （这是"暂停/恢复后文件损坏"的窗口来源）；
/// 3. N 个任务 = N 个进程，各自重复读配置。
/// RPC 模型下 `aria2.pause/unpause` 是引擎内部真正的暂停，`tellStatus` 返回结构化进度。
///
/// 隔离措施（都必要）：
/// - `--conf-path=/dev/null` + `--no-conf`：不读 `~/.aria2/aria2.conf`，避免用户装的其它
///   aria2 工具把 RPC 端口/密钥/限速/默认目录污染进我们的实例；
/// - `--rpc-secret=<随机>`：即使别的程序连上端口也调不动；
/// - 端口可选固定（默认 6801）或随机（自动挑空闲端口），避开与其它 aria2 软件冲突。
actor Aria2RPCClient {
    enum RPCError: LocalizedError {
        case notStarted
        case launchFailed(String)
        case rpcFailed(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .notStarted: return "aria2Next 未启动"
            case .launchFailed(let m): return "aria2Next 启动失败：\(m)"
            case .rpcFailed(let m): return "aria2Next 调用失败：\(m)"
            case .timeout(let m): return "aria2Next 超时：\(m)"
            }
        }
    }

    private var process: Process?
    private var port: Int = 0
    private var secret: String = ""
    private var invokeId = 0
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    var isRunning: Bool { process?.isRunning == true }
    var listeningPort: Int { port }

    // MARK: - 启动 / 停止

    /// 启动常驻 aria2Next（幂等）。已有实例且端口一致则直接返回。
    /// - Parameters:
    ///   - binary: 可执行文件
    ///   - preferredPort: fixed 模式下的端口
    ///   - randomPort: true 时自动挑选空闲端口
    ///   - stateDir: 续传状态目录（见下方说明）
    func start(binary: URL, preferredPort: Int, randomPort: Bool, stateDir: String) async throws {
        if let process, process.isRunning, (!randomPort ? port == preferredPort : true) {
            return
        }
        await stop()

        let chosen = randomPort ? Self.findFreePort() : preferredPort
        guard chosen > 0 else { throw RPCError.launchFailed("找不到可用端口") }

        secret = UUID().uuidString
        let p = Process()
        p.executableURL = binary
        p.arguments = [
            "--enable-rpc",
            "--rpc-secret=\(secret)",
            "--rpc-listen-port=\(chosen)",
            "--rpc-listen-all=false",
            // 不读用户其它 aria2 工具的配置
            "--conf-path=/dev/null",
            "--no-conf",
            "--continue=true",
            "--auto-file-renaming=false",
            "--allow-overwrite=true",
            "--console-log-level=warn",
            // 续传状态目录：aria2Next **不再在下载目录旁生成 .aria2 控制文件**，
            // HTTP 续传状态改存 `state-dir/stream/state.db`（SQLite）。
            // 默认会落到 `~/Library/Application Support/aria2-next`，
            // 这里显式指到本应用的数据目录，便于随应用数据一起管理/清理。
            "--state-dir=\(stateDir)",
            // 关掉与 HTTP 下载无关的 BT/DHT 监听：
            // 默认会尝试 bind 6881，端口被占时每次下载刷十几行 error 日志
            "--enable-dht=false",
            "--enable-dht6=false",
            "--bt-enable-lpd=false",
            "--enable-peer-exchange=false",
            // App 退出时 aria2 自动收尾
            "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
        ]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        do {
            try p.run()
        } catch {
            throw RPCError.launchFailed(error.localizedDescription)
        }
        process = p
        port = chosen

        // 等待 RPC 就绪：轮询端口连通性（比解析 stdout 更可靠，且不依赖日志文案）
        let ready = await waitUntilReady(timeout: 12)
        guard ready else {
            await stop()
            throw RPCError.launchFailed("RPC 端口 \(chosen) 未在超时内就绪（可能被其它程序占用）")
        }
        AppLogger.info("aria2Next 常驻进程已就绪", category: "DL", [
            "port": "\(chosen)", "mode": randomPort ? "random" : "fixed",
        ])
    }

    func stop() async {
        guard let p = process else { return }
        process = nil
        port = 0
        if p.isRunning {
            // SIGINT 让 aria2 优雅保存会话控制文件
            kill(p.processIdentifier, SIGINT)
            try? await Task.sleep(nanoseconds: 600_000_000)
            if p.isRunning { p.terminate() }
        }
    }

    /// 端口连通性探测
    private func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.canConnect(port: port) { return true }
            if process?.isRunning == false { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    // MARK: - JSON-RPC

    /// 单次 RPC 调用（HTTP POST /jsonrpc）
    func invoke(_ method: String, _ params: [Any]) async throws -> Any {
        guard let process, process.isRunning, port > 0 else { throw RPCError.notStarted }
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "\(invokeId)",
            "method": method,
            // 首参固定为 token:<secret>（aria2 的鉴权约定）
            "params": ["token:\(secret)"] + params,
        ]
        invokeId += 1

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/jsonrpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RPCError.rpcFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCError.rpcFailed("响应不是 JSON")
        }
        if let error = json["error"] as? [String: Any] {
            throw RPCError.rpcFailed(error["message"] as? String ?? "未知错误")
        }
        return json["result"] as Any
    }

    /// 批量调用（system.multicall）：一次请求取回多个任务状态
    func multicall(_ calls: [(method: String, params: [Any])]) async throws -> [Any] {
        let encoded: [[String: Any]] = calls.map { call in
            ["methodName": call.method, "params": ["token:\(secret)"] + call.params]
        }
        let result = try await invoke("system.multicall", [encoded])
        return result as? [Any] ?? []
    }

    // MARK: - 任务操作

    /// 下发任务；返回 gid。**dir 与 out 通过 RPC 指定**（与上游一致）。
    func addURI(url: String, dir: String, out: String, options: [String: String]) async throws -> String {
        var opts: [String: Any] = ["dir": dir, "out": out]
        for (k, v) in options { opts[k] = v }
        let result = try await invoke("aria2.addUri", [[url], opts])
        guard let gid = result as? String else { throw RPCError.rpcFailed("addUri 未返回 gid") }
        return gid
    }

    /// 任务状态（Sendable 值类型：跨 actor 边界返回字典会触发 RegionIsolation 检查）
    struct TaskStatus: Sendable {
        var gid: String
        var state: String
        var completedLength: Int64
        var totalLength: Int64
        var errorMessage: String

        var isComplete: Bool { state == "complete" }
        var isError: Bool { state == "error" }
        var isPausedOrRemoved: Bool { state == "paused" || state == "removed" }
    }

    func tellStatus(gid: String) async throws -> TaskStatus {
        let result = try await invoke("aria2.tellStatus", [gid, ["gid", "status", "completedLength", "totalLength", "errorMessage"]])
        guard let dict = result as? [String: Any] else { throw RPCError.rpcFailed("tellStatus 返回格式异常") }
        return TaskStatus(
            gid: dict["gid"] as? String ?? gid,
            state: dict["status"] as? String ?? "",
            completedLength: Int64(dict["completedLength"] as? String ?? "0") ?? 0,
            totalLength: Int64(dict["totalLength"] as? String ?? "0") ?? 0,
            errorMessage: dict["errorMessage"] as? String ?? ""
        )
    }

    func pause(gid: String) async throws {
        _ = try await invoke("aria2.pause", [gid])
    }

    func unpause(gid: String) async throws {
        _ = try await invoke("aria2.unpause", [gid])
    }

    func remove(gid: String) async throws {
        _ = try await invoke("aria2.remove", [gid])
    }

    // MARK: - 端口工具

    /// 让系统分配一个空闲端口（bind 到 0 后读取实际端口，再立即释放）
    static func findFreePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                      // 由系统挑选
        addr.sin_addr.s_addr = INADDR_ANY
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { return 0 }
        var out = sockaddr_in()
        let got = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return 0 }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    /// 端口是否可连接（用于等待 RPC 就绪与占用检测）
    static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        // 非阻塞 + 短超时，避免探测本身卡住
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
