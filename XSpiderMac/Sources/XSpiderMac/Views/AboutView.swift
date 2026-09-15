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

            // 项目信息：开发 → 项目 → 上游 → 开源协议（自上而下）
            VStack(alignment: .leading, spacing: 10) {
                labeledRow(L("开发"), "LeeDespo", url: developerURL)
                labeledRow(L("项目"), "LeeDespo/x-spider-mac", url: projectURL)
                labeledRow(L("上游"), "MiningCattiva/x-spider", url: upstreamURL)
                labeledRow(L("开源协议"), "GPL-3.0-only", url: licenseURL)
            }
            .font(.callout)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .liquidGlass(cornerRadius: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("关于"))
    }

    private func labeledRow(_ title: String, _ label: String, url: URL) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
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
