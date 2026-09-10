import Foundation
import UniformTypeIdentifiers

actor DownloadEngine {
    static let shared = DownloadEngine()

    private var tasks: [DownloadTask] = []
    private var sessions: [String: URLSessionDownloadTask] = [:]
    private var retryTimers: [String: Timer] = [:]

    func createTasks(paramsList: [CreateDownloadParams], settings: Settings) async -> [DownloadTask] {
        var created: [DownloadTask] = []
        for params in paramsList {
            guard let url = downloadURL(for: params.media) else { continue }
            let now = Date()
            let task = DownloadTask(
                gid: UUID().uuidString,
                post: params.post,
                media: params.media,
                fileName: resolveFileName(template: settings.download.fileNameTemplate, data: params),
                dir: settings.download.saveDirBase,
                totalSize: 0,
                completeSize: 0,
                status: .waiting,
                error: nil,
                updatedAt: now,
                downloadUrl: url,
                retryCountRemains: 5
            )
            tasks.append(task)
            created.append(task)
        }
        return created
    }

    func start(taskID: String) {
        guard let task = tasks.first(where: { $0.gid == taskID }) else { return }
        guard let url = URL(string: task.downloadUrl) else { return }
        let session = URLSession.shared
        let downloadTask = session.downloadTask(with: url) { [weak self] localURL, response, error in
            Task { await self?.handleCompletion(taskID: taskID, localURL: localURL, error: error) }
        }
        sessions[taskID] = downloadTask
        downloadTask.resume()
        update(taskID: taskID) { $0.status = .active }
    }

    func pause(taskID: String) {
        sessions[taskID]?.suspend()
        update(taskID: taskID) { $0.status = .paused }
    }

    func resume(taskID: String) {
        sessions[taskID]?.resume()
        update(taskID: taskID) { $0.status = .active }
    }

    func cancel(taskID: String) {
        sessions[taskID]?.cancel()
        sessions.removeValue(forKey: taskID)
        update(taskID: taskID) { $0.status = .removed }
    }

    func task(id: String) -> DownloadTask? { tasks.first { $0.gid == id } }

    // MARK: - Internal

    private func handleCompletion(taskID: String, localURL: URL?, error: Error?) async {
        defer { sessions.removeValue(forKey: taskID) }
        if let error {
            update(taskID: taskID) { $0.status = .error; $0.error = error.localizedDescription }
            return
        }
        update(taskID: taskID) { $0.status = .complete }
    }

    private func update(taskID: String, mutation: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.gid == taskID }) else { return }
        var task = tasks[index]
        mutation(&task)
        task.updatedAt = Date()
        tasks[index] = task
    }
}

struct CreateDownloadParams: Sendable {
    let post: TwitterPost
    let media: TwitterMedia
}

func downloadURL(for media: TwitterMedia) -> String? {
    switch media.type {
    case .photo:
        guard var url = URL(string: media.url ?? "") else { return nil }
        url.append(queryItems: [URLQueryItem(name: "name", value: "orig")])
        return url.absoluteString
    case .video:
        let best = media.videoInfo?.variants?.compactMap { $0 }.filter { $0.bitrate != nil }.sorted { ($0.bitrate!) < ($1.bitrate!) }.last
        return best?.url
    case .gif:
        return media.videoInfo?.variants?.first?.url
    }
}

func resolveFileName(template: String, data: CreateDownloadParams) -> String {
    // Minimal placeholder replacement; full template engine lives in FileNameTemplate.
    let post = data.post
    let media = data.media
    var result = template
    result = result.replacingOccurrences(of: "%USER_SCREEN_NAME%", with: post.user.screenName)
    result = result.replacingOccurrences(of: "%POST_ID%", with: post.id)
    result = result.replacingOccurrences(of: "%MEDIA_INDEX%", with: "1")
    result = result.replacingOccurrences(of: "%EXT%", with: media.type == .photo ? ".jpg" : ".mp4")
    return result.makeSafeFileName()
}

extension String {
    func makeSafeFileName() -> String {
        let invalid = CharacterSet(charactersIn: #"<>/?:\|"# + "*\"").union(.controlCharacters)
        return self.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
    }
}
