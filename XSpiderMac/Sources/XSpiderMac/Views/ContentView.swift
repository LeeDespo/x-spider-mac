import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            Text("Select a destination")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
