import SwiftUI

struct SidebarView: View {
    var body: some View {
        List {
            Label("Home", systemImage: "photo.on.rectangle.angled")
            Label("Downloads", systemImage: "arrow.down.circle")
            Label("Settings", systemImage: "gear")
            Label("About", systemImage: "info.circle")
        }
        .navigationTitle("X-Spider")
    }
}

#Preview {
    SidebarView()
}
