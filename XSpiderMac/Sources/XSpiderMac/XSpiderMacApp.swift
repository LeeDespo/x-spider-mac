import SwiftUI

@main
struct XSpiderMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
    }
}
