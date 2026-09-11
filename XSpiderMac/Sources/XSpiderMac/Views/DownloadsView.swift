import SwiftUI

/// 上游 DownloadManagement.tsx 的移植：三 Tab（下载中/已完成/失败）+ 任务创建进度 + 任务列表。
struct DownloadsView: View {
    @State private var store = DownloadStore.shared
    @State private var creationStore = CreationTaskStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // 创建中任务（上游 CreationTasks：可取消、进度计数）
            if !creationStore.creationTasks.isEmpty {
                creationTaskBar
            }

            // Tab 栏（上游 Tabs：计数徽标）
            tabBar

            Divider()

            // Tab 内容
            switch store.currentTab {
            case "下载中": taskList(filter: { [.waiting, .active, .paused].contains($0.status) })
            case "已完成": taskList(filter: { $0.status == .complete })
            case "失败": taskList(filter: { $0.status == .error })
            default: EmptyView()
            }

            // 批量操作（上游 DownloadList batchActions）
            batchActionBar
        }
        .navigationTitle("下载管理")
    }

    // MARK: - Tab 栏

    private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach(["下载中", "已完成", "失败"], id: \.self) { tabName in
                let count = store.tasks.filter { statusFilter(tabName).contains($0.status) }.count
                Button {
                    store.currentTab = tabName
                } label: {
                    HStack(spacing: 4) {
                        Text(tabName)
                        Text("(\(count))")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .font(store.currentTab == tabName ? .headline : .body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.currentTab == tabName ? .primary : .secondary)
                .overlay(alignment: .bottom) {
                    if store.currentTab == tabName {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func statusFilter(_ tab: String) -> [DownloadStatus] {
        switch tab {
        case "下载中": return [.waiting, .active, .paused]
        case "已完成": return [.complete]
        case "失败": return [.error]
        default: return []
        }
    }

    // MARK: - 创建任务进度（上游 CreationTasks.tsx）

    private var creationTaskBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("共 \(creationStore.creationTasks.count) 个任务创建中")
                .font(.subheadline)

            ForEach(creationStore.creationTasks) { task in
                HStack {
                    Text("\(task.user.name) @\(task.user.screenName)")
                    Spacer()
                    Text("已发送：\(task.completeCount)")
                    if task.skipCount > 0 {
                        Text("已跳过：\(task.skipCount)")
                            .help("跳过原因：1. 相同文件名已存在且开启跳过相同文件；2. 爬取进度未到指定开始日期")
                    }
                    Button("取消") {
                        creationStore.removeCreationTask(task.id)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - 任务列表（上游 DownloadList：缩略图 + 文件名 + 用户 + 进度 + 速度 + 操作）

    private func taskList(filter: @escaping (DownloadTask) -> Bool) -> some View {
        let filtered = store.tasks.filter(filter).sorted { a, b in
            let order: [DownloadStatus: Int] = [.active: 0, .paused: 1, .waiting: 2, .error: 3, .complete: 4, .removed: 5]
            return (order[a.status] ?? 9) < (order[b.status] ?? 9)
        }

        return Group {
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("暂无任务")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { task in
                    DownloadTaskRow(task: task)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - 批量操作

    private var batchActionBar: some View {
        HStack(spacing: 12) {
            switch store.currentTab {
            case "下载中":
                Button("全部暂停") { store.pauseAll() }
                Button("全部恢复") { store.unpauseAll() }
                Button("全部删除", role: .destructive) { store.removeAll(status: .waiting) }
            case "已完成":
                Button("全部删除", role: .destructive) { store.removeAll(status: .complete) }
            case "失败":
                Button("全部重试") { Task { await store.batchRedownload(store.tasks.filter { $0.status == .error }.map(\.gid)) } }
                Button("全部删除", role: .destructive) { store.removeAll(status: .error) }
            default:
                EmptyView()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 单行任务（上游 DownloadListItem）

struct DownloadTaskRow: View {
    let task: DownloadTask
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            // 缩略图
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: task.media.type == .photo ? "photo" : "video")
                                .foregroundStyle(.secondary)
                        }
                        .task { await loadThumbnail() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(task.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("@\(task.post.user.screenName)")
                        .foregroundStyle(.secondary)
                    statusText
                }
                .font(.caption)

                if task.status == .active {
                    ProgressView(value: task.totalSize > 0 ? Double(task.completeSize) / Double(task.totalSize) : 0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    HStack {
                        Text("\(ByteCountFormatter.string(fromByteCount: task.completeSize, countStyle: .file)) / \(task.totalSize > 0 ? ByteCountFormatter.string(fromByteCount: task.totalSize, countStyle: .file) : "未知大小")")
                        Spacer()
                        if let error = task.error {
                            Text(error)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // 操作按钮（上游 TaskActions：暂停/恢复/重试/删除/打开文件/打开文件夹）
            HStack(spacing: 4) {
                switch task.status {
                case .active:
                    Button { DownloadStore.shared.pause(task.gid) } label: {
                        Image(systemName: "pause.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("暂停")
                case .paused:
                    Button { DownloadStore.shared.unpause(task.gid) } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("恢复")
                case .error:
                    Button { Task { await DownloadStore.shared.redownload(task.gid) } } label: {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("重试")
                default:
                    EmptyView()
                }

                if task.status == .complete {
                    Button { openFile(task) } label: {
                        Image(systemName: "doc")
                    }
                    .buttonStyle(.borderless)
                    .help("打开文件")
                    Button { showInFolder(task) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("在文件夹中显示")
                }

                Button { DownloadStore.shared.remove(task.gid) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除")
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: some View {
        Group {
            switch task.status {
            case .waiting: Text("等待中").foregroundStyle(.orange)
            case .active: Text("下载中").foregroundStyle(.blue)
            case .paused: Text("已暂停").foregroundStyle(.yellow)
            case .error: Text("失败").foregroundStyle(.red)
            case .complete: Text("完成").foregroundStyle(.green)
            case .removed: Text("已移除").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func loadThumbnail() async {
        guard let urlString = task.media.url, let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            thumbnail = NSImage(data: data)
        } catch {}
    }

    private func openFile(_ task: DownloadTask) {
        let path = (task.dir as NSString).appendingPathComponent(task.fileName)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func showInFolder(_ task: DownloadTask) {
        let path = (task.dir as NSString).appendingPathComponent(task.fileName)
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: task.dir)
    }
}
