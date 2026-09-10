import SwiftUI

struct DownloadsView: View {
    var body: some View {
        VStack {
            if true {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Downloads")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No active downloads")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    DownloadsView()
}
