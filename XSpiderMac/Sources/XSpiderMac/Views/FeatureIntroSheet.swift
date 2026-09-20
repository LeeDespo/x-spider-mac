import SwiftUI

/// 功能介绍弹窗（单页:大标题 + 三个小节)。
/// 首次启动自动弹出;菜单「功能介绍」可再次打开。
///
/// 三个小节对应应用的三个主要页面（需求：同样是介绍三个页面的功能）：
/// **主页 / 下载管理 / 同步**。文案按"用户第一次打开会想知道什么"来写：
/// 每个页面能做什么、怎么用、有哪些容易忽略的能力。
struct FeatureIntroSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                Text(L("欢迎使用"))
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 30)

                introSection(icon: "house.fill", tint: .accentColor,
                             title: L("主页：浏览与搜索")) {
                    Text(L("搜索用户名或直接粘贴推文链接，查看 TA 的媒体时间线或推文时间线。\n可先用日期范围与媒体类型筛出想看的内容——浏览走 X 的搜索接口，加载更快。\n\n主页时间线支持「推文 / 媒体」两种形态：推文看内容，媒体是瀑布流。点击任意媒体可打开详情，也能用放大镜在独立窗口里缩放、旋转、全屏播放。"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                introSection(icon: "arrow.down.circle.fill", tint: .green,
                             title: L("下载管理：批量保存媒体")) {
                    Text(L("两种下载方式，按需要选：\n· 看中哪张点哪张——媒体卡上的下载按钮；\n· 想全都要——「选择下载」里点「全选」再「下载所选」。\n\n「下载所选」由内置爬虫逐页翻完该账号，因此比页面看到的更全；已下载过的会自动跳过，不会重复下载。\n日期范围、媒体类型、文件名模板都可在设置里调整。"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                introSection(icon: "person.2.fill", tint: .orange,
                             title: L("同步：跟进关注的人")) {
                    Text(L("把关注的用户加入同步清单，一键检查并补齐他们新发的媒体。\n同步会记录已处理到的位置，之后每次只查更新的部分，因此二次同步快得多。\n\n在关注清单里点「选择」，还能批量把多个账号一次性加入同步清单。"))
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
        .frame(width: 560)
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
