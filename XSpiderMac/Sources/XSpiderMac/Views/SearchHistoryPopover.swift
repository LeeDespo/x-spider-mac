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
                if item.kind == .tweet {
                    // 推文：主文 = 推文 id；小字 = 发布者昵称 @用户名
                    Text(item.keyword)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if let author = item.displayName {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    // 用户：主文 = 昵称；小字 = @用户名
                    Text(item.displayName ?? item.keyword)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if item.displayName != nil {
                        Text("@\(item.keyword)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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

    /// 32pt 图标：用户 = 圆头像；推文 = 自适应矩形缩略图（多图计数徽标）
    @ViewBuilder
    private func thumbnailStack(for item: SearchHistoryItem) -> some View {
        if item.kind == .user {
            CachedAvatarView(urlString: item.imageURL, size: 32)
        } else {
            CachedMediaThumbView(urlString: item.imageURL, width: 44, height: 32, cornerRadius: 6)
                .overlay(alignment: .bottomTrailing) {
                    if (item.extraImageURLs?.count ?? 0) > 0 {
                        Text("×\(1 + (item.extraImageURLs?.count ?? 0))")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.6), in: Capsule())
                            .offset(x: 4, y: 4)
                    }
                }
        }
    }
}

/// 矩形媒体缩略图（推文历史用）：aspectRatio .fill + 圆角矩形裁剪
struct CachedMediaThumbView: View {
    let urlString: String?
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: width, height: height)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: urlString) {
            guard let urlString else { return }
            image = await ImageCache.shared.image(for: urlString, category: .mediaThumbnails)
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
