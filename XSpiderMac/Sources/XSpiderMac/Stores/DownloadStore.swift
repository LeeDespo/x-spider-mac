import Foundation

@Observable
@MainActor
final class DownloadStore {
    static let shared = DownloadStore()

    var tasks: [DownloadTask] = []
    var creationTasks: [CreationTask] = []

    func add(tasks: [DownloadTask]) {
        self.tasks.append(contentsOf: tasks)
    }

    func update(_ task: DownloadTask) {
        if let index = tasks.firstIndex(where: { $0.gid == task.gid }) {
            tasks[index] = task
        }
    }

    func addCreation(_ task: CreationTask) {
        creationTasks.append(task)
    }
}
