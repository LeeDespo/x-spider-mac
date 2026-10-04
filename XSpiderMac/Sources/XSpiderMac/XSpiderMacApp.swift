import SwiftUI

/// 退出时收尾：**先把组件优雅关停**（它会落盘下载记录、结束自己的 aria2 子进程），
/// 再让应用退出。
///
/// 为什么必须有这一步：组件是独立进程，`kill -9` 会跳过它的收尾——
/// 表现是"重启后未完成的任务没有恢复"，而那是很难归因的一类问题。
/// 关闭窗口不等于退出（macOS 习惯），所以这里用 `applicationShouldTerminate`
/// 返回 `.terminateLater`，等收尾完成再真正退出。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            // 下载历史是**节流**落盘的（见 `DownloadStore.markHistoryDirty`），
            // 退出前同步补一次，否则最近一秒内的状态变化会丢。
            await MainActor.run { DownloadStore.shared.flushHistoryNow() }
            await XSpiderComponent.shared.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 兜底：上面的异步收尾若已超时（组件不响应），这里同步再踢一脚
        if XSpiderComponent.shared.isRunning {
            AppLogger.info("退出时组件仍在运行，交给进程组清理", category: "CORE")
        }
    }
}

@main
struct XSpiderMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settingsStore = SettingsStore.shared
    @State private var appStore = AppStore.shared
    @State private var downloadStore = DownloadStore.shared
    @State private var syncStore = SyncStore.shared
    @State private var homepageStore = HomepageStore.shared

    init() {
        AppDirectories.ensureAll()
        // 启动即记录构建身份：排查"改动没生效"时，先看这条日志确认跑的是哪个二进制
        // （曾出现 Xcode 用 ~/Library/Developer/Xcode/DerivedData 的旧产物覆盖测试结论）
        let buildDate = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        AppLogger.info("应用启动", category: "APP", [
            "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?",
            "build": buildDate,
            "executablePath": Bundle.main.executablePath ?? "?",
        ])
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
        // 应用菜单：功能介绍 + 关于卡片(替换默认 About 链接)
            CommandGroup(replacing: .appInfo) {
                Button(L("关于 XSpiderMac")) {
                    NotificationCenter.default.post(name: .openAboutTab, object: nil)
                }
                Divider()
                Button(L("功能介绍")) {
                    NotificationCenter.default.post(name: .showFeatureIntro, object: nil)
                }
            }

        // 移除系统默认注入的菜单项（设置/服务/隐藏/窗口字母排序/编辑/新窗口等非用户指定项）
            CommandGroup(replacing: .appVisibility) {}
            CommandGroup(replacing: .appTermination) {}
            CommandGroup(replacing: .systemServices) {}
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .windowArrangement) {}
            CommandGroup(replacing: .windowList) {}
                                            } // commands
    }
}

/// 菜单栏动作通知
extension Notification.Name {
    static let showFeatureIntro = Notification.Name("showFeatureIntro")
    static let openAboutTab = Notification.Name("openAboutTab")
    static let openDownloadsTab = Notification.Name("menu.openDownloadsTab")
    static let focusSearchField = Notification.Name("menu.focusSearchField")
    static let openCookieImport = Notification.Name("menu.openCookieImport")
}
