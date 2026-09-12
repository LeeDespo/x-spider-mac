import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    @State private var showCookieSheet = false
    @State private var account: TwitterAccountInfo?
    @State private var avatarImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            accountCard
                .onTapGesture {
                    if AppStore.shared.account == nil {
                        showCookieSheet = true
                    }
                }
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

            Spacer()
        }
        .frame(minWidth: 200, idealWidth: 220)
        .background(.clear)
        .sheet(isPresented: $showCookieSheet) {
            CookieImportView(isPresented: $showCookieSheet)
        }
        .onAppear {
            account = AppStore.shared.account
        }
        .onChange(of: AppStore.shared.account) { _, newAccount in
            account = newAccount
        }
        .overlay {
            if let account {
                logoutOverlay(account)
            }
        }
    }

    private func navTitle(_ item: NavigationItem) -> String {
        switch item {
        case .home: return L("主页")
        case .downloads: return L("下载管理")
        case .settings: return L("设置")
        case .about: return L("关于")
        }
    }

    // MARK: - 账户卡（上游 Account.tsx：头像 + 昵称 + screen_name，点击可登出）

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
    }

    private func logoutOverlay(_ account: TwitterAccountInfo) -> some View {
        // 只放一个按钮（底部右侧），不做全屏覆盖层——
        // 之前的全屏 overlay + allowsHitTesting(true) 会拦截 List 的点击，导致侧边栏无法切换
        Button {
            AppStore.shared.logout()
            self.account = nil
        } label: {
            Label(L("登出"), systemImage: "rectangle.portrait.and.arrow.right")
        }
        .compatGlassButton()
        .padding(.trailing, 12)
        .padding(.bottom, 24)
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
