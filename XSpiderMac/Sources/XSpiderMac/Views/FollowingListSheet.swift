import SwiftUI

/// 关注清单管理弹窗(账户卡弹窗 → 关注清单):
/// 搜索(昵称/用户名) + 头像矩形网格 + 选中蓝框 + 左侧全选/反选 + 右侧下载(完成后关app)/加入同步清单/退出
struct FollowingListSheet: View {
    /// 非选择模式下点击用户 → 跳到该用户的搜索页（由 SidebarView 注入）
    var onSearchUser: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var users: [TwitterUser] = []
    @State private var selected: Set<String> = []   // screenName
    /// 选择模式：批量操作（全选/反选/下载/加入同步）只在此模式下出现
    @State private var selectionMode = false
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

            // 底部操作条。
            //
            // **批量操作藏在「选择」按钮之后**（需求）：
            // 全选 / 反选 / 下载全部媒体 / 加入同步清单 只在选择模式出现，
            // 避免普通浏览时被一排危险批量按钮干扰（误点会触发整账号下载）。
            HStack(spacing: 10) {
                if selectionMode {
                    Button { selected = Set(filtered.map(\.screenName)) } label: {
                        Label(L("全选"), systemImage: "checkmark.circle")
                    }
                    .compatGlassButton()
                    Button {
                        let all = Set(filtered.map(\.screenName))
                        selected = all.subtracting(selected)
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
                        Label(addedToSync ? L("已加入同步清单") : L("加入同步清单"),
                              systemImage: addedToSync ? "checkmark" : "plus.circle")
                    }
                    .compatGlassButton()
                    .disabled(selected.isEmpty || addedToSync)
                    // 取消：退出选择模式（需求）
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            selectionMode = false
                            selected = []
                        }
                    } label: {
                        Label(L("取消"), systemImage: "xmark.circle")
                    }
                    .compatGlassButton()
                } else {
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { selectionMode = true }
                    } label: {
                        Label(L("选择"), systemImage: "checkmark.circle")
                    }
                    .compatGlassButton()
                }
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

    /// 网格单元。
    ///
    /// 两种模式（需求）：
    /// - **普通模式**：点头像/名字 = 跳到该用户的搜索页（`onSearchUser`）；
    /// - **选择模式**：点击 = 勾选/取消勾选，头像描边 + 角标表示选中。
    ///
    /// 名字按**昵称 / 用户名两行居中**（需求）：挤成一行 `名字-@用户名` 时
    /// 长昵称会被截断，两行各自居中更易读。
    private func followCell(_ user: TwitterUser) -> some View {
        let isSelected = selected.contains(user.screenName)
        return Button {
            if selectionMode {
                if isSelected { selected.remove(user.screenName) } else { selected.insert(user.screenName) }
            } else {
                // 非选择模式：跳转到该用户的搜索页
                onSearchUser?(user.screenName)
                dismiss()
            }
        } label: {
            VStack(spacing: 6) {
                CachedAvatarView(urlString: user.avatar, size: 64)
                    .overlay {
                        Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // 选择模式：已选角标（普通模式不显示，避免视觉噪声）
                        if selectionMode, isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, Color.accentColor)
                                .background(Circle().fill(.white).padding(2))
                        }
                    }
                // 两行居中：昵称一行、@用户名一行
                Text(user.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                Text("@\(user.screenName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
            .multilineTextAlignment(.center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .help(selectionMode ? L("点击选择") : L("点击进入该用户的搜索页"))
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
