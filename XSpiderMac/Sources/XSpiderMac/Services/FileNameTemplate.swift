import Foundation

/// 上游 constants/file-name-template.ts + utils/file-name-template.ts + utils/unicode.ts 的完整移植。
///
/// 变量语法：`%VARIABLE%` 或带参数 `%VARIABLE,k=v,k2=v2%`（参数大小写敏感 key，值任意）。
/// 每个替换值经 unicodeFilenamify：保留字符不动；保留字符 `[<>:"/\\|?*\\u0000-\\u001F]` 替换为 `!`；
/// Windows 保留名（con/prn/aux/nul/com1-9/lpt1-9）尾部加 `!`。
enum FileNameTemplate {

    struct VariableInfo: Sendable {
        let name: String
        let desc: String
        let params: [ParamInfo]
        let replacer: @Sendable (FileNameTemplateData, [String: String]) -> String
    }

    struct ParamInfo: Sendable {
        let name: String
        let desc: String
        let defaultValue: String
    }

    /// 上游 13 个变量的完整定义（顺序与上游 REPLACER_MAP 一致）
    static let variables: [VariableInfo] = {
        [
            VariableInfo(name: "POST_ID", desc: "推文 ID", params: []) { data, _ in data.post.id },
        VariableInfo(name: "POST_TIME", desc: "推文发布日期", params: [
            ParamInfo(name: "d", desc: "仅日期（0 或 1）", defaultValue: "0"),
        ]) { data, params in
            guard let createdAt = data.post.createdAt else { return "未知日期" }
            let dateOnly = params["d"] == "1"
            return createdAt.formatted(fileNameFormat: dateOnly ? "yyyy-MM-dd" : "yyyy-MM-dd HH-mm-ss")
        },
        VariableInfo(name: "USER_ID", desc: "用户 ID", params: []) { data, _ in data.post.user.id },
        VariableInfo(name: "USER_NAME", desc: "用户昵称", params: []) { data, _ in data.post.user.name },
        VariableInfo(name: "USER_SCREEN_NAME", desc: "用户名", params: []) { data, _ in data.post.user.screenName },
        VariableInfo(name: "MEDIA_ID", desc: "资源 ID", params: []) { data, _ in data.media.id ?? "" },
        VariableInfo(name: "MEDIA_WIDTH", desc: "资源宽度", params: []) { data, _ in data.media.width.map(String.init) ?? "" },
        VariableInfo(name: "MEDIA_HEIGHT", desc: "资源高度", params: []) { data, _ in data.media.height.map(String.init) ?? "" },
        VariableInfo(name: "MEDIA_INDEX", desc: "资源索引", params: []) { data, _ in
            let index = data.post.medias?.firstIndex(where: { $0.id == data.media.id }) ?? -1
            return String(index + 1)
        },
        VariableInfo(name: "CONTENT", desc: "推文内容", params: [
            ParamInfo(name: "t", desc: "截断长度", defaultValue: "16"),
        ]) { data, params in
            let paramTrim = Int(params["t"] ?? "")
            let trimLen = paramTrim ?? 32
            guard let fullText = data.post.fullText else { return "" }
            return String(fullText.prefix(trimLen))
        },
        VariableInfo(name: "MEDIA_TYPE", desc: "媒体类型", params: []) { data, _ in data.media.type.rawValue },
        VariableInfo(name: "EXT", desc: "扩展名", params: []) { data, _ in
            guard let url = downloadURL(for: data.media) else { return "" }
            let path = url.split(separator: "?").first ?? Substring(url)
            let ext = path.split(separator: ".").last.map { "." + $0 } ?? ""
            return String(ext)
        },
        VariableInfo(name: "TAGS", desc: "推文标签", params: []) { data, _ in
            (data.post.tags ?? []).joined(separator: ",")
        },
        ]
    }()

    /// 完整解析：%VAR% 与 %VAR,k=v% 两种形式，大小写不敏感变量名（上游 regex 'gi'）
    static func resolve(template: String, data: FileNameTemplateData) -> String {
        var result = template
        for variable in variables {
            let pattern = "%\(variable.name)((?:,[a-z]=.+?)+)?%"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }

            var replaced = result
            let nsRange = NSRange(replaced.startIndex..., in: replaced)
            regex.enumerateMatches(in: replaced, options: [], range: nsRange) { match, _, _ in
                guard let match else { return }
                let fullRange = Range(match.range, in: replaced)!
                let paramsString: String?
                if match.range(at: 1).location != NSNotFound, let r = Range(match.range(at: 1), in: replaced) {
                    paramsString = String(replaced[r])
                } else {
                    paramsString = nil
                }

                var params: [String: String] = [:]
                if let paramsString {
                    // 去掉开头逗号，按逗号切分，每组 k=v
                    let body = paramsString.dropFirst()
                    for pair in body.split(separator: ",") {
                        let kv = pair.split(separator: "=", maxSplits: 1)
                        if kv.count == 2 {
                            params[String(kv[0])] = String(kv[1])
                        }
                    }
                }

                let raw = variable.replacer(data, params)
                let safe = UnicodeFilename.filenamify(raw)
                replaced.replaceSubrange(fullRange, with: safe)
            }
            result = replaced
        }
        return result
    }

    /// 上游变量列表（设置页 VariablePicker 用）
    static var variableDescriptions: [(name: String, desc: String, params: [ParamInfo])] {
        variables.map { ($0.name, $0.desc, $0.params) }
    }
}

struct FileNameTemplateData: Sendable {
    let post: TwitterPost
    let media: TwitterMedia
}

// MARK: - 下载 URL 解析（上游 twitter/utils.ts getDownloadUrl）

func downloadURL(for media: TwitterMedia) -> String? {
    switch media.type {
    case .photo:
        guard let urlString = media.url, var url = URL(string: urlString) else { return nil }
        url.append(queryItems: [URLQueryItem(name: "name", value: "orig")])
        return url.absoluteString
    case .video:
        let variants = media.videoInfo?.variants ?? []
        let best = variants
            .filter { $0.bitrate != nil }
            .sorted { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            .last
        return best?.url
    case .gif:
        return media.videoInfo?.url
    }
}

// MARK: - unicode 工具（上游 utils/unicode.ts）

enum UnicodeFilename {
    private static let filenameReservedRegex = try! NSRegularExpression(pattern: #"[<>:"/\\|?*\u{0000}-\u{001F}]"# as String)
    private static let windowsReservedNameRegex = try! NSRegularExpression(pattern: #"^(con|prn|aux|nul|com\d|lpt\d)$"#, options: [.caseInsensitive])

    private static let reservedCharacters = Set<Character>(arrayLiteral: "<", ">", ":", "\"", "/", "\\", "|", "?", "*")

    static func filenamify(_ string: String) -> String {
        if isWindowsReservedName(string) {
            return string + "!"
        }
        var result = ""
        for scalar in string.unicodeScalars {
            if isReservedCharacter(scalar) {
                result.append("!")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func isReservedCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value <= 0x1F { return true }  // 控制字符
        return reservedCharacters.contains(Character(scalar))
    }

    private static func isWindowsReservedName(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return windowsReservedNameRegex.firstMatch(in: string, options: [], range: range) != nil
    }
}

extension Date {
    func formatted(fileNameFormat format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: self)
    }
}
