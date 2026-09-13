import SwiftUI

@main
struct XSpiderMacApp: App {
    @State private var settingsStore = SettingsStore.shared
    @State private var appStore = AppStore.shared
    @State private var downloadStore = DownloadStore.shared
    @State private var syncStore = SyncStore.shared
    @State private var homepageStore = HomepageStore.shared

    init() {
        AppDirectories.ensureAll()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                // 全局字号：SwiftUI 隐式 font 环境会级联到所有子视图文本
                .environment(\.font, Font.system(size: settingsStore.fontSize))
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        // ── 实用菜单栏（L() 动态翻译：语言切换立即生效）──
        .commands {
        CommandMenu(L("下载")) {
            Button(L("全部暂停")) {
                downloadStore.pauseAll()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(downloadStore.tasks.allSatisfy { $0.status != .active && $0.status != .waiting })

            Button(L("全部继续")) {
                downloadStore.unpauseAll()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(downloadStore.tasks.allSatisfy { $0.status != .paused })

            Divider()
            Button(L("开始同步")) {
                syncStore.startSync()
            }
            .disabled(syncStore.users.isEmpty || syncStore.phase == .syncing)

            Button(L("暂停同步")) {
                syncStore.interrupt()
            }
            .disabled(syncStore.phase != .syncing)
        }

        CommandMenu(L("视图")) {
            Button(L("增大字号")) {
                settingsStore.fontSize = min(24, settingsStore.fontSize + 1)
            }
            .keyboardShortcut("+", modifiers: .command)

            Button(L("减小字号")) {
                settingsStore.fontSize = max(11, settingsStore.fontSize - 1)
            }
            .keyboardShortcut("-", modifiers: .command)
        }

        CommandMenu(L("帮助")) {
            Button(L("打开日志文件夹")) {
                NSWorkspace.shared.open(AppDirectories.logs)
            }
            Button(L("打开数据文件夹")) {
                NSWorkspace.shared.open(AppDirectories.supportRoot)
            }
            Divider()
            Button(L("清空图片缓存")) {
                ImageCache.shared.clearAll()
            }
        }
        } // commands
    }
}

/// 菜单栏动作通知
extension Notification.Name {
    static let openDownloadsTab = Notification.Name("menu.openDownloadsTab")
    static let focusSearchField = Notification.Name("menu.focusSearchField")
    static let openCookieImport = Notification.Name("menu.openCookieImport")
}
