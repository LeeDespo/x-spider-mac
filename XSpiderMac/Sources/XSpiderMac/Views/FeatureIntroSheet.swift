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
                    icon: "magnifyingglass.circle.fill",
                    tint: .accentColor,
                    title: L("搜索与浏览"),
                    lines: [
                        L("在主页搜索框输入用户 @用户名 或推文链接。"),
                        L("网格展示媒体；双击任意媒体卡片可查看推文详情：左侧切换高清图或播放视频，右侧浏览正文与评论。"),
                        L("下载配置可按日期范围、媒体类型、数据源筛选；「选择下载」可勾选部分媒体单独下载。"),
                    ]
                )
                .tag(0)

                introPage(
                    icon: "arrow.down.circle.fill",
                    tint: .green,
                    title: L("下载与同步"),
                    lines: [
                        L("下载引擎可选内置引擎或 aria2Next（多连接，大文件更快更稳）。"),
                        L("同步页把关注用户排成队列，逐个同步其媒体时间线；仿 Dock 布局或蜂窝布局可在设置中切换。"),
                        L("重复判定支持按文件名或按记录文件，避免重复下载。"),
                    ]
                )
                .tag(1)

                introPage(
                    icon: "gearshape.circle.fill",
                    tint: .orange,
                    title: L("设置与个性化"),
                    lines: [
                        L("设置 - 外观：液态玻璃、字号、语言即时生效。"),
                        L("设置 - 代理：支持系统代理或手动代理（含身份验证）。"),
                        L("设置 - 隐私：自动清除搜索/下载历史。"),
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
