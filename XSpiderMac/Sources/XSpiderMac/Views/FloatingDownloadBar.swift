import SwiftUI

/// 悬浮下载进度条：进行中 / 已完成 / 失败 三计数；出现与消失带过渡动画。
struct FloatingDownloadBar: View {
    @State private var store = DownloadStore.shared
    @State private var isExpanded = false
    @State private var visible = false

    private var activeTasks: [DownloadTask] {
        store.tasks.filter { [.waiting, .active, .paused].contains($0.status) }
    }

    private var completedCount: Int {
        store.tasks.filter { $0.status == .complete }.count
    }

    private var failedCount: Int {
        store.tasks.filter { $0.status == .error }.count
    }

    var body: some View {
        Group {
            if visible {
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
                                Text(L("暂无进行中任务"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text(summaryText)
                            .font(.caption)
                        Spacer()
                        Button(isExpanded ? L("收起") : L("展开")) { isExpanded.toggle() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(width: 280)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)).combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.35), value: visible)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .onChange(of: store.tasks.isEmpty) { _, empty in
            // 出现延迟一帧确保 transition 生效；消失延迟 1.5s 让用户看到完成状态
            if empty {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation { visible = false }
                }
            } else {
                withAnimation { visible = true }
            }
        }
        .onAppear {
            visible = !store.tasks.isEmpty
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        if !activeTasks.isEmpty {
            parts.append("\(activeTasks.count) " + L("进行中"))
        }
        if completedCount > 0 {
            parts.append("\(completedCount) " + L("已完成"))
        }
        if failedCount > 0 {
            parts.append("\(failedCount) " + L("失败"))
        }
        if parts.isEmpty {
            return L("暂无任务")
        }
        return parts.joined(separator: " · ")
    }

    private func progress(of task: DownloadTask) -> Double {
        guard task.totalSize > 0 else { return 0 }
        return Double(task.completeSize) / Double(task.totalSize)
    }
}

#Preview {
    FloatingDownloadBar()
}
