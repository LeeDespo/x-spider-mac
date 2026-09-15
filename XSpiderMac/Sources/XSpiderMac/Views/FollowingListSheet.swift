import SwiftUI

/// 关注清单管理弹窗(账户卡弹窗 → 关注清单):
/// 搜索(昵称/用户名) + 头像矩形网格 + 选中蓝框 + 左侧全选/反选 + 右侧下载(完成后关app)/加入同步清单/退出
struct FollowingListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var users: [TwitterUser] = []
    @State private var selected: Set<String> = []   // screenName
    @State private var searchText = ""
    @State private var loading = false
    @State private var loadingMore = false
    @State private var cursor: String?
    @State private var errorMessage: String?
    @State private var showShutdownConfirm = false
    @State private var addedToSync = false

    private var filtered: [TwitterUser] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return users }
        return users.filter {
            $0.screenName.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏:搜索
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("搜索昵称或用户名"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if loading {
                ProgressView(L("加载关注列表…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
                    Text(errorMessage).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 12)], spacing: 14) {
                        ForEach(filtered, id: \.screenName) { user in
                            followCell(user)
                        }
                    }
                    .padding(14)
                    Color.clear.frame(height: 1)
                        .onAppear {
                            if cursor != nil, !loadingMore { Task { await loadMore() } }
                        }
                    if loadingMore { ProgressView().padding(8) }
                }
            }

            Divider()

            // 底部操作条:左(全选/反选) 右(下载/同步清单/退出)
            HStack(spacing: 10) {
                Button { selected = Set(filtered.map(\.screenName)) } label: {
                    Label(L("全选"), systemImage: "checkmark.circle")
                }
                .compatGlassButton()
                Button {
                    let all = Set(filtered.map(\.screenName))
                    selected = selected.isSubset(of: all)
                        ? all.subtracting(selected)
                        : all.symmetricDifference(selected)
                } label: {
                    Label(L("反选"), systemImage: "circle.lefthalf.filled")
                }
                .compatGlassButton()
                Spacer()
                Text(L("已选") + " \(selected.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    showShutdownConfirm = true
                } label: {
                    Label(L("下载全部媒体"), systemImage: "arrow.down.circle.fill")
                }
                .compatGlassButton()
                .disabled(selected.isEmpty)
                Button {
                    addToSyncList()
                } label: {
                    Label(addedToSync ? L("已加入同步清单") : L("加入同步清单"), systemImage: addedToSync ? "checkmark" : "plus.circle")
                }
                .compatGlassButton()
                .disabled(selected.isEmpty || addedToSync)
                Button(role: .destructive) {
                    dismiss()
                } label: {
                    Label(L("退出"), systemImage: "xmark.circle")
                }
                .compatGlassButton()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 720, height: 560)
        .background(.regularMaterial)
        .confirmationDialog(
            L("下载并退出？"),
            isPresented: $showShutdownConfirm,
            titleVisibility: .visible
        ) {
            Button(L("全部完成后关闭应用"), role: .destructive) { startBatchDownloadAndQuit() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("将逐个账户创建全部媒体的下载任务，所有任务完成后自动关闭应用。"))
        }
        .task { await initialLoad() }
    }

    // MARK: - 网格单元

    private func followCell(_ user: TwitterUser) -> some View {
        let isSelected = selected.contains(user.screenName)
        return Button {
            if isSelected { selected.remove(user.screenName) } else { selected.insert(user.screenName) }
        } label: {
            VStack(spacing: 6) {
                CachedAvatarView(urlString: user.avatar, size: 64)
                    .overlay {
                        Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                Text("\(user.name)-@\(user.screenName)")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    // MARK: - 数据

    private func initialLoad() async {
        loading = true
        defer { loading = false }
        guard let me = AppStore.shared.account else {
            errorMessage = L("未登录")
            return
        }
        do {
            // 需要 userId:用 getAccountInfo 已存;这里直接查自己(跟随当前账户 id)
            if let id = await Self.currentUserId() {
                let r = try await TwitterAPI.shared.getFollowing(userId: id)
                users = r.users
                cursor = r.cursor
            } else {
                errorMessage = L("无法获取当前账户")
            }
        } catch {
            errorMessage = L("关注列表加载失败：") + error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let c = cursor else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            guard let id = await Self.currentUserId() else { return }
            let r = try await TwitterAPI.shared.getFollowing(userId: id, cursor: c)
            let existing = Set(users.map(\.screenName))
            users.append(contentsOf: r.users.filter { !existing.contains($0.screenName) })
            cursor = r.cursor != c ? r.cursor : nil
        } catch {
            AppLogger.warn("关注列表翻页失败", category: "HOME", ["error": error.localizedDescription])
        }
    }

    static func currentUserId() async -> String? {
        if let id = AppStore.shared.account?.id { return id }
        // TwitterAccountInfo 无 id 时从 API 侧补
        return await TwitterAPI.shared.currentUserId()
    }

    // MARK: - 动作

    private func addToSyncList() {
        let targets = users.filter { selected.contains($0.screenName) }
        let store = SyncStore.shared
        for u in targets where !store.users.contains(where: { $0.screenName == u.screenName }) {
            store.addUser(user: u)
        }
        addedToSync = true
    }

    /// 逐个账户创建下载任务;全部完成后关闭应用
    private func startBatchDownloadAndQuit() {
        let targets = users.filter { selected.contains($0.screenName) }
        dismiss()
        Task {
            for u in targets {
                do {
                    let user = try await TwitterAPI.shared.getUser(screenName: u.screenName)
                    guard !user.id.isEmpty else { continue }
                    // 翻完该用户的媒体时间线,创建任务
                    var next: String? = nil
                    var guardCount = 0
                    repeat {
                        let r = try await TwitterAPI.shared.getUserMedias(userId: user.id, cursor: next)
                        let items: [(post: TwitterPost, media: TwitterMedia)] = r.posts.flatMap { p in
                            (p.medias ?? []).map { (p, $0) }
                        }
                        await DownloadStore.shared.batchCreateDownloadTasks(items)
                        next = r.cursor
                        guardCount += 1
                    } while next != nil && guardCount < 500
                } catch {
                    AppLogger.warn("批量下载账户失败", category: "DL", ["user": u.screenName, "error": error.localizedDescription])
                }
            }
            // 全部任务完成 → 退出应用
            await DownloadStore.shared.waitUntilAllSettled()
            await MainActor.run { NSApp.terminate(nil) }
        }
    }
}
