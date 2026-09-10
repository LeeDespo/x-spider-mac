import SwiftUI

struct FloatingDownloadBar: View {
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 8) {
            if isExpanded {
                Text("下载进度")
                    .font(.headline)
                ProgressView(value: 0.45)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            }

            HStack {
                Image(systemName: "arrow.down.circle")
                Text("3 / 12")
                Spacer()
                Button(isExpanded ? "收起" : "展开") { isExpanded.toggle() }
                    .buttonStyle(.glass)
            }
        }
        .padding()
        .frame(width: 260)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }
}

#Preview {
    FloatingDownloadBar()
}
