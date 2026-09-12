import SwiftUI

/// 上游 DownloadManagement.tsx 的移植：三 Tab（下载中/已完成/失败）+ 任务创建进度 + 任务列表。
/// 新增：按推特用户名筛选历史（头像小窗）、显示全部、删除当前视图记录。
struct DownloadsView: View {
    @State private var store = DownloadStore.shared
    @State private var creationStore = CreationTaskStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var appearedOnce = false

    var body: some View {
        VStack(spacing: 0) {
            // 创建中任务（上游 CreationTasks：可取消、进度计数）
            if !creationStore.creationTasks.isEmpty {
                creationTaskBar
            }

            // Tab 栏（上游 Tabs：计数徽标 + 用户筛选）
            tabBar

            Divider()

            // Tab 内容
            switch store.currentTab {
            case L("下载中"): taskList(statuses: [.waiting, .active, .paused])
            case L("已完成"): taskList(statuses: [.complete])
            case L("失败"): taskList(statuses: [.error])
            default: EmptyView()
            }

            // 批量操作（上游 DownloadList batchActions）
            batchActionBar
        }
        .navigationTitle(L("下载管理"))
        .onAppear {
            // 隐私开关：进入页面时清空上一次会话的下载历史（仅记录不删文件）
            if appearedOnce, SettingsStore.shared.settings.autoClearDownloadHistoryEnabled, !store.tasks.isEmpty {
                store.removeAll()
            }
            appearedOnce = true
        }
    }

    private var currentStatuses: [DownloadStatus] {
        switch store.currentTab {
        case L("下载中"): return [.waiting, .active, .paused]
        case L("已完成"): return [.complete]
        case L("失败"): return [.error]
        default: return []
        }
    }

    // MARK: - Tab 栏（含用户筛选）

    private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach([L("下载中"), L("已完成"), L("失败")], id: \.self) { tabName in
                let count = store.tasksForCurrentTab(statuses: statusFilter(tabName)).count
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

            // 用户筛选：按钮 + 显示全部
            userFilterControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var userFilterControls: some View {
        HStack(spacing: 8) {
            if store.userFilterScreenName != nil {
                Button(L("显示全部")) {
                    withAnimation(.spring(duration: 0.25)) { store.userFilterScreenName = nil }
                }
                .compatGlassButton()
                .controlSize(.small)
            }

            Button {
                withAnimation(.spring(duration: 0.3)) { store.userFilterPickerVisible.toggle() }
            } label: {
                Label(store.userFilterScreenName.map { "@\($0)" } ?? L("按用户筛选"),
                      systemImage: "person.crop.circle")
            }
            .compatGlassButton()
            .controlSize(.small)
        }
        .popover(isPresented: Binding(
            get: { store.userFilterPickerVisible },
            set: { store.userFilterPickerVisible = $0 }
        ), arrowEdge: .top) {
            UserFilterPicker(store: store)
        }
    }

    private func statusFilter(_ tab: String) -> [DownloadStatus] {
        switch tab {
        case L("下载中"): return [.waiting, .active, .paused]
        case L("已完成"): return [.complete]
        case L("失败"): return [.error]
        default: return []
        }
    }

    // MARK: - 创建任务进度（上游 CreationTasks.tsx）

    private var creationTaskBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("共") + " \(creationStore.creationTasks.count) " + L("个任务创建中"))
                .font(.subheadline)

            ForEach(creationStore.creationTasks) { task in
                HStack {
                    Text("\(task.user.name) @\(task.user.screenName)")
                    Spacer()
                    Text(L("已发送：") + "\(task.completeCount)")
                    if task.skipCount > 0 {
                        Text(L("已跳过：") + "\(task.skipCount)")
                            .help(L("跳过原因：1. 相同文件名已存在且开启跳过相同文件；2. 爬取进度未到指定开始日期"))
                    }
                    Button(L("取消")) {
                        creationStore.removeCreationTask(task.id)
                    }
                    .compatGlassButton()
                    .controlSize(.small)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .liquidGlass(cornerRadius: 12)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - 任务列表（上游 DownloadList：缩略图 + 文件名 + 用户 + 进度 + 速度 + 操作）

    private func taskList(statuses: [DownloadStatus]) -> some View {
        let filtered = store.tasksForCurrentTab(statuses: statuses).sorted { a, b in
            let order: [DownloadStatus: Int] = [.active: 0, .paused: 1, .waiting: 2, .error: 3, .complete: 4, .removed: 5]
            return (order[a.status] ?? 9) < (order[b.status] ?? 9)
        }

        return Group {
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(L("暂无任务"))
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

    // MARK: - 批量操作（删除当前视图 = 当前 Tab + 当前用户筛选）

    private var batchActionBar: some View {
        HStack(spacing: 12) {
            switch store.currentTab {
            case L("下载中"):
                Button(L("全部暂停")) { store.pauseAll() }
                Button(L("全部恢复")) { store.unpauseAll() }
                Button(L("删除当前记录"), role: .destructive) {
                    store.removeVisibleRecords(statuses: currentStatuses)
                }
            case L("已完成"):
                Button(L("删除当前记录"), role: .destructive) {
                    store.removeVisibleRecords(statuses: currentStatuses)
                }
            case L("失败"):
                Button(L("全部重试")) { Task { await store.batchRedownload(store.tasksForCurrentTab(statuses: currentStatuses).map(\.gid)) } }
                Button(L("删除当前记录"), role: .destructive) {
                    store.removeVisibleRecords(statuses: currentStatuses)
                }
            default:
                EmptyView()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 用户筛选小窗（头像 + 加粗昵称 + 用户名，点击切换筛选）

struct UserFilterPicker: View {
    @Bindable var store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("选择用户"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if store.knownUsers.isEmpty {
                Text(L("暂无记录"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.knownUsers, id: \.screenName) { user in
                            Button {
                                withAnimation(.spring(duration: 0.25)) {
                                    store.userFilterScreenName = user.screenName
                                    store.userFilterPickerVisible = false
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    AccountAvatarView(urlString: user.avatar, size: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(user.name)
                                            .font(.body.weight(.bold))
                                            .foregroundStyle(.primary)
                                        Text("@\(user.screenName)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if store.userFilterScreenName == user.screenName {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 260)
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
                        Text("\(ByteCountFormatter.string(fromByteCount: task.completeSize, countStyle: .file)) / \(task.totalSize > 0 ? ByteCountFormatter.string(fromByteCount: task.totalSize, countStyle: .file) : L("未知大小"))")
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
                    .help(L("暂停"))
                case .paused:
                    Button { DownloadStore.shared.unpause(task.gid) } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("恢复"))
                case .error:
                    Button { Task { await DownloadStore.shared.redownload(task.gid) } } label: {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("重试"))
                default:
                    EmptyView()
                }

                if task.status == .complete {
                    Button { openFile(task) } label: {
                        Image(systemName: "doc")
                    }
                    .buttonStyle(.borderless)
                    .help(L("打开文件"))
                    Button { showInFolder(task) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(L("在文件夹中显示"))
                }

                Button { DownloadStore.shared.remove(task.gid) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L("删除"))
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: some View {
        Group {
            switch task.status {
            case .waiting: Text(L("等待中")).foregroundStyle(.orange)
            case .active: Text(L("下载中")).foregroundStyle(.blue)
            case .paused: Text(L("已暂停")).foregroundStyle(.yellow)
            case .error: Text(L("失败")).foregroundStyle(.red)
            case .complete: Text(L("完成")).foregroundStyle(.green)
            case .removed: Text(L("已移除")).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func loadThumbnail() async {
        // 已完成且有本地文件：直接读本地（不发网络请求）
        if task.status == .complete {
            let localPath = (task.dir as NSString).appendingPathComponent(task.fileName)
            if let img = NSImage(contentsOfFile: localPath) {
                thumbnail = img
                return
            }
            // 视频没有系统缩略图时落回占位图（不联网）
            if task.media.type != .photo { return }
        }
        // 未完成或本地文件缺失：网络取缩略图
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
