import SwiftUI

/// 选择性下载弹窗：勾选需要下载的媒体（默认全选当前列表），确认后批量创建任务。
/// 支持「全选 / 全不选」与按媒体类型快速筛选。
struct SelectiveDownloadSheet: View {
    let store: HomepageStore
    let filter: DownloadFilter
    @Environment(\.dismiss) private var dismiss

    /// 可选项：当前列表按 filter 类型过滤后的媒体
    private var items: [(post: TwitterPost, media: TwitterMedia, index: Int)] {
        store.flatMediaList.filter { item in
            filter.mediaTypes?.contains(item.media.type) ?? true
        }
    }

    /// 勾选状态：媒体 id → 是否选中
    @State private var selected: [String: Bool] = [:]
    @State private var created = false

    private var selectedCount: Int {
        items.filter { selected[$0.media.id ?? ""] ?? true }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(L("选择下载"))
                    .font(.headline)
                Text(L("已选 \(selectedCount) / \(items.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("全选")) { selectAll(true) }.compatGlassButton()
                Button(L("全不选")) { selectAll(false) }.compatGlassButton()
            }
            .padding(16)

            Divider()

            // 媒体清单
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items, id: \.media.id) { item in
                        row(for: item)
                    }
                    if items.isEmpty {
                        Text(L("当前列表没有可选媒体"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(minHeight: 260, maxHeight: 420)

            Divider()

            // 底部操作
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }
                Button {
                    createTasks()
                } label: {
                    if created {
                        Label(L("已创建任务"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(L("下载所选 (\(selectedCount))"))
                    }
                }
                .disabled(selectedCount == 0 || created)
                .compatGlassProminentButton()
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    private func row(for item: (post: TwitterPost, media: TwitterMedia, index: Int)) -> some View {
        let id = item.media.id ?? ""
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                selected[id] = !(selected[id] ?? true)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected[id] ?? true ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected[id] ?? true ? Color.accentColor : .secondary)
                Text("#\(item.index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                Text(item.media.type.displayName)
                    .font(.caption)
                    .frame(width: 34, alignment: .leading)
                Text(item.post.fullText ?? L("(无文字)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let created = item.media.createdTime {
                    Text(created.formatted(date: .numeric, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectAll(_ value: Bool) {
        withAnimation(.easeOut(duration: 0.15)) {
            for item in items {
                selected[item.media.id ?? ""] = value
            }
        }
    }

    private func createTasks() {
        let targets = items.filter { selected[$0.media.id ?? ""] ?? true }
        Task {
            for item in targets {
                await DownloadStore.shared.createDownloadTask(post: item.post, media: item.media)
            }
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { created = true }
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        }
    }
}
