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
    private var inflight: [String: Task<CGImage?, Never>] = [:]
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

    /// 缓存上限字节（`nil` = 设置里选了「无上限」，不做容量控制）。
    ///
    /// 单位口径（十进制 MB）由 `Settings.cacheLimitBytes` 决定，见那里的说明。
    private var limitBytes: Int64? { SettingsStore.shared.settings.cacheLimitBytes }

    // MARK: - 读取（先内存 → 磁盘 → 网络；重活全在后台）

    /// maxPixelSize:解码降采样的最大边长。网格缩略图 600 足够(格子约 200pt@2x),
    /// 详情大图传 1600。key 按尺寸档位区分,不同档位互不污染。
    func image(for urlString: String, category: Category, maxPixelSize: Int = 600) async -> NSImage? {
        guard let url = URL(string: urlString) else { return nil }
        let key = Self.key(for: urlString, maxPixelSize: maxPixelSize)
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let filePath = dir.appendingPathComponent(key)
        if let cg = await Self.decodeFile(at: filePath, maxPixelSize: maxPixelSize) {
            let img = Self.makeImage(cg)
            memory.setObject(img, forKey: key as NSString, cost: Self.pixelCost(cg))
            return img
        }

        if !enabled(category) {
            // 缓存关闭：直接网络加载，不落盘。后台只传 Sendable 的 CGImage，
            // NSImage 始终在 MainActor 上创建与使用。
            guard let cg = await Self.fetchAndDecode(url: url, maxPixelSize: maxPixelSize, writingTo: nil) else {
                return nil
            }
            return Self.makeImage(cg)
        }

        // 网络加载 → 落盘（inflight 合并同 key 并发请求）。
        // Task.Success 不能是 NSImage：AppKit 明确将 NSImage 标为 non-Sendable。
        let task: Task<CGImage?, Never>
        if let existing = inflight[key] {
            task = existing
        } else {
            let created = Task {
                await Self.fetchAndDecode(url: url, maxPixelSize: maxPixelSize, writingTo: filePath)
            }
            inflight[key] = created
            task = created
        }

        let cg = await task.value
        inflight.removeValue(forKey: key)
        scheduleDiskLimitCheck()

        guard let cg else { return nil }
        let img = Self.makeImage(cg)
        memory.setObject(img, forKey: key as NSString, cost: Self.pixelCost(cg))
        return img
    }

    // MARK: - 后台工作（nonisolated async 函数跑在全局并发池,不占主线程）

    private nonisolated static func fetchAndDecode(url: URL, maxPixelSize: Int, writingTo: URL?) async -> CGImage? {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        guard !Task.isCancelled else { return nil }
        if let writingTo { try? data.write(to: writingTo, options: .atomic) }
        return decode(data: data, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func decodeFile(at path: URL, maxPixelSize: Int) async -> CGImage? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return decode(data: data, maxPixelSize: maxPixelSize)
    }

    /// 按 kCGImageSourceThumbnailMaxPixelSize 降采样 + ShouldCacheImmediately 立即解码。
    /// 后台只产出 CGImage；NSImage 留在 MainActor 上构造，避免跨并发域传递 AppKit 对象。
    private nonisolated static func decode(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return cg
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func makeImage(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private nonisolated static func pixelCost(_ cg: CGImage) -> Int {
        max(1, cg.bytesPerRow * cg.height)
    }

    // MARK: - 容量控制（后台节流，每 60s 至多一次全目录扫描）

    private func scheduleDiskLimitCheck() {
        guard diskCheckTask == nil, Date() > lastDiskCheckAt.addingTimeInterval(60) else { return }
        // 无上限：没有可回收的目标，连扫描都不必做
        guard let limit = limitBytes else { return }
        lastDiskCheckAt = Date()
        let root = dir
        // 目标百分比读一次快照传下去（后台任务里不碰 MainActor 的 settings）
        let targetPercent = Int64(SettingsStore.shared.settings.cacheReclaimTargetPercent)
        diskCheckTask = Task.detached(priority: .utility) { [weak self] in
            Self.enforceLimit(dir: root, limitBytes: limit, targetPercent: targetPercent)
            await MainActor.run { self?.diskCheckTask = nil }
        }
    }

    /// 超限时删除**最旧**的文件，直到占用降到「上限 × 目标百分比」。
    ///
    /// 例：上限 1 GB、目标 60%、当前 2 GB → 从最旧开始删，删到只剩 600 MB。
    ///
    /// **为什么不只降到刚好低于上限**：那样缓存再涨一点就要重新全目录扫描并再清一次
    /// （`scheduleDiskLimitCheck` 有 60s 节流，写入频繁时仍会不断触发）。
    /// 直接回收出余量，后续写入可以长时间不再越界。
    /// 目标为 `0%` 时全部清空。
    ///
    /// 可见性为 internal（而非 private）以便单测直接跑真实删除逻辑。
    nonisolated static func enforceLimit(dir: URL,
                                         limitBytes: Int64,
                                         targetPercent: Int64) {
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

        let target = reclaimTargetBytes(limitBytes: limitBytes, targetPercent: targetPercent)
        var remaining = total
        for e in entries.sorted(by: { $0.date < $1.date }) {
            guard remaining > target else { break }
            try? fm.removeItem(at: e.url)
            remaining -= e.size
        }
        AppLogger.info("缓存超限自动清理", category: "APP", [
            "before": "\(total)",
            "after": "\(remaining)",
            "limit": "\(limitBytes)",
            "target": "\(target)",
        ])
    }

    /// 回收目标字节数 = **上限 × 目标百分比 / 100**。
    ///
    /// 先除后乘，避免上限很大时 `limit × percent` 溢出。纯函数，便于单测。
    nonisolated static func reclaimTargetBytes(limitBytes: Int64, targetPercent: Int64) -> Int64 {
        let r = Settings.cacheReclaimTargetRange
        let clamped = min(Int64(r.upperBound), max(Int64(r.lowerBound), targetPercent))
        return limitBytes / 100 * clamped
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
