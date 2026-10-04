import Foundation

/// 账号文件夹命名（契约 `MEDIA_RECORDS.md` §5.1）。
///
/// 形态：`昵称-用户名[数字id]`，例：`Tesla-Tesla[13298072]`。
///
/// 为什么把数字 id 放进文件夹名：昵称与用户名都会被改，而且昵称不唯一；
/// 只有数字 id 是账号的稳定身份。记录文件（`.downloadedrecord.json` /
/// `.synced.json`）就落在账号文件夹里，所以"文件夹 ↔ 账号"的映射必须无歧义。
///
/// 与旧命名（`昵称-@用户名`）**不兼容**：旧文件夹不会被读取、迁移或改写。
enum AccountFolder {
    /// 数字 id 后缀：`[13298072]`（半角方括号，不含空格）。
    static func suffix(userId: String) -> String {
        "[\(userId)]"
    }

    /// 账号文件夹名：`昵称-用户名[数字id]`。
    ///
    /// 整体过一遍 `safePathComponent`：斜杠、反斜杠、控制字符转义为 `-`。
    /// 数字 id 非空时后缀一定保留（昵称/用户名为空也拼得出来，如 `-[1]`）。
    static func name(name: String, screenName: String, userId: String) -> String {
        var base = "\(name)-\(screenName)"
        if !userId.isEmpty { base += suffix(userId: userId) }
        return base.safePathComponent()
    }

    /// 从文件夹名解析账号数字 id：`…[13298072]` → `13298072`。
    ///
    /// **只看最后一个 `[…]`**：昵称本身可能含方括号（`a[1]-b[2]`），
    /// 而数字 id 后缀是拼接时最后加上的、且必定是纯数字。
    /// 解析失败（没有后缀 / 括号里不是数字）→ nil，调用方跳过该文件夹
    /// （旧命名的文件夹天然落到这里，这正是"不兼容旧命名"的实现方式）。
    ///
    /// **只认 ASCII 数字 0-9**：`Character.isNumber` 会把阿拉伯-印度数字
    /// （`x[١٢٣]`）、圈号（`x[①]`）、全角（`x[１２３]`）、分数（`x[½]`）
    /// 都判成"数字"，于是这些文件夹会被当成账号、记录写到一个不存在的账号 id 下
    /// （实测确认过）。账号 id 只可能是 X 的十进制数字串，多认只会造假。
    static func accountId(fromFolderName folderName: String) -> String? {
        guard folderName.hasSuffix("]"),
              let open = folderName.lastIndex(of: "[") else { return nil }
        let digits = folderName[folderName.index(after: open)..<folderName.index(before: folderName.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy(isASCIIDigit(_:)) else { return nil }
        return String(digits)
    }

    /// ASCII `0`-`9`（`isNumber` 的 Unicode 语义太宽，见 `accountId(fromFolderName:)`）。
    static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    // MARK: - 账号文件夹定位（同一 user id 永远指向同一个文件夹）

    /// 保存路径 → `[账号数字 id: 文件夹名]` 索引缓存。
    ///
    /// 为什么必须缓存：`DownloadStore.targetDir(for:)` 会在媒体网格里**每个格子**被调用
    /// （算目标目录 → 判定已下载），每次都去扫保存路径会成为明显的卡顿源。
    /// 缓存键是保存路径；保存路径变更 / 记录刷新
    /// （`DownloadStore.refreshDownloadedCaches()`）时还会整体失效一次。
    private static let folderIndex = FolderIndex()

    /// 目录索引缓存（`NSLock` 保护：判定在主线程，导入/重建可能从别的路径调用）。
    final class FolderIndex: @unchecked Sendable {
        private let lock = NSLock()
        private var bySaveDir: [String: [String: String]] = [:]

        /// 取某保存路径的索引；没有就按 `rebuild` 建一份并记住。
        func index(for saveDir: String, rebuild: () -> [String: String]) -> [String: String] {
            lock.lock()
            if let cached = bySaveDir[saveDir] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            let built = rebuild()
            lock.lock()
            bySaveDir[saveDir] = built
            lock.unlock()
            return built
        }

        /// 记下"这个 id 用这个名字"（新建文件夹时立即记住，下一次调用不必再扫盘）。
        func remember(userId: String, folderName: String, in saveDir: String) {
            lock.lock()
            bySaveDir[saveDir, default: [:]][userId] = folderName
            lock.unlock()
        }

        func invalidate() {
            lock.lock()
            bySaveDir.removeAll()
            lock.unlock()
        }
    }

    /// 账号文件夹名：**同一 user id 永远指向同一个文件夹**。
    ///
    /// 先在保存路径下按 `[数字id]` 找已有文件夹，找到了就用它的名字——用户改昵称 /
    /// 用户名后不会出现第二个文件夹、记录也不会写进一个新的空文件
    /// （那会让整个账号的已下载媒体被当成没下过，整库重下）。
    /// 找不到才用当前昵称 / 用户名新建。
    ///
    /// 目录扫描按保存路径缓存（见 `folderIndex`），判定路径上的高频调用不扫盘。
    /// 缓存里的条目若在磁盘上还不存在（这一轮刚算出来、下载还没落盘），
    /// 改名后用当前昵称重新算——目录一旦真的出现，缓存条目就有磁盘依据了。
    /// `userId` 为空时无从"按 id 找"，退回纯昵称命名（调用方见 `DownloadStore.targetDir`）。
    static func folderName(saveDir: String, name: String, screenName: String, userId: String) -> String {
        let fresh = Self.name(name: name, screenName: screenName, userId: userId)
        guard !userId.isEmpty else { return fresh }
        let index = folderIndex.index(for: saveDir) { scan(in: saveDir) }
        if let cached = index[userId] {
            if cached == fresh || folderExists(saveDir: saveDir, folderName: cached) { return cached }
            // 缓存里的名字是"算过但还没落盘"的：改名后按新昵称重算并覆盖缓存
            folderIndex.remember(userId: userId, folderName: fresh, in: saveDir)
            return fresh
        }
        folderIndex.remember(userId: userId, folderName: fresh, in: saveDir)
        return fresh
    }

    /// 账号文件夹路径：`<保存路径>/<昵称-用户名[数字id]>`（已有文件夹优先，见 `folderName`）。
    static func directory(saveDir: String, name: String, screenName: String, userId: String) -> String {
        (saveDir as NSString).appendingPathComponent(
            folderName(saveDir: saveDir, name: name, screenName: screenName, userId: userId))
    }

    /// 失效目录索引缓存（保存路径变更 / 记录刷新时调用；见 `DownloadStore.refreshDownloadedCaches`）。
    static func invalidateIndex() {
        folderIndex.invalidate()
    }

    /// 该名字在保存路径下是不是一个真的目录。
    private static func folderExists(saveDir: String, folderName: String) -> Bool {
        var isDirectory: ObjCBool = false
        let path = (saveDir as NSString).appendingPathComponent(folderName)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// 扫保存路径下的一级子目录，建 `[数字id: 文件夹名]` 索引。
    ///
    /// 同一个 id 对应多个文件夹时（历史缺陷留下的第二个文件夹）取**名字字典序最小**的那个：
    /// 结果必须确定，否则同一份数据在两次调用间可能落到不同的文件夹。
    private static func scan(in saveDir: String) -> [String: String] {
        guard !saveDir.isEmpty else { return [:] }
        let url = URL(fileURLWithPath: saveDir, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return [:] }
        let folders = entries.compactMap { entry -> String? in
            let folder = entry.lastPathComponent
            guard !folder.hasPrefix("."),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            return folder
        }.sorted()
        var index: [String: String] = [:]
        for folder in folders {
            guard let userId = accountId(fromFolderName: folder), index[userId] == nil else { continue }
            index[userId] = folder
        }
        return index
    }
}
