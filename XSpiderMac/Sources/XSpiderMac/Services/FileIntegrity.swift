import Foundation

/// 下载文件完整性校验（两个引擎共用的唯一成功判据）。
///
/// 为什么需要它：实测（2026-09-17）用仓库内置 aria2next 对一个不可达 URL 下载，
/// 失败后**留下了 0 字节文件**；而旧代码把"文件存在"当作下载成功（`Aria2Engine.swift:185`
/// 还额外放行了 exit 1），于是失败被标成完成、写入下载记录、永不重试 —— 这就是成批
/// 出现损坏/0 字节文件的根因。
///
/// 更关键的是：实测发现 exit 0 也可能配 0 字节文件，exit 1/2 亦同。**仅凭退出码无法
/// 区分成功与失败**，因此必须以文件内容为判据。
enum FileIntegrity {

    enum Failure: LocalizedError, Equatable {
        case missing
        case empty                       // 0 字节（最常见的失败残留）
        case truncated(expected: Int64, actual: Int64)  // 大小不符（下了一半）
        case htmlErrorPage               // CDN 返回错误页却给了 200
        case notAnImage                  // 图片魔数不匹配

        var errorDescription: String? {
            switch self {
            case .missing: return L("文件不存在")
            case .empty: return L("文件为空（0 字节），下载未成功")
            case .truncated(let e, let a):
                return L("文件不完整：应为 \(e) 字节，实际 \(a) 字节")
            case .htmlErrorPage: return L("下载内容不是媒体文件（疑似错误页）")
            case .notAnImage: return L("文件内容不是有效图片")
            }
        }
    }

    /// 校验下载结果是否可用。
    ///
    /// - Parameters:
    ///   - path: 目标文件路径
    ///   - expectedTotal: 期望字节数（0 或未知则跳过大小比对）
    ///   - type: 媒体类型（图片做魔数校验；视频容器多样故不校验魔数）
    /// - Returns: 实际字节数
    static func verify(path: String, expectedTotal: Int64, type: MediaType) -> Result<Int64, Failure> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .failure(.missing) }
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        guard size > 0 else { return .failure(.empty) }

        // 期望大小已知时必须完全相等（小文件与 CDN 压缩差异已由 type 分流规避）
        if expectedTotal > 0, size != expectedTotal {
            return .failure(.truncated(expected: expectedTotal, actual: size))
        }

        // 读文件头：挡住"CDN 返回 HTML/JSON 错误页却带 200"这类隐蔽损坏
        guard let head = readHead(path: path, count: 16) else {
            // 读不到文件头（权限/瞬时 IO 问题）不判失败，交给后续使用方决定
            return .success(size)
        }
        if looksLikeTextError(head) { return .failure(.htmlErrorPage) }
        if type == .photo, !hasKnownImageMagic(head) { return .failure(.notAnImage) }

        return .success(size)
    }

    private static func readHead(path: String, count: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    /// 错误页/JSON 特征：以 `<`（HTML/XML）或 `{`/`[`（JSON）开头
    private static func looksLikeTextError(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first == UInt8(ascii: "<") || first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    /// 常见图片魔数：JPEG / PNG / GIF / WebP / HEIC
    /// 各格式所需前缀长度不同（WebP/HEIC 需要 12 字节，JPEG/PNG/GIF 只需 4），
    /// 因此按需判界，不用统一的长度门槛。
    private static func hasKnownImageMagic(_ d: Data) -> Bool {
        let b = [UInt8](d)
        guard b.count >= 4 else { return false }
        // JPEG: FF D8 FF
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }
        // PNG: 89 50 4E 47
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }
        // GIF: "GIF8"
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return true }
        guard b.count >= 12 else { return false }
        // WebP: "RIFF"…"WEBP"
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }
        // HEIC/HEIF: "ftyp" + brand
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "heif", "mif1", "msf1"].contains(brand) { return true }
        }
        return false
    }
}
