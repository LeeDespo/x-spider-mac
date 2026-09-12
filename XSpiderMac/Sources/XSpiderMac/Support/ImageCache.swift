import Foundation
import AppKit

/// 磁盘图片缓存：按 key 存原始图片数据 + 内存 NSImage 池。
/// 分类（avatar / mediaThumbnail / 其他）受设置开关控制；总量超上限后按最旧清理。
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    enum Category: String, CaseIterable {
        case avatars          // 用户头像
        case mediaThumbnails  // 媒体/推文缩略图

        var settingKey: String {
            switch self {
            case .avatars: return "cache.avatars"
            case .mediaThumbnails: return "cache.mediaThumbnails"
            }
        }

        var displayName: String {
            switch self {
            case .avatars: return L("用户头像")
            case .mediaThumbnails: return L("媒体缩略图")
            }
        }
    }

    private let fm = FileManager.default
    private let dir: URL = AppDirectories.cacheRoot.appendingPathComponent("images", isDirectory: true)
    private var memory: [String: NSImage] = [:]
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - 设置

    private func enabled(_ category: Category) -> Bool {
        guard SettingsStore.shared.settings.cachingEnabled else { return false }
        return UserDefaults.standard.object(forKey: category.settingKey) as? Bool ?? true
    }

    /// 缓存上限字节（50–500MB）
    private var limitBytes: Int64 { Int64(SettingsStore.shared.settings.cacheLimitMB) * 1_048_576 }

    // MARK: - 读取（先内存 → 磁盘 → 网络）

    func image(for urlString: String, category: Category) async -> NSImage? {
        guard let url = URL(string: urlString) else { return nil }
        let key = Self.key(for: urlString)
        if let hit = memory[key] { return hit }

        let filePath = dir.appendingPathComponent(key)
        if let data = try? Data(contentsOf: filePath), let img = NSImage(data: data) {
            memory[key] = img
            return img
        }

        if !enabled(category) {
            // 缓存关闭：直接网络加载，不落盘
            return try? await load(url)
        }

        // 网络加载 → 落盘
        if let task = inflight[key] { return await task.value }
        let t = Task<NSImage?, Never> {
            guard let data = try? await Self.fetch(url) else { return nil }
            try? data.write(to: filePath, options: .atomic)
            let img = NSImage(data: data)
            if let img { self.memory[key] = img }
            await self.enforceLimitIfNeeded()
            return img
        }
        inflight[key] = t
        let result = await t.value
        inflight.removeValue(forKey: key)
        return result
    }

    private nonisolated static func fetch(_ url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    private func load(_ url: URL) async throws -> NSImage? {
        let data = try await Self.fetch(url)
        return NSImage(data: data)
    }

    // MARK: - 容量控制

    func enforceLimitIfNeeded() {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var total: Int64 = 0
        let entries: [(url: URL, date: Date, size: Int64)] = files.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(v?.fileSize ?? 0)
            total += size
            return (u, v?.contentModificationDate ?? .distantPast, size)
        }
        guard total > limitBytes else { return }
        let over = total - limitBytes
        var removed: Int64 = 0
        for e in entries.sorted(by: { $0.date < $1.date }) {
            guard removed < over else { break }
            try? fm.removeItem(at: e.url)
            removed += e.size
        }
        AppLogger.info("缓存超限自动清理", category: "APP", ["removed": "\(removed)", "limit": "\(limitBytes)"])
    }

    /// 清空全部图片缓存
    func clearAll() {
        memory.removeAll()
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? fm.removeItem(at: f) }
        AppLogger.info("图片缓存已清空", category: "APP")
    }

    /// 当前缓存占用（字节）
    func currentBytes() -> Int64 {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    // MARK: - Key

    static func key(for urlString: String) -> String {
        // URL 的稳定哈希 + 扩展名（便于肉眼排查）
        let ext = URL(string: urlString)?.pathExtension ?? ""
        var h = UInt64(0xcbf29ce484222325)
        for b in urlString.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(format: "%016llx", h) + (ext.isEmpty ? "" : ".\(ext)")
    }
}
