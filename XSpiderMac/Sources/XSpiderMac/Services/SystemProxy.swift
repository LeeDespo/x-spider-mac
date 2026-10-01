import Foundation

/// 系统代理探测。
///
/// # 为什么需要它
///
/// 组件是**独立进程**，不继承 macOS 的系统代理设置——"跟随系统代理"这一档
/// 必须由外壳解析出具体 URL 再告诉它（`net.set_proxy`；`null` 是"明确关闭"，
/// 两者语义不同，见契约 §4.3）。
///
/// 这份实现从 `Aria2Engine` 搬出来（引擎本体已随下载迁移删除）：
/// 主路径走 CFNetwork，取不到时回退解析 `scutil --proxy` 文本——
/// 应用内偶发取不到 CFNetwork 的值，两条都试才稳。
enum SystemProxy {
    static func current() -> String? {
        if let viaCF = viaCFNetwork() { return viaCF }
        return viaScutil()
    }

    private static func viaCFNetwork() -> String? {
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

    private static func viaScutil() -> String? {
        guard let out = runAndRead("/usr/sbin/scutil", args: ["--proxy"])
                ?? runAndRead("/usr/bin/scutil", args: ["--proxy"]) else { return nil }
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

    private static func runAndRead(_ path: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
