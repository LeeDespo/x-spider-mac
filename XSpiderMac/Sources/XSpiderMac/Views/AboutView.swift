import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)

            Text("X-Spider")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("macOS native port of x-spider")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("License: GPL-3.0-only")
                Text("Upstream: MiningCattiva/x-spider")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}

#Preview {
    AboutView()
}
