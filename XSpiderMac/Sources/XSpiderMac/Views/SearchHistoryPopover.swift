import SwiftUI

/// 搜索历史弹窗：与下载管理的用户筛选弹窗同款交互。
/// 用户条目 = 头像 + keyword；推文条目 = 缩略图（多图堆叠）+ "昵称 @user"。
/// 每条右侧有单条删除按钮；底部清空全部。
struct SearchHistoryPopover: View {
    @Bindable var appStore: AppStore
    var onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("搜索历史"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if appStore.searchHistory.isEmpty {
                Text(L("暂无搜索历史"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(appStore.searchHistory) { item in
                            row(item)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            }

            Divider()

            HStack {
                Spacer()
                Button(L("清空历史"), role: .destructive) {
                    withAnimation(.spring(duration: 0.25)) {
                        appStore.clearSearchHistory()
                    }
                }
                .font(.callout)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private func row(_ item: SearchHistoryItem) -> some View {
        HStack(spacing: 10) {
            thumbnailStack(for: item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind == .tweet ? (item.displayName ?? L("推文") + " \(item.keyword)") : item.keyword)
                    .font(.body.weight(item.kind == .tweet ? .bold : .regular))
                    .lineLimit(1)
                if item.kind == .tweet {
                    Text(L("推文") + " · \(item.keyword)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                withAnimation(.spring(duration: 0.22)) {
                    appStore.removeSearchHistory(keyword: item.keyword)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("删除该条记录"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onSubmit(item.keyword)
        }
    }

    /// 32pt 图标：用户 = 头像；推文 = 单图或多图堆叠（与账户头像同尺寸）
    @ViewBuilder
    private func thumbnailStack(for item: SearchHistoryItem) -> some View {
        if item.kind == .user {
            CachedAvatarView(urlString: item.imageURL, size: 32)
        } else {
            ZStack {
                if let extra = item.extraImageURLs, !extra.isEmpty {
                    ForEach(Array(extra.enumerated().reversed()), id: \.offset) { _, urlString in
                        CachedAvatarView(urlString: urlString, size: 32)
                            .rotationEffect(.degrees(0))
                            .offset(x: 3, y: -3)
                    }
                }
                CachedAvatarView(urlString: item.imageURL, size: 32)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.background, lineWidth: 1)
                    }
            }
            .overlay(alignment: .bottomTrailing) {
                if (item.extraImageURLs?.count ?? 0) > 0 {
                    Text("+\(1 + (item.extraImageURLs?.count ?? 0))")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(.black.opacity(0.6), in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
        }
    }
}

/// 走 ImageCache 的圆头像/缩略图（替代 AccountAvatarView 的直连版本）
struct CachedAvatarView: View {
    let urlString: String?
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
            }
        }
        .task(id: urlString) {
            guard let urlString else { return }
            image = await ImageCache.shared.image(for: urlString, category: .avatars)
        }
    }
}
