import SwiftUI

struct AboutView: View {
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

            VStack(alignment: .leading, spacing: 8) {
                Text("License: GPL-3.0-only")
                Text("Upstream: MiningCattiva/x-spider")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(20)
            .liquidGlass(cornerRadius: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("关于"))
    }
}

#Preview {
    AboutView()
}
