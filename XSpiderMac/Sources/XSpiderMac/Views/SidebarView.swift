import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    @State private var showCookieSheet = false
    @State private var appStore = AppStore.shared
    private var account: TwitterAccountInfo? { appStore.account }
    @State private var avatarImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            accountCard
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            List(selection: $selection) {
                Section {
                    ForEach(NavigationItem.allCases) { item in
                        Label(navTitle(item), systemImage: item.icon)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer()
        }
        .frame(minWidth: 200, idealWidth: 220)
        .background(.clear)
        .sheet(isPresented: $showCookieSheet) {
            CookieLoginSheet()
        }
        .sheet(isPresented: $showFollowingList) {
            FollowingListSheet()
        }

    }

    private func navTitle(_ item: NavigationItem) -> String {
        switch item {
        case .home: return L("主页")
        case .sync: return L("同步")
        case .downloads: return L("下载管理")
        case .settings: return L("设置")
        case .about: return L("关于")
        }
    }

    // MARK: - 账户卡（上游 Account.tsx：头像 + 昵称 + screen_name，点击可登出）

    @State private var accountMenuVisible = false
    @State private var showFollowingList = false
    @State private var switchingAccount: SavedAccount?
    @State private var statusStore = AccountStatusStore.shared

    /// 账号/限流状态标签。被动采集：只在操作遇阻时出现，正常态整个视图不渲染。
    private func statusBadge(_ text: String) -> some View {
        let tint: Color = {
            switch statusStore.severity {
            case .critical: return .red
            case .warning: return .orange
            case .muted: return .secondary
            case .normal: return .secondary
            }
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
            .help(statusStore.helpText)
            // 登录失效 → 点击直接去导入 Cookie
            .onTapGesture {
                if statusStore.suggestsReLogin {
                    NotificationCenter.default.post(name: .openCookieImport, object: nil)
                }
            }
    }

    private var accountCard: some View {
        HStack(spacing: 12) {
            if let account {
                CachedAvatarView(urlString: account.avatar, size: 40)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let account {
                    Text(account.screenName)
                        .font(.headline)
                    Text("@\(account.screenName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("未登录"))
                        .font(.headline)
                    Text(L("点击导入 Cookie"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 被动状态标签：仅在真实操作遇阻时出现（正常态不渲染 → 无布局开销）
                if let badge = statusStore.badgeText {
                    statusBadge(badge)
                        // 限流有恢复期限：安排**一次**到期刷新（不是轮询）。
                        // 没有它，期间无新请求时标签会一直留着不消失。
                        .task(id: statusStore.rateLimitDeadline) {
                            guard let deadline = statusStore.rateLimitDeadline else { return }
                            let wait = deadline.timeIntervalSinceNow
                            guard wait > 0 else { return }
                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 200_000_000)
                            guard !Task.isCancelled else { return }
                            statusStore.refreshExpiry()
                        }
                }
            }

            Spacer()
        }
        .padding(12)
        .liquidGlass(cornerRadius: 16)
        .contentShape(Rectangle())
        .onTapGesture {
            if appStore.account == nil {
                showCookieSheet = true
            } else {
                accountMenuVisible = true
            }
        }
        // 已登录：点击弹菜单（已存账户列表 / 导入新账号 / 登出销毁）；未登录：点击导入 Cookie
        .popover(isPresented: $accountMenuVisible, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                // 1) 已登录过的账户（点击切换,cookie 保留切换不丢）
                let saved = appStore.savedAccounts
                if !saved.isEmpty {
                    Text(L("已登录的账户"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                    ForEach(saved) { acc in
                        Button {
                            accountMenuVisible = false
                            switchingAccount = acc
                        } label: {
                            HStack(spacing: 8) {
                                CachedAvatarView(urlString: acc.avatar, size: 22)
                                Text("@\(acc.screenName)")
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if acc.screenName == account?.screenName {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    Divider()
                }

                // 2) 导入/登录新账号（保留当前 cookie）
                Button {
                    accountMenuVisible = false
                    showCookieSheet = true
                } label: {
                    Label(L("添加账户"), systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                Divider()

                Divider()

                // 关注清单管理
                Button {
                    accountMenuVisible = false
                    showFollowingList = true
                } label: {
                    Label(L("关注清单"), systemImage: "person.2.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                Divider()

                // 3) 登出 = 销毁当前账户的 cookie
                Button(role: .destructive) {
                    accountMenuVisible = false
                    appStore.logout()
                } label: {
                    Label(L("登出"), systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .padding(.vertical, 6)
            .frame(width: 200)
        }
        // 切换账户确认(可能要重新验证)
        .confirmationDialog(
            L("切换到 @\(switchingAccount?.screenName ?? "")？"),
            isPresented: Binding(get: { switchingAccount != nil }, set: { if !$0 { switchingAccount = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("切换")) {
                if let target = switchingAccount {
                    Task {
                        try? await AppStore.shared.switchToAccount(target)
                    }
                }
                switchingAccount = nil
            }
            Button(L("取消"), role: .cancel) { switchingAccount = nil }
        } message: {
            Text(L("当前账户的 Cookie 会保留，可随时切回。"))
        }
    }
}

/// 远程头像加载（AsyncImage 在 macOS 26 的替代）
struct AccountAvatarView: View {
    let urlString: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
                    .task { await load() }
            }
        }
    }

    private func load() async {
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            image = NSImage(data: data)
        } catch {
            // 头像加载失败静默降级
        }
    }
}

#Preview {
    SidebarView(selection: .constant(.home))
}
