import SwiftUI

/// 悬浮下载进度条：实时数据（替换之前的硬编码 3/12）。
struct FloatingDownloadBar: View {
    @State private var store = DownloadStore.shared
    @State private var isExpanded = false

    private var activeTasks: [DownloadTask] {
        store.tasks.filter { [.waiting, .active, .paused].contains($0.status) }
    }

    private var completedCount: Int {
        store.tasks.filter { $0.status == .complete }.count
    }

    var body: some View {
        Group {
            if !store.tasks.isEmpty {
                VStack(spacing: 8) {
                    if isExpanded {
                        VStack(spacing: 6) {
                            ForEach(activeTasks.prefix(5)) { task in
                                HStack {
                                    Text(task.fileName)
                                        .lineLimit(1)
                                        .font(.caption)
                                    Spacer()
                                    Text("\(Int(progress(of: task) * 100))%")
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                                ProgressView(value: progress(of: task))
                                    .progressViewStyle(.linear)
                                    .controlSize(.small)
                            }
                            if activeTasks.isEmpty {
                                Text("暂无进行中任务")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("\(activeTasks.count) 进行中 · \(completedCount) 已完成")
                            .font(.caption)
                        Spacer()
                        Button(isExpanded ? "收起" : "展开") { isExpanded.toggle() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(width: 280)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private func progress(of task: DownloadTask) -> Double {
        guard task.totalSize > 0 else { return 0 }
        return Double(task.completeSize) / Double(task.totalSize)
    }
}

#Preview {
    FloatingDownloadBar()
}
