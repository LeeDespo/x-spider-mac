import Foundation

/// xspider-core 组件（`xspiderd`）的**进程与 JSON-RPC 客户端**。
///
/// # 为什么是独立进程
///
/// 主形态是 sidecar：换组件 = 换一个二进制，应用**不需要重新构建**。
/// 本机 hardened runtime 打开时 `dlopen` 任何 dylib 都会被 library validation 拒
/// （`docs/03` §1 的实测），所以不做进程内形态。
///
/// # 组件放哪儿（这是"分开更新"的关键）
///
/// 查找顺序**外部目录优先**，App bundle 里那份只作兜底：
///
///   1. `~/Library/Application Support/moe.keli.xspider.mac/XSpiderCore/`
///   2. `~/Library/Application Support/XSpiderMac/XSpiderCore/`
///   3. `XSpiderMac.app/Contents/Resources/`（随包携带的兜底）
///   4. `PATH`
///
/// 目录里放两个文件即可：`xspiderd` 与 `aria2next`。更新组件的步骤见
/// `docs/07-API-REFERENCE.md` §2 —— **清隔离属性 + 重新签名两件都要做**，
/// 否则内核会以 137 静默杀掉它（没有输出，只有一行日志）。
///
/// # 纪律
///
/// - **只经契约说话**：这里只有 `POST /` 与 `X-XSpider-Token`，没有任何组件内部类型；
/// - **token 不回显**：它只出现在请求头里，绝不进日志；
/// - **崩溃自愈**：进程没了就下一次性重起（下载队列会从记录里恢复未完成任务）；
/// - **退出要优雅**：先 `system.shutdown`，超时才 kill（否则下载记录可能没落盘）。
final class XSpiderComponent: @unchecked Sendable {
    static let shared = XSpiderComponent()

    /// 组件目录名（外部目录 `<app support>/XSpiderCore/`）。
    static let componentDirectoryName = "XSpiderCore"

    /// 这个应用按哪个契约主版本写的。主版本不匹配就拒绝启动（`docs/CONTRACT.md` §6）。
    static let supportedContractMajor = "1"

    struct Info: Sendable {
        var transport: String
        var contractVersion: String
        var buildVersion: String
        var binaryPath: String
        var pid: Int32?
    }

    enum ComponentError: Error, LocalizedError {
        /// 组件错误包络里的 `code`（`unauthorized` / `rate_limited` / `parse`…）。
        case contract(code: String, message: String, endpoint: String?, retryAfterS: Int?, status: Int?)
        /// 连不上 / 起不来 / 超时。
        case transport(String)
        /// 找不到组件二进制。
        case notInstalled(String)
        /// 响应不是契约包络（版本不匹配，或者这不是我们的组件）。
        case shape(String)

        var errorDescription: String? {
            switch self {
            case let .contract(code, message, _, retryAfter, _):
                if let retryAfter { return "\(message)（\(code)，建议等 \(retryAfter) 秒）" }
                return message.isEmpty ? code : message
            case let .transport(message): return message
            case let .notInstalled(message): return message
            case let .shape(message): return "组件响应不符合契约：\(message)"
            }
        }

        /// 契约错误码；传输/形状问题返回 nil。**判断一律用它，不要看文案**。
        var code: String? {
            if case let .contract(code, _, _, _, _) = self { return code }
            return nil
        }

        /// 上游 HTTP 状态码（仅 `upstream` 有）。
        var status: Int? {
            if case let .contract(_, _, _, _, status) = self { return status }
            return nil
        }

        /// 传输层问题可以重试（契约错误重试只会更慢地失败）。
        var isTransport: Bool {
            if case .transport = self { return true }
            return false
        }
    }

    private let lock = NSLock()

    /// 所有状态读写都过这里：`NSLock.lock()/unlock()` 在 Swift 6 的 async 上下文里
    /// 是被标记为不可用的（跨 await 持锁必然出问题），作用域式的 `withLock` 可以。
    private func sync<T>(_ body: () -> T) -> T {
        lock.withLock(body)
    }

    private var process: Process?
    private var port: UInt16 = 0
    private var token = ""
    private var stdoutBuffer = Data()
    private var launch: Task<Info, Error>?
    private var info: Info?
    private var nextId = 0
    private var shuttingDown = false

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = [:]
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - 对外

    var isRunning: Bool {
        sync { process?.isRunning == true && info != nil }
    }

    var currentInfo: Info? {
        sync { info }
    }

    /// 起进程并完成握手（幂等：已经在跑就直接返回）。
    @discardableResult
    func ensureStarted() async throws -> Info {
        if let existing = sync({ process?.isRunning == true ? info : nil }) {
            return existing
        }
        if let inFlight = sync({ launch }) {
            return try await inFlight.value
        }
        let task = Task<Info, Error> { [weak self] in
            guard let self else { throw ComponentError.transport("组件对象已释放") }
            return try await self.launchProcess()
        }
        sync { launch = task }

        defer { sync { launch = nil } }
        return try await task.value
    }

    /// 调一个契约 method。**参数与返回值就是契约里的 JSON**，没有中间类型。
    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        _ = try await ensureStarted()
        let (currentPort, currentToken) = sync { (port, token) }
        return try await performCall(method, params, port: currentPort, token: currentToken)
    }

    /// 优雅关停：先 `system.shutdown`，5 秒没退再 kill。**退出时一定要调**。
    func shutdown() async {
        let (proc, currentPort, currentToken): (Process?, UInt16, String) = sync {
            shuttingDown = true
            return (process, port, token)
        }

        guard let proc, proc.isRunning else { return }

        // 优雅路径：让组件把下载记录与断点落盘，并结束它自己的子进程（aria2）
        if currentPort != 0 {
            _ = try? await performCall("system.shutdown", [:], port: currentPort, token: currentToken)
        }
        for _ in 0..<50 {
            if !proc.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if proc.isRunning {
            AppLogger.info("组件未在 5 秒内退出，强制结束", category: "CORE",
                           ["pid": String(proc.processIdentifier)])
            proc.terminate()
        }
        clearProcessState()
    }

    /// 手动重起（设置里改代理/路径后用，或者自检用）。
    func restart() async throws -> Info {
        await shutdown()
        sync { shuttingDown = false }
        return try await ensureStarted()
    }

    // MARK: - 进程

    /// 组件二进制的查找路径（**外部目录优先**，bundle 只作兜底）。
    static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let support {
            if let bundleID = Bundle.main.bundleIdentifier {
                dirs.append(support.appendingPathComponent(bundleID, isDirectory: true)
                    .appendingPathComponent(componentDirectoryName, isDirectory: true))
            }
            dirs.append(support.appendingPathComponent("XSpiderMac", isDirectory: true)
                .appendingPathComponent(componentDirectoryName, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources)
        }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            dirs.append(exe)
        }
        return dirs
    }

    /// 找一个可执行文件：外部目录 → bundle → PATH。
    static func locate(_ name: String, extra: [URL] = []) -> URL? {
        let fm = FileManager.default
        for dir in extra + searchDirectories() {
            let candidate = dir.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func launchProcess() async throws -> Info {
        guard let binary = Self.locate("xspiderd") else {
            throw ComponentError.notInstalled("""
                找不到 xspiderd。把组件放进下面任一个目录即可（两个文件一起放）：
                  ~/Library/Application Support/\(Bundle.main.bundleIdentifier ?? "moe.keli.xspider.mac")/\(Self.componentDirectoryName)/
                需要的文件：xspiderd、aria2next
                放好后**两件都要做**（否则内核会静默杀掉它，退出码 137、没有任何输出）：
                  xattr -cr "<目录>"
                  codesign --force --sign - "<目录>"/xspiderd "<目录>"/aria2next
                """)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--port", "0"]
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        // 下载记录与单实例锁：放在应用数据目录里，跟应用数据一起清理
        env["XSPIDER_STATE_DIR"] = AppDirectories.supportRoot
            .appendingPathComponent("component-state", isDirectory: true).path
        // 组件自己拉起 aria2 时用的二进制：优先组件目录里那个（和 xspiderd 放一起）
        if let aria2 = Self.locate("aria2next", extra: [binary.deletingLastPathComponent()]) {
            env["XSPIDER_ARIA2_PATH"] = aria2.path
        }
        // 组件日志走 stderr，级别交给应用控制（默认 warn，排障时用 info）
        env["XSPIDER_LOG"] = env["XSPIDER_LOG"] ?? "warn"
        proc.environment = env

        sync { stdoutBuffer = Data() }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.sync { self.stdoutBuffer.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.isEmpty {
                AppLogger.info("组件: \(line)", category: "CORE")
            }
        }
        proc.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let wasShuttingDown: Bool = self.sync {
                let flag = self.shuttingDown
                self.process = nil
                self.info = nil
                self.port = 0
                self.token = ""
                return flag
            }
            if !wasShuttingDown {
                AppLogger.info("组件进程退出", category: "CORE", [
                    "status": String(finished.terminationStatus),
                    "reason": String(finished.terminationReason.rawValue),
                ])
            }
        }

        do {
            try proc.run()
        } catch {
            throw ComponentError.transport("起不来组件（\(binary.path)）：\(error.localizedDescription)")
        }

        let ready: Ready
        do {
            ready = try await waitForReadyLine(binary: binary, process: proc)
        } catch {
            // 没握上手就别留一个半死的进程在后台
            if proc.isRunning { proc.terminate() }
            throw error
        }
        sync {
            process = proc
            port = ready.port
            token = ready.token
        }

        // 握手：形态 + 契约版本（契约 §6：主版本不匹配就拒绝启动，不要降级成"部分可用"）
        let version = try await performCall("system.version", [:], port: ready.port, token: ready.token)
        let transport = version[string: "transport"] ?? "?"
        let contract = version[string: "contract_version"] ?? "?"
        let build = version[string: "build_version"] ?? "?"
        guard contract.split(separator: ".").first.map(String.init) == Self.supportedContractMajor else {
            proc.terminate()
            clearProcessState()
            throw ComponentError.transport(
                "组件契约版本 \(contract) 与本应用要求的 \(Self.supportedContractMajor).x 不匹配：请更新组件或应用")
        }

        let started = Info(transport: transport, contractVersion: contract,
                           buildVersion: build, binaryPath: binary.path,
                           pid: proc.processIdentifier)
        sync {
            info = started
            shuttingDown = false
        }

        AppLogger.info("组件已就绪", category: "CORE", [
            "contract": contract, "build": build, "transport": transport,
            "pid": String(started.pid ?? 0),
            // 路径要记：排查"改动没生效"时，先确认加载的是哪一份组件
            "path": binary.path,
        ])
        return started
    }

    private struct Ready {
        var port: UInt16
        var token: String
    }

    /// 读 stdout 的 `ready {"port":N,"token":"…","version":"…"}` 行（契约 §2.2）。
    private func waitForReadyLine(binary: URL, process proc: Process) async throws -> Ready {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let text = sync { String(data: stdoutBuffer, encoding: .utf8) ?? "" }
            if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("ready ") }) {
                let payload = line.dropFirst("ready ".count)
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let port = (json["port"] as? NSNumber)?.uint16Value,
                      let token = json["token"] as? String else {
                    throw ComponentError.shape("ready 行不是合法 JSON：\(payload)")
                }
                return Ready(port: port, token: token)
            }
            // 进程起来了却一直不打印 ready：多半是没签名/被隔离（SIGKILL 137）
            if !proc.isRunning {
                throw ComponentError.transport("""
                    组件没有打印 ready 行就退出了。最常见的原因：
                    文件没签名或被隔离（退出码 137、无输出）。依次执行：
                      xattr -cr "<组件目录>"
                      codesign --force --sign - "<组件目录>"/xspiderd "<组件目录>"/aria2next
                    组件路径：\(binary.path)
                    """)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ComponentError.transport("15 秒内没有收到组件的 ready 行（\(binary.path)）")
    }

    private func clearProcessState() {
        sync {
            process = nil
            info = nil
            port = 0
            token = ""
            stdoutBuffer = Data()
        }
    }

    // MARK: - JSON-RPC

    private func performCall(_ method: String, _ params: [String: JSONValue],
                             port: UInt16, token: String) async throws -> [String: JSONValue] {
        let id: Int = sync {
            nextId += 1
            return nextId
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // token 只出现在请求头里：**绝不进日志**
        request.setValue(token, forHTTPHeaderField: "X-XSpider-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": id, "method": method,
            "params": params.mapValues(\.anyValue),
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ComponentError.transport("调用 \(method) 失败：\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw ComponentError.transport("组件拒绝了本地 token（401）")
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? "<非 UTF-8>"
            throw ComponentError.shape("\(method) 的响应不是 JSON：\(text.prefix(200))")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw ComponentError.contract(
                code: error["code"] as? String ?? "internal",
                message: error["message"] as? String ?? "",
                endpoint: error["endpoint"] as? String,
                retryAfterS: (error["retry_after_s"] as? NSNumber)?.intValue,
                status: (error["status"] as? NSNumber)?.intValue)
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw ComponentError.shape("\(method) 既没有 result 也没有 error")
        }
        return JSONValue.from(result).asObject ?? [:]
    }
}
