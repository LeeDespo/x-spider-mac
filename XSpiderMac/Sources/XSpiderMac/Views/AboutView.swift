import SwiftUI

struct AboutView: View {
    private let developerURL = URL(string: "https://github.com/LeeDespo")!
    private let projectURL = URL(string: "https://github.com/LeeDespo/x-spider-mac")!
    private let licenseURL = URL(string: "https://github.com/LeeDespo/x-spider-mac/blob/main/LICENSE")!
    private let upstreamURL = URL(string: "https://github.com/MiningCattiva/x-spider")!

    var body: some View {
        VStack(spacing: 20) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 128, height: 128)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 96))
                    .foregroundStyle(.secondary)
            }

            Text("X-Spider")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text(L("macOS 原生版 X 媒体下载器"))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                linkRow(L("开发者"), label: "LeeDespo", url: developerURL)
                linkRow(L("项目地址"), label: "LeeDespo/x-spider-mac", url: projectURL)
                linkRow(L("开源协议"), label: "GPL-3.0-only", url: licenseURL)
                Divider()
                // 鸣谢：X 爬虫核心方案来自上游项目
                linkRow(L("鸣谢") + " · " + L("上游项目"), label: "MiningCattiva/x-spider", url: upstreamURL)
                Text(L("X 的媒体解析与接口方案基于上游 x-spider（Electron 版）移植，感谢原作者。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(20)
            .liquidGlass(cornerRadius: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("关于"))
    }

    private func linkRow(_ title: String, label: String, url: URL) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Link(label, destination: url)
                .foregroundStyle(Color.accentColor)
            Image(systemName: "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

#Preview {
    AboutView()
}
