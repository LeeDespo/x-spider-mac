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

    // MARK: - 账号状态栏（边栏最底端，两行：X API / 媒体 CDN）

    /// 两行状态：上行 X GraphQL API（翻页、爬虫），下行媒体 CDN（图片视频下载）。
    /// 二者是不同域、不同配额，分开显示才能一眼看出是哪一侧出了问题。
    /// 状态全部**被动**采集（由真实请求遇阻推导），只有点重试才主动探测。
    private var accountStatusBar: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 12)

            VStack(spacing: 4) {
                statusRow(
                    label: L("X API"),
                    lamp: lampColor(for: statusStore.severity),
                    text: { statusStore.statusText },
                    help: statusStore.helpText,
                    isDim: statusStore.severity == .ok,
                    deadline: statusStore.breakerOpen ? statusStore.rateLimitDeadline : nil,
                    probing: statusStore.probing,
                    retry: { Task { await statusStore.probeAndRecover() } }
                )
                statusRow(
                    label: L("媒体 CDN"),
                    lamp: statusStore.cdnThrottled ? .red : (statusStore.cdnStatusText == nil ? .green : .orange),
                    text: { statusStore.cdnStatusText ?? L("下载正常") },
                    help: statusStore.cdnHelpText,
                    isDim: statusStore.cdnStatusText == nil,
                    deadline: statusStore.cdnRateLimitedUntil,
                    probing: statusStore.probingCDN,
                    retry: { Task { await statusStore.probeCDN() } }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
    }

    /// 单行状态：灯 + 标签 + 文案 + 重试
    private func statusRow(
        label: String,
        lamp: Color,
        text: @escaping () -> String,
        help: String,
        isDim: Bool,
        deadline: Date?,
        probing: Bool,
        retry: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(lamp)
                .frame(width: 7, height: 7)
                .overlay { Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1) }

            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            statusText(text, deadline: deadline)
                .font(.caption2)
                .foregroundStyle(isDim ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help)

            Spacer(minLength: 2)

            Button(action: retry) {
                if probing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(probing)
            .help(L("重试：立即探测连接；若正在限流则同时结束限流"))
        }
    }

    /// 状态文案。有截止时间时用 TimelineView 每秒重算一次（**只驱动这一个文本**，
    /// 不重绘整棵侧边栏——文案里的倒计时由 store 按当前时间生成）；
    /// 无截止时间则普通 Text，零额外开销。
    @ViewBuilder
    private func statusText(_ text: @escaping () -> String, deadline: Date?) -> some View {
        if let deadline {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(text())
            }
            // 到期后把状态真正落回正常（一次性回调，不是轮询）
            .task(id: deadline) {
                let wait = deadline.timeIntervalSinceNow
                guard wait > 0 else {
                    statusStore.refreshExpiry()
                    statusStore.refreshCDNExpiry()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 200_000_000)
                guard !Task.isCancelled else { return }
                statusStore.refreshExpiry()
                statusStore.refreshCDNExpiry()
            }
        } else {
            Text(text())
        }
    }

    private func lampColor(for severity: AccountStatusStore.Severity) -> Color {
        switch severity {
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
