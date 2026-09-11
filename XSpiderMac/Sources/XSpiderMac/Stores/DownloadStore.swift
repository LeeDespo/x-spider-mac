import Foundation
import UserNotifications

/// 上游 download store + aria2 的原生替代：URLSessionDownloadTask。
/// 支持暂停/恢复（resumeData）/重试×5/批量创建/sameFileSkip/系统通知。
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()

    // MARK: - 状态

    var tasks: [DownloadTask] = []
    var currentTab: String = "下载中"
    var creationTasks: [CreationTask] = []

    /// 引擎内部状态（resumeData、进行中的 URLSession 任务）
    private var sessionTasks: [String: URLSessionDownloadTask] = [:]
    private var resumeDataMap: [String: Data] = [:]
    private var session = URLSession(configuration: .default)

    private var settings: Settings { SettingsStore.shared.settings }
    private let fm = FileManager.default

    // MARK: - 创建任务

    /// 上游 prepareDownloadTask + createDownloadTask：解析模板 → 检查 sameFileSkip → 启动下载
    func createDownloadTask(post: TwitterPost, media: TwitterMedia) async -> DownloadTask? {
        guard let downloadUrl = downloadURL(for: media) else {
            NSLog("媒体没有下载链接: \(media)")
            return nil
        }

        let templateData = FileNameTemplateData(post: post, media: media)
        let dirName = settings.download.dirTemplate.isEmpty
            ? ""
            : FileNameTemplate.resolve(template: settings.download.dirTemplate, data: templateData)
        let dir = (settings.download.saveDirBase as NSString).appendingPathComponent(dirName)
        let fileName = FileNameTemplate.resolve(template: settings.download.fileNameTemplate, data: templateData)

        let task = DownloadTask(
            gid: UUID().uuidString,
            post: post,
            media: media,
            fileName: fileName,
            dir: dir,
            totalSize: 0,
            completeSize: 0,
            status: .waiting,
            error: nil,
            updatedAt: Date(),
            downloadUrl: downloadUrl,
            retryCountRemains: 5
        )

        // sameFileSkip：目标文件已存在则跳过（上游 fs.exists 检查）
        if settings.download.sameFileSkip {
            let filePath = (dir as NSString).appendingPathComponent(fileName)
            if fm.fileExists(atPath: filePath) {
                NSLog("sameFileSkip 跳过已存在文件: \(filePath)")
                return nil
            }
        }

        tasks.append(task)
        start(task)
        return task
    }

    func batchCreateDownloadTasks(_ paramsList: [(post: TwitterPost, media: TwitterMedia)]) async {
        for params in paramsList {
            _ = await createDownloadTask(post: params.post, media: params.media)
        }
    }

    // MARK: - 任务控制

    func start(_ task: DownloadTask) {
        guard let url = URL(string: task.downloadUrl) else { return }
        try? fm.createDirectory(atPath: task.dir, withIntermediateDirectories: true)

        // resumeData 恢复
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://x.com", forHTTPHeaderField: "Referer")

        let sessionTask: URLSessionDownloadTask
        if let resumeData = resumeDataMap[task.gid] {
            sessionTask = session.downloadTask(withResumeData: resumeData)
            resumeDataMap.removeValue(forKey: task.gid)
        } else {
            sessionTask = session.downloadTask(with: request)
        }

        let gid = task.gid
        let delegate = DownloadDelegate(store: self, gid: gid)
        sessionTask.delegate = delegate
        sessionTask.resume()
        sessionTasks[gid] = sessionTask
        update(gid: gid) { $0.status = .active }
    }

    func pause(_ gid: String) {
        guard let task = sessionTasks[gid] else {
            update(gid: gid) { $0.status = .paused }
            return
        }
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                if let data { self?.resumeDataMap[gid] = data }
                self?.sessionTasks.removeValue(forKey: gid)
                self?.update(gid: gid) { $0.status = .paused }
            }
        })
    }

    func unpause(_ gid: String) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        start(tasks[index])
    }

    func remove(_ gid: String) {
        sessionTasks[gid]?.cancel()
        sessionTasks.removeValue(forKey: gid)
        resumeDataMap.removeValue(forKey: gid)
        tasks.removeAll { $0.gid == gid }
    }

    func pauseAll() {
        for task in tasks where task.status == .active || task.status == .waiting {
            pause(task.gid)
        }
    }

    func unpauseAll() {
        for task in tasks where task.status == .paused {
            unpause(task.gid)
        }
    }

    func removeAll(status: DownloadStatus? = nil) {
        let toRemove = tasks.filter { status == nil || $0.status == status }
        for task in toRemove { remove(task.gid) }
    }

    func redownload(_ gid: String) async {
        guard let task = tasks.first(where: { $0.gid == gid }) else { return }
        remove(gid)
        _ = await createDownloadTask(post: task.post, media: task.media)
    }

    func batchRedownload(_ gids: [String]) async {
        for gid in gids {
            await redownload(gid)
        }
    }

    // MARK: - 任务更新

    func update(gid: String, now: Date = Date(), _ mutation: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        var task = tasks[index]
        if task.updatedAt > now { return }
        mutation(&task)
        task.updatedAt = now
        tasks[index] = task
    }

    // MARK: - 下载完成回调（DownloadDelegate 调用）

    func handleDownloadCompleted(gid: String, localURL: URL?, response: URLResponse?, error: Error?) {
        defer { sessionTasks.removeValue(forKey: gid) }

        guard let index = tasks.firstIndex(where: { $0.gid == gid }) else { return }
        let task = tasks[index]

        if let error {
            // 上游逻辑：重试次数未用尽 → 重新入队；用尽 → error 状态 + 通知
            if task.retryCountRemains > 0 {
                NSLog("Task \(task.fileName) failed, retry. Remains: \(task.retryCountRemains)")
                update(gid: gid) {
                    $0.status = .waiting
                    $0.retryCountRemains -= 1
                    $0.error = error.localizedDescription
                }
                // 延迟重试
                let retryGid = gid
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let t = self.tasks.first(where: { $0.gid == retryGid }), t.status == .waiting {
                        self.start(t)
                    }
                }
            } else {
                update(gid: gid) {
                    $0.status = .error
                    $0.error = error.localizedDescription
                }
                notify(title: "任务下载失败", body: "\(task.fileName)\n\(error.localizedDescription)")
            }
            return
        }

        guard let localURL else {
            update(gid: gid) { $0.status = .error; $0.error = "本地文件缺失" }
            return
        }

        // 移动到目标目录
        let destURL = URL(fileURLWithPath: (task.dir as NSString).appendingPathComponent(task.fileName))
        try? fm.createDirectory(atPath: task.dir, withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
            try fm.moveItem(at: localURL, to: destURL)
            let size = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
            update(gid: gid) {
                $0.status = .complete
                $0.completeSize = size ?? 0
                $0.totalSize = size ?? 0
                $0.error = nil
            }
        } catch {
            update(gid: gid) { $0.status = .error; $0.error = error.localizedDescription }
        }
    }

    // MARK: - 系统通知（上游 notification.sendNotification）

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - URLSession 代理（进度 + 完成）

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let store: DownloadStore
    let gid: String

    init(store: DownloadStore, gid: String) {
        self.store = store
        self.gid = gid
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.store.update(gid: self.gid) {
                $0.completeSize = totalBytesWritten
                if totalBytesExpectedToWrite > 0 { $0.totalSize = totalBytesExpectedToWrite }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            self.store.handleDownloadCompleted(gid: self.gid, localURL: location, response: downloadTask.response, error: nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.store.handleDownloadCompleted(gid: self.gid, localURL: nil, response: task.response, error: error)
        }
    }
}
