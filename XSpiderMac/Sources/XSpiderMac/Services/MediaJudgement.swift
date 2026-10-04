import Foundation

/// 媒体判定与命名的公共实现（契约 `MEDIA_RECORDS.md` §5.2 / §6.1）。
///
/// 这里只做两件纯函数的事，**不读设置、不碰网络**：
/// 1. **算文件名**：模板解析 + （可选）唯一标识后缀；
/// 2. **按文件名判定**：目标文件夹里该文件名是否存在。
///
/// 「按文件名」是三种判定依据里唯一不需要记录文件的一种；同步判定选「按文件名」时
/// 直接复用它（同一个实现），两条判定路径因此不可能漂移。
enum MediaJudgement {

    /// 组件留下的断点 / 临时文件后缀（`x-spider-download` 的 `part_path_for`：
    /// `<目标文件名>.part.<引擎标识>`；aria2Next 还会在自己的断点旁留一个 `.aria2` 控制文件）。
    ///
    /// 名字带引擎标识是组件刻意的设计（两个引擎的断点物理隔开，见组件
    /// `docs/02-X-DOMAIN-NOTES.md` §E3），外壳侧唯一的真相在这里——
    /// **凡是"按文件名扫媒体"的地方都必须跳过它们**。
    /// 它们与目标文件同目录、且名字里就带着媒体 id，被解析出来就等同于
    /// 把一个从没下完的媒体记成"已下载"（记录模式只信记录、不回查文件，错一次就永久错）。
    static let enginePartialSuffixes = [".part.http", ".part.aria2next",
                                        ".part.http.aria2", ".part.aria2next.aria2"]

    /// 是不是组件的断点 / 临时文件（不是媒体文件）。
    static func isEnginePartial(fileName: String) -> Bool {
        enginePartialSuffixes.contains { fileName.hasSuffix($0) }
    }

    /// 在扩展名前用 `[` `]` 包裹媒体 id：`2026-09-12 Tesla 2098843535730725124.jpg`
    /// → `2026-09-12 Tesla 2098843535730725124[2098843532463411200].jpg`。
    ///
    /// **为什么用方括号而不是下划线**：下划线在模板变量里到处都是
    /// （`%USER_SCREEN_NAME%` 允许 `_`），解析时只能靠"取最后一个数字段 + 位数窗口"去猜；
    /// 方括号把这件事从"猜"变成"结构"——分界符本身携带语义。
    /// 账号文件夹（`昵称-用户名[数字id]`）已经用同一套约定，于是整个系统只剩一个心智模型：
    /// **方括号里是数字 id**。
    ///
    /// 方括号在 macOS / Windows / Linux 的文件名里都合法，也在 `UnicodeFilename.filenamify`
    /// 的转义集之外——昵称、正文里的 `[` 会原样保留，所以解析取的是**最后一个**方括号组。
    ///
    /// - 媒体 id 为空 / 缺失 → 原样返回（此时它不唯一，调用方应由设置保证开关状态，
    ///   见 §6.2 的联动规则）。
    /// - 没有扩展名时追加在末尾（`name` → `name[<id>]`）。
    static func appendingUniqueId(_ fileName: String, mediaId: String?) -> String {
        guard let mediaId, !mediaId.isEmpty else { return fileName }
        let ns = fileName as NSString
        // 模板常在 %EXT% 前留一个空格（`… %POST_ID% %EXT%`），解析后 stem 以空格结尾；
        // 追加前把它去掉，否则会拼出 `… 2098843535730725124 [2098843532463411200].jpg`
        // （契约 §5.2 的例子没有这个空格）。**只在追加时**去尾空格，不改不用标识时的命名。
        let stem = ns.deletingPathExtension.trimmingCharacters(in: .whitespaces)
        let ext = ns.pathExtension
        let joined = "\(stem)[\(mediaId)]"
        return ext.isEmpty ? joined : "\(joined).\(ext)"
    }

    /// 按模板算最终文件名（唯一标识后缀由开关决定）。
    static func fileName(post: TwitterPost, media: TwitterMedia,
                         template: String, appendUniqueId: Bool) -> String {
        let raw = FileNameTemplate.resolve(template: template,
                                           data: FileNameTemplateData(post: post, media: media))
        return appendUniqueId ? appendingUniqueId(raw, mediaId: media.id) : raw
    }

    /// 按文件名判定：目标文件夹里该文件是否存在。
    ///
    /// 有意**只查文件系统**：这就是该判定的全部语义（改名 / 移动文件即视为未下载），
    /// 不要再叠加记录或下载历史，否则会重演"三种判据互相打架"的旧问题。
    static func isDownloaded(fileName: String, in dir: String) -> Bool {
        guard !fileName.isEmpty, !dir.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent(fileName))
    }

    /// 便捷版：算文件名 + 查存在（调用方（DownloadStore）两条判定路径共用）。
    static func isDownloaded(post: TwitterPost, media: TwitterMedia, template: String,
                             appendUniqueId: Bool, in dir: String) -> Bool {
        isDownloaded(
            fileName: fileName(post: post, media: media,
                               template: template, appendUniqueId: appendUniqueId),
            in: dir)
    }

    // MARK: - 落盘名（判据与落盘名必须一致）

    /// 最终落盘的文件名。
    ///
    /// 规则（契约 §5.2「不再自动追加序号，名字的唯一性由『追加唯一标识』开关负责」）：
    /// - **带唯一标识**（文件名里有 `_<媒体id>`）：原样返回，**不**做重名消解。
    ///   媒体 id 是资源级全局唯一标识，撞名只可能是同一个媒体本身；
    ///   此时再改成「 (2)」会让**判据与落盘名分叉**——判定查的是模板算出的那一个名字，
    ///   而文件落在 `… (2).jpg` 上，于是界面永远显示未下载、每点一次多一份副本
    ///   （隔离复现：三次点击得到 (2)/(3)/(4)，`hasDownloaded` 恒为 false）。
    /// - **不带唯一标识**（只可能出现在记录模式，判定不看文件名）：保留重名保护，
    ///   同名文件或同路径未完成任务占用时追加「 (n)」，n 从 2 起。
    ///
    /// - Parameter extraTaken: 文件系统之外的"已被占用"判断（调用方传"未完成任务表"）。
    static func landingFileName(_ fileName: String, hasUniqueId: Bool, dir: String,
                                extraTaken: (String) -> Bool = { _ in false }) -> String {
        guard !fileName.isEmpty, !dir.isEmpty else { return fileName }
        func taken(_ name: String) -> Bool {
            if FileManager.default.fileExists(
                atPath: (dir as NSString).appendingPathComponent(name)) { return true }
            return extraTaken(name)
        }
        guard !hasUniqueId, taken(fileName) else { return fileName }
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}
