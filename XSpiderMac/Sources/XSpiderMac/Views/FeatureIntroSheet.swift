import SwiftUI

/// 功能介绍弹窗（单页:大标题 + 三个小节)。
/// 首次启动自动弹出;菜单「功能介绍」可再次打开。
struct FeatureIntroSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Text(L("欢迎使用"))
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 34)

                introSection(icon: "house.fill", tint: .accentColor,
                             title: L("主页")) {
                    Text(L("搜索用户浏览媒体网格，或直接看推荐/关注时间线。点击媒体打开推文详情：左滑右滑切换媒体、点赞、书签、下载。"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                introSection(icon: "arrow.down.circle.fill", tint: .green,
                             title: L("下载")) {
                    Text(L("配置日期范围、媒体类型与数据源后开始下载；引擎可选 aria2Next（多连接更稳更快）。重复判定避免重复下载，记录可随时管理。"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                introSection(icon: "person.2.fill", tint: .orange,
                             title: L("同步")) {
                    Text(L("把关注的用户加入同步清单，一键逐个同步最新媒体;支持蜂窝/Dock 两种布局,同步记录文件可加快二次同步。"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 8)

                HStack {
                    Spacer()
                    Button(L("开始使用")) { dismiss() }
                        .compatGlassProminentButton()
                        .controlSize(.large)
                    Spacer()
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 34)
        }
        .frame(width: 520)
        .background(.regularMaterial)
    }

    private func introSection<Content: View>(icon: String, tint: Color, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.title3)
                Text(title)
                    .font(.headline)
            }
            content()
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
