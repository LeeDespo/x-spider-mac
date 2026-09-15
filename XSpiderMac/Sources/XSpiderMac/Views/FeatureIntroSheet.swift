import SwiftUI

/// 功能介绍弹窗（Apple 官方 onboarding 样式：页面圆点 + 上次页「开始使用」）。
/// 首次启动自动弹出；「帮助 → 功能介绍」菜单可再次打开。
struct FeatureIntroSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                introPage(
                    icon: "house.circle.fill",
                    tint: .accentColor,
                    title: L("主页"),
                    lines: [
                        L("搜索用户浏览其媒体，或在下载配置中按日期、类型筛选后开始下载。"),
                        L("「选择下载」可勾选部分媒体单独下载。"),
                    ]
                )
                .tag(0)

                introPage(
                    icon: "arrow.down.circle.fill",
                    tint: .green,
                    title: L("下载"),
                    lines: [
                        L("下载页管理任务进度、历史与失败重试。"),
                        L("引擎可选内置引擎或 aria2Next（多连接，大文件更快更稳）。"),
                    ]
                )
                .tag(1)

                introPage(
                    icon: "arrow.triangle.2.circlepath.circle.fill",
                    tint: .orange,
                    title: L("同步"),
                    lines: [
                        L("同步页把清单里的用户逐个同步最新媒体，仿 Dock 与蜂窝布局可切换。"),
                        L("判定依据建议保持「按同步记录文件」，只检索新内容，速度更快。"),
                    ]
                )
                .tag(2)
            }
            .frame(height: 380)

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { idx in
                    Circle()
                        .fill(idx == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .animation(.easeInOut(duration: 0.2), value: page)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)

            Divider()

            HStack {
                Spacer()
                if page < 2 {
                    Button(L("跳过")) { dismiss() }
                    Button(L("下一步")) {
                        withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                    }
                    .compatGlassProminentButton()
                } else {
                    Button(L("开始使用")) { dismiss() }
                        .compatGlassProminentButton()
                }
            }
            .padding(16)
        }
        .frame(width: 480)
        .background(.regularMaterial)
    }

    private func introPage(icon: String, tint: Color, title: String, lines: [String]) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(tint)
                .padding(.top, 34)

            Text(title)
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(tint).frame(width: 5, height: 5).padding(.top, 6)
                        Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 34)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
