import Foundation
import AppKit
import ImageIO

/// 磁盘图片缓存：按 key 存原始图片数据 + 内存 NSCache 池。
/// 重活（网络下载、磁盘读、解码降采样）全部在后台线程；主线程只拿现成位图。
/// 分类（avatar / mediaThumbnail / 其他）受设置开关控制；总量超上限后按最旧清理（后台节流执行）。
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
    /// NSCache 自动响应系统内存压力,替代无上限的手写字典
    private let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        c.totalCostLimit = 192 * 1_048_576
        return c
    }()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var diskCheckTask: Task<Void, Never>?
    private var lastDiskCheckAt = Date.distantPast

    private init() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - 设置

    private func enabled(_ category: Category) -> Bool {
        guard SettingsStore.shared.settings.cachingEnabled else { return false }
        return UserDefaults.standard.object(forKey: category.settingKey) as? Bool ?? true
    }

    /// 缓存上限字节。
    ///
    /// **单位必须与 UI 显示一致**：设置项写的是 "200 MB"，用户用 `ByteCountFormatter`
    /// 的 `.file` 风格（**十进制**，1 MB = 1_000_000 字节）看实际占用。
    /// 此前这里乘 `1_048_576`（MiB），于是"设 200MB 却显示 209.7MB"——
    /// 用户以为上限没生效（实测反馈）。现在统一为十进制，两处口径一致。
    private var limitBytes: Int64 { Int64(SettingsStore.shared.settings.cacheLimitMB) * 1_000_000 }

    // MARK: - 读取（先内存 → 磁盘 → 网络；重活全在后台）

    /// maxPixelSize:解码降采样的最大边长。网格缩略图 600 足够(格子约 200pt@2x),
    /// 详情大图传 1600。key 按尺寸档位区分,不同档位互不污染。
    func image(for urlString: String, category: Category, maxPixelSize: Int = 600) async -> NSImage? {
        guard let url = URL(string: urlString) else { return nil }
        let key = Self.key(for: urlString, maxPixelSize: maxPixelSize)
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let filePath = dir.appendingPathComponent(key)
        if let img = await Self.decodeFile(at: filePath, maxPixelSize: maxPixelSize) {
            memory.setObject(img, forKey: key as NSString, cost: Self.pixelCost(img))
            return img
        }

        if !enabled(category) {
            // 缓存关闭：直接网络加载，不落盘
            return await Self.fetchAndDecode(url: url, maxPixelSize: maxPixelSize, writingTo: nil)
        }

        // 网络加载 → 落盘（inflight 合并同 key 并发请求）
        if let task = inflight[key] { return await task.value }
        let t = Task<NSImage?, Never> { [weak self] in
            let img = await Self.fetchAndDecode(url: url, maxPixelSize: maxPixelSize, writingTo: filePath)
            if let img {
                self?.memory.setObject(img, forKey: key as NSString, cost: Self.pixelCost(img))
            }
            self?.scheduleDiskLimitCheck()
            return img
        }
        inflight[key] = t
        let result = await t.value
        inflight.removeValue(forKey: key)
        return result
    }

    // MARK: - 后台工作（nonisolated async 函数跑在全局并发池,不占主线程）

    private nonisolated static func fetchAndDecode(url: URL, maxPixelSize: Int, writingTo: URL?) async -> NSImage? {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        guard !Task.isCancelled else { return nil }
        if let writingTo { try? data.write(to: writingTo, options: .atomic) }
        return decode(data: data, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func decodeFile(at path: URL, maxPixelSize: Int) async -> NSImage? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return decode(data: data, maxPixelSize: maxPixelSize)
    }

    /// 按 kCGImageSourceThumbnailMaxPixelSize 降采样 + ShouldCacheImmediately 立即解码,
    /// 避免 NSImage(data:) 的惰性解码把全尺寸位图解码拖到主线程首次绘制时
    private nonisolated static func decode(data: Data, maxPixelSize: Int) -> NSImage? {
        if let src = CGImageSourceCreateWithData(data as CFData, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return NSImage(data: data)
    }

    private nonisolated static func pixelCost(_ img: NSImage) -> Int {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        return max(1, cg.bytesPerRow * cg.height)
    }

    // MARK: - 容量控制（后台节流，每 60s 至多一次全目录扫描）

    private func scheduleDiskLimitCheck() {
        guard diskCheckTask == nil, Date() > lastDiskCheckAt.addingTimeInterval(60) else { return }
        lastDiskCheckAt = Date()
        let root = dir
        let limit = limitBytes
        diskCheckTask = Task.detached(priority: .utility) { [weak self] in
            Self.enforceLimit(dir: root, limitBytes: limit)
            await MainActor.run { self?.diskCheckTask = nil }
        }
    }

    private nonisolated static func enforceLimit(dir: URL, limitBytes: Int64) {
        let fm = FileManager.default
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

    /// 清空全部图片缓存（磁盘删除放后台）
    func clearAll() {
        memory.removeAllObjects()
        inflight.removeAll()
        diskCheckTask?.cancel()
        diskCheckTask = nil
        let root = dir
        Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        AppLogger.info("图片缓存已清空", category: "APP")
    }

    /// 当前缓存占用（字节）（仅设置页低频调用，保持同步）
    func currentBytes() -> Int64 {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    // MARK: - Key

    static func key(for urlString: String, maxPixelSize: Int) -> String {
        // URL + 尺寸档位的稳定哈希 + 扩展名（便于肉眼排查）
        let ext = URL(string: urlString)?.pathExtension ?? ""
        var h = UInt64(0xcbf29ce484222325)
        for b in "\(urlString)#\(maxPixelSize)".utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(format: "%016llx", h) + (ext.isEmpty ? "" : ".\(ext)")
    }
}
