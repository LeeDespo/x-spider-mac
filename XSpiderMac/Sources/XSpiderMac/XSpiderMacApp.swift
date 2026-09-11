import SwiftUI

@main
struct XSpiderMacApp: App {
    @State private var settingsStore = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                // 全局字号：SwiftUI 隐式 font 环境会级联到所有子视图文本
                .environment(\.font, Font.system(size: settingsStore.fontSize))
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
    }
}
