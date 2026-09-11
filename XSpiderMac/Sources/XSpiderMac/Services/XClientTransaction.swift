import Foundation
import CryptoKit

/// X Client Transaction ID 生成器（x-client-transaction-id 头）。
/// X 于 2025 年起对 /i/api/ 强制校验此头；缺它 → 401 code 89。
/// 算法移植自 twscrape/xclid.py（源自 iSarabjitDhiman/XClientTransaction，MIT）。
/// 流程：
///   1. 抓登录态页面 https://x.com/<user>
///   2. 提取 <meta name="twitter-site-verification"> → base64 解码 → vkBytes（48 字节）
///   3. 扫描 bundle 脚本找到签名文件（ondemand.s*.js / sign.o-*.js）→ 提取动画索引 animIdx
///   4. 页面内 4 个 <svg id="loading-x-anim-N"> 的第 2 条 <path d> → 动画帧数据（16 行）
///   5. vkBytes[animIdx[0]]%16 选帧 + frameTime 计算 → cubic 插值 → animKey（hex 串）
///   6. 每请求: payload = vkBytes + ts(4B) + SHA256("METHOD!path!ts!obfiowerehiring!animKey")[0..16] + 3
///      → XOR 混淆（首字节随机 0..255）→ base64 去填充
extension String {
    /// 整串匹配正则（等价 Python re.fullmatch）
    func fullRange(of pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.firstMatch(in: self, range: range)?.range == range
    }
}

actor XClientTransaction {
    static let shared = XClientTransaction()

    // MARK: - 状态

    private var vkBytes: [UInt8] = []
    private var animKey: String = ""
    private var loadedAt: Date?

    /// twscrape/account.py TOKEN（X 轮换后的有效 Bearer；上游 2024 年硬编码的已失效）
    static let bearer = "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZzS4fnriEAGWWjCpTnA"

    private var client: NetworkClient

    init() {
        self.client = NetworkClient()
    }

    func updateClient(_ client: NetworkClient) {
        self.client = client
    }

    var isLoaded: Bool {
        // vk 有效期较长，缓存 1 小时
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 3600, !vkBytes.isEmpty {
            return true
        }
        return false
    }

    /// 加载密钥（登录态页面 + 签名脚本）。在 cookie 变更或首次调用时执行。
    func loadKeys(cookieString: String) async throws {
        let headers = [
            "User-Agent": TwitterAPI.userAgent,
            "Cookie": cookieString,
        ]
        // 1. 登录态页面（xclid 用 /tesla；任何用户页都行，关键是登录态渲染）
        let page = try await client.request(
            url: URL(string: "https://x.com/tesla")!,
            headers: headers
        )
        let html = page.text()

        // 2. 验证 key
        guard let metaMatch = firstMatch(pattern: #"<meta[^>]*name="twitter-site-verification"[^>]*content="([^"]*)""#, in: html),
              let vkData = Data(base64Encoded: metaMatch) else {
            throw XClIdError.parseError("verification key not found")
        }
        self.vkBytes = Array(vkData)
        guard vkBytes.count >= 6 else {
            throw XClIdError.parseError("verification key too short")
        }

        // 3. 动画帧数据（页面内 4 个 svg 的第 2 条 path）
        let animArr = try parseAnimArr(html: html, vkBytes: vkBytes)
        guard !animArr.isEmpty else {
            throw XClIdError.parseError("animation data not found")
        }

        // 4. 动画索引（需下载签名脚本解析）
        let animIdx = try await parseAnimIdx(html: html, headers: headers)

        // 5. animKey
        self.animKey = try calcAnimKey(animIdx: animIdx, animArr: animArr, vkBytes: vkBytes)
        self.loadedAt = Date()
        AppLogger.info("XClId 密钥已加载", category: "NET", [
            "vkLen": "\(vkBytes.count)", "animKeyLen": "\(animKey.count)"
        ])
    }

    /// 为单个请求生成 txid。method 大写，path 为 URL path（含 query 前）。
    func transactionId(method: String, path: String) -> String? {
        guard !vkBytes.isEmpty, !animKey.isEmpty else { return nil }
        return Self.calc(method: method, path: path, vkBytes: vkBytes, animKey: animKey)
    }

    // MARK: - 计算核心（静态纯函数，可测试）

    static func calc(method: String, path: String, vkBytes: [UInt8], animKey: String) -> String {
        let ts = Int64((Date().timeIntervalSince1970 * 1000 - 1_682_924_400 * 1000) / 1000)
        let tsBytes: [UInt8] = [
            UInt8((ts >> 0) & 0xFF), UInt8((ts >> 8) & 0xFF),
            UInt8((ts >> 16) & 0xFF), UInt8((ts >> 24) & 0xFF),
        ]
        let payload = "\(method.uppercased())!\(path)!\(ts)obfiowerehiring\(animKey)"
        let digest = Array(SHA256.hash(data: Data(payload.utf8))).prefix(16)
        var bytes = vkBytes + tsBytes + Array(digest) + [3]
        let num = UInt8.random(in: 0...255)
        bytes = [num] + bytes.map { $0 ^ num }
        let b64 = Data(bytes).base64EncodedString()
        // 去 padding（xclid: .strip("=")）
        if let eqIndex = b64.firstIndex(of: "=") {
            return String(b64[b64.startIndex..<eqIndex])
        }
        return b64
    }

    // MARK: - HTML 解析

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// xclid.parse_anim_arr：4 个 loading-x-anim svg 的 g:first-child path:nth-child(2) 的 d 属性
    /// d 形如 "M 10,30 C 254,52 75,150 35,70 h 225 s ..."，去掉前 9 字符按 C 切分，数字解析为帧行
    private func parseAnimArr(html: String, vkBytes: [UInt8]) throws -> [[Double]] {
        var svgPaths: [String] = []
        // 每个 svg: <svg ... id="loading-x-anim-N" ...> ... </svg>，取 path 第 2 条的 d
        guard let svgRegex = try? NSRegularExpression(pattern: #"<svg[^>]*id="loading-x-anim[^"]*"[^>]*>(.*?)</svg>"#, options: [.dotMatchesLineSeparators]) else {
            throw XClIdError.parseError("svg regex failed")
        }
        let range = NSRange(html.startIndex..., in: html)
        svgRegex.enumerateMatches(in: html, range: range) { m, _, _ in
            guard let m, let inner = Range(m.range(at: 1), in: html) else { return }
            let innerHTML = String(html[inner])
            // path:nth-child(2)：第 2 条 path 的 d
            let dRegex = try? NSRegularExpression(pattern: #"<path[^>]*d="([^"]*)""#)
            let dRange = NSRange(innerHTML.startIndex..., in: innerHTML)
            var ds: [String] = []
            dRegex?.enumerateMatches(in: innerHTML, range: dRange) { dm, _, _ in
                guard let dm, let dr = Range(dm.range(at: 1), in: innerHTML) else { return }
                ds.append(String(innerHTML[dr]))
            }
            if ds.count >= 2 { svgPaths.append(ds[1]) }
        }
        guard !svgPaths.isEmpty else { throw XClIdError.parseError("no anim paths") }

        let idx = Int(vkBytes[5]) % svgPaths.count
        let d = svgPaths[idx]
        let clean = String(d.dropFirst(9))
        let segments = clean.split(separator: "C")
        var rows: [[Double]] = []
        for seg in segments {
            let numStrings = extractNumbers(String(seg))
            rows.append(numStrings.compactMap(Double.init))
        }
        return rows
    }

    private func extractNumbers(_ s: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        var out: [String] = []
        regex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, let r = Range(m.range, in: s) else { return }
            out.append(String(s[r]))
        }
        return out
    }

    /// xclid.get_scripts_list：页面直链 + webpack hash/name map 重建 chunk URL
    private func getScriptsList(_ html: String) -> [String] {
        var urls: [String] = []
        for pattern in [#"https://[\w.-]+/x-web/[\w./-]+\.js"#, #"https://[\w.-]+/responsive-web/client-web/[\w./-]+\.js"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { m, _, _ in
                guard let m, let r = Range(m.range, in: html) else { return }
                urls.append(String(html[r]))
            }
        }
        // legacy webpack: main.js 链接 + hash/name map 重建
        if let m = firstMatch(pattern: #"/client-web/main\.([^.\"']+)\.js"#, in: html) {
            urls.append("https://abs.twimg.com/responsive-web/client-web/main.\(m)a.js")
        }
        // hash map {id:"hex7/16"}
        var hashMap: [String: String] = [:]
        if let regex = try? NSRegularExpression(pattern: #"(\d+):"([0-9a-f]{7}|[0-9a-f]{16})""#) {
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { m, _, _ in
                guard let m, m.numberOfRanges > 2,
                      let k = Range(m.range(at: 1), in: html),
                      let v = Range(m.range(at: 2), in: html) else { return }
                hashMap[String(html[k])] = String(html[v])
            }
        }
        // name map（非 hex 值）
        if let regex = try? NSRegularExpression(pattern: #"(\d+):"([^"]+)""#) {
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { m, _, _ in
                guard let m, m.numberOfRanges > 2,
                      let k = Range(m.range(at: 1), in: html),
                      let v = Range(m.range(at: 2), in: html) else { return }
                let value = String(html[v])
                if !value.fullRange(of: #"[0-9a-f]{7}|[0-9a-f]{16}"#) {
                    let chunkId = String(html[k])
                    let hash = hashMap[chunkId] ?? chunkId
                    urls.append("https://abs.twimg.com/responsive-web/client-web/\(value).\(hash)a.js")
                }
            }
        }
        // 去重保序
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// xclid.parse_anim_idx：扫描脚本找签名文件（ondemand.s*.js / sign.o-*.js）→ 提取索引
    private func parseAnimIdx(html: String, headers: [String: String]) async throws -> [Int] {
        var scripts = getScriptsList(html)
        let xWebScripts = scripts.filter { $0.contains("/x-web/") }
        if !xWebScripts.isEmpty {
            if xWebScripts.contains(where: { $0.contains("entry-client-logged-out") }) {
                throw XClIdError.accountError("Logged-out X web app")
            }
            scripts = xWebScripts
        }

        // 直接命中的 URL（Python 语义：direct = scripts 中能匹配 INDICES_FILE_RE 的【完整 URL】，
        // 不是匹配子串！xclid: url = direct[0]）
        let indicesFileRegex = try NSRegularExpression(pattern: #"(?:\.{0,2}/)?[\w./-]*?\b(?:ondemand\.s|sign\.o)[\w.-]*\.js"#)
        func hasIndicesRef(in text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            return indicesFileRegex.firstMatch(in: text, range: range) != nil
        }
        func matchIndices(in text: String) -> String? {
            let range = NSRange(text.startIndex..., in: text)
            guard let m = indicesFileRegex.firstMatch(in: text, range: range),
                  let r = Range(m.range, in: text) else { return nil }
            return String(text[r])
        }

        var indicesUrl: String?
        if let direct = scripts.first(where: { hasIndicesRef(in: $0) }) {
            // 用完整 URL（Python url = direct[0]）
            indicesUrl = direct
        } else {
            // 并发扫描 bundle chunk（并发 16，首个命中即止，与 xclid._find_indices_url 一致）
            indicesUrl = await withTaskGroup(of: (String, String?).self) { group in
                var iterator = scripts.makeIterator()
                var active = 0
                var hit: String?
                func addNext() {
                    guard active < 16, let url = iterator.next() else { return }
                    active += 1
                    group.addTask { [client, headers] in
                        let text = (try? await client.request(url: URL(string: url)!, headers: headers))?.text()
                        return (url, text)
                    }
                }
                for _ in 0..<16 { addNext() }
                while active > 0, hit == nil {
                    if let (url, text) = await group.next() {
                        active -= 1
                        if let text, let rel = matchIndices(in: text) {
                            hit = Self.urljoin(base: url, rel: rel)
                            break
                        }
                        addNext()
                    }
                }
                group.cancelAll()
                return hit
            }
        }
        guard let rawUrl = indicesUrl else {
            throw XClIdError.parseError("signing script not found (scanned \(scripts.count) scripts)")
        }

        let text = try await fetchScript(urlString: rawUrl, headers: headers)
        let items = extractIndices(from: text)
        guard !items.isEmpty else {
            throw XClIdError.parseError("signing indices not found")
        }
        return items
    }

    /// Python urljoin 的核心语义：rel 以 // 开头 → scheme 相对（继承 base 的 https:）；
    /// rel 以 / 开头 → 站点根相对；其余 → 相对 base 目录
    static func urljoin(base: String, rel: String) -> String {
        if rel.hasPrefix("http://") || rel.hasPrefix("https://") { return rel }
        if rel.hasPrefix("//") { return "https:" + rel }
        guard var comps = URLComponents(string: base) else { return rel }
        if rel.hasPrefix("/") {
            comps.path = rel
            return comps.string ?? rel
        }
        // 相对 base 所在目录（去掉最后一段）
        let basePath = comps.path
        let dirPath = String(basePath.dropLast((basePath as NSString).lastPathComponent.count))
        comps.path = dirPath + rel
        return comps.string ?? rel
    }

    private func fetchScript(urlString: String, headers: [String: String]) async throws -> String {
        let resp = try await client.request(url: URL(string: urlString)!, headers: headers)
        return resp.text()
    }

    /// INDICES_REGEX：(\w[\d{1,2}],16) 连续组，取每组第二个捕获（索引值）
    private func extractIndices(from text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"(\(\w{1}\[(\d{1,2})\],\s*16\))+"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var items: [Int] = []
        regex.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m, m.numberOfRanges > 2, let r = Range(m.range(at: 2), in: text) else { return }
            items.append(Int(text[r]) ?? 0)
        }
        return items
    }

    // MARK: - animKey 计算（xclid.cacl_anim_key）

    /// animKey = calcAnimKey(animArr[frameIdx], frameTime/4096)
    /// 注意：animArr 每行数据行数可能不同，frameIdx 越界时回退到 0（xclid 直接 IndexError）
    private func calcAnimKey(animIdx: [Int], animArr: [[Double]], vkBytes: [UInt8]) throws -> String {
        // frameTime = floor(prod(vkBytes[animIdx[i]] % 16 for i in 1..) / 10 + 0.5) * 10
        var frameTime = 1.0
        for x in animIdx.dropFirst() {
            guard x < vkBytes.count else { throw XClIdError.parseError("anim idx out of vk range") }
            frameTime *= Double(vkBytes[x] % 16)
        }
        frameTime = (frameTime / 10 + 0.5).rounded(.down)
        frameTime *= 10

        guard let first = animIdx.first, first < vkBytes.count else {
            throw XClIdError.parseError("anim idx out of vk range")
        }
        let frameIdx = Int(vkBytes[first] % 16)
        guard !animArr.isEmpty else { throw XClIdError.parseError("empty anim data") }
        let row = frameIdx < animArr.count ? animArr[frameIdx] : animArr[0]
        guard !row.isEmpty else { throw XClIdError.parseError("empty frame row") }
        let frameDur = frameTime / 4096.0
        return Self.calcAnimKeyString(frameRow: row, targetTime: frameDur)
    }

    /// 上游 cacl_anim_key 的静态版（供测试）
    static func calcAnimKeyString(frameRow: [Double], targetTime: Double) -> String {
        guard frameRow.count >= 7 else { return "" }
        let fromColor = [frameRow[0], frameRow[1], frameRow[2], 1.0]
        let toColor = [frameRow[3], frameRow[4], frameRow[5], 1.0]
        let fromRotation: [Double] = [0.0]
        let toRotation: [Double] = [solve(frameRow[6], minVal: 60.0, maxVal: 360.0, rounding: true)]

        let frames = Array(frameRow.dropFirst(7))
        let curves = frames.enumerated().map { i, x in
            solve(x, minVal: i % 2 == 0 ? 0.0 : -1.0, maxVal: 1.0, rounding: false)
        }
        let val = Cubic(curves: curves).getValue(time: targetTime)

        var color = interpolate(fromColor, toColor, val).map { min(255, max(0, $0)) }
        color = color.map { Double(round($0)) }
        let rotation = interpolate(fromRotation, toRotation, val)

        let matrix = rotationMatrix(rotation[0])
        var strArr = color.dropLast().map { String(Int($0), radix: 16) }
        for value in matrix {
            let rounded = (value * 100).rounded() / 100
            let absRounded = abs(rounded)
            let hex = floatToHex(absRounded)
            if hex.hasPrefix(".") {
                strArr.append("0" + hex.lowercased())
            } else if hex.isEmpty {
                strArr.append("0")
            } else {
                strArr.append(hex)
            }
        }
        strArr.append("0")
        strArr.append("0")
        let joined = strArr.joined()
        return joined.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
    }

    // MARK: - 数学工具（Cubic / interpolate / solve / floatToHex）

    struct Cubic {
        let curves: [Double]
        init(curves: [Double]) { self.curves = curves }

        func getValue(time: Double) -> Double {
            var startGradient: Double = 0, endGradient: Double = 0
            var start: Double = 0, mid: Double = 0
            var end: Double = 1

            if time <= 0 {
                if curves[0] > 0 { startGradient = curves[1] / curves[0] }
                else if curves[1] == 0, curves.count > 2, curves[2] > 0 { startGradient = curves[3] / curves[2] }
                return startGradient * time
            }
            if time >= 1 {
                if curves.count > 2, curves[2] < 1 { endGradient = (curves[3] - 1) / (curves[2] - 1) }
                else if curves.count > 2, curves[2] == 1, curves[0] < 1 { endGradient = (curves[1] - 1) / (curves[0] - 1) }
                return 1 + endGradient * (time - 1)
            }
            while start < end {
                mid = (start + end) / 2
                let xEst = Cubic.calculate(curves[0], curves[2], mid)
                if abs(time - xEst) < 0.00001 {
                    return Cubic.calculate(curves[1], curves[3], mid)
                }
                if xEst < time { start = mid } else { end = mid }
            }
            return Cubic.calculate(curves[1], curves[3], mid)
        }

        static func calculate(_ a: Double, _ b: Double, _ m: Double) -> Double {
            3.0 * a * (1 - m) * (1 - m) * m + 3.0 * b * (1 - m) * m * m + m * m * m
        }
    }

    static func interpolate(_ from: [Double], _ to: [Double], _ f: Double) -> [Double] {
        zip(from, to).map { a, b in a * (1 - f) + b * f }
    }

    static func solve(_ value: Double, minVal: Double, maxVal: Double, rounding: Bool) -> Double {
        let result = value * (maxVal - minVal) / 255 + minVal
        return rounding ? Double(floor(result)) : (result * 100).rounded() / 100
    }

    static func rotationMatrix(_ rotation: Double) -> [Double] {
        let rad = rotation * .pi / 180
        return [cos(rad), -sin(rad), sin(rad), cos(rad)]
    }

    static func floatToHex(_ x: Double) -> String {
        var result: [String] = []
        var quotient = Int(x)
        var fraction = x - Double(quotient)
        var value = x

        while quotient > 0 {
            quotient = Int(value / 16)
            let remainder = Int(value - Double(quotient) * 16)
            if remainder > 9 {
                result.insert(String(UnicodeScalar(55 + remainder)!), at: 0)
            } else {
                result.insert("\(remainder)", at: 0)
            }
            value = Double(quotient)
        }

        if fraction == 0 { return result.joined() }

        result.append(".")
        var frac = fraction
        var guardCount = 0
        while frac > 0 && guardCount < 10 {
            frac *= 16
            let integer = Int(frac)
            frac -= Double(integer)
            if integer > 9 {
                result.append(String(UnicodeScalar(55 + integer)!))
            } else {
                result.append("\(integer)")
            }
            guardCount += 1
        }
        return result.joined()
    }
}

enum XClIdError: LocalizedError {
    case parseError(String)
    case accountError(String)

    var errorDescription: String? {
        switch self {
        case .parseError(let m): return "XClId 解析失败: \(m)"
        case .accountError(let m): return "XClId 账号问题: \(m)"
        }
    }
}
