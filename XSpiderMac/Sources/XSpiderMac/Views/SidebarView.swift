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

            Spacer(minLength: 0)

            // 边栏最底端：账号状态栏（状态灯 + 文案 + 重试）
            accountStatusBar
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

    // MARK: - 账号状态栏（边栏最底端）

    /// 状态灯 + 文案 + 「重试」按钮。
    /// 状态是**被动**采集的（由真实请求遇阻推导），只有点重试才主动探测一次。
    private var accountStatusBar: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                statusLamp

                statusLabel

                Spacer(minLength: 4)

                Button {
                    Task { await statusStore.probeAndRecover() }
                } label: {
                    if statusStore.probing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(statusStore.probing)
                .help(L("重试：立即探测与 X 的连接；若正在熔断则同时结束熔断"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
    }

    /// 状态文案。熔断中需要每秒刷新倒计时——用 TimelineView **只驱动这一个文本**，
    /// 不重绘整棵侧边栏；非熔断态走普通 Text，零额外开销。
    @ViewBuilder
    private var statusLabel: some View {
        let base = Text(statusStore.statusText)
            .font(.caption)
            .foregroundStyle(statusStore.severity == .ok ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(statusStore.helpText)

        if statusStore.breakerOpen, statusStore.rateLimitDeadline != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                base
            }
            // 倒计时归零后把状态真正落回正常（一次性，不是轮询）
            .task(id: statusStore.rateLimitDeadline) {
                guard let deadline = statusStore.rateLimitDeadline else { return }
                let wait = deadline.timeIntervalSinceNow
                guard wait > 0 else { statusStore.refreshExpiry(); return }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 200_000_000)
                guard !Task.isCancelled else { return }
                statusStore.refreshExpiry()
            }
        } else {
            base
        }
    }

    /// 状态灯：绿灯正常 / 红灯限流 / 橙灯其它异常
    private var statusLamp: some View {
        Circle()
            .fill(lampColor)
            .frame(width: 8, height: 8)
            .overlay {
                Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1)
            }
    }

    private var lampColor: Color {
        switch statusStore.severity {
        case .ok: return .green
        case .critical: return .red
        case .warning: return .orange
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
