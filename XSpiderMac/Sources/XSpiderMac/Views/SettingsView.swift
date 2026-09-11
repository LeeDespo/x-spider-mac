import SwiftUI

/// 设置页：下载（保存路径/账号子目录/文件名模板/跳过相同文件）+ 代理 + 外观（字体/语言）+ 日志 + 防休眠。
struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared
    @State private var exportMessage: String?
    @State private var showCleanupDialog = false

    var body: some View {
        Form {
            downloadSection
            homeSection
            proxySection
            appearanceSection
            privacySection
            powerSection
            logSection
            dataSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("设置"))
        .frame(minWidth: 620)
    }

    // MARK: - 下载设置

    private var downloadSection: some View {
        Section {
            // 下载引擎选择（aria2 多连接 / 内置 URLSession）
            Picker(L("下载引擎"), selection: Binding(
                get: { settingsStore.settings.download.engine },
                set: { settingsStore.settings.download.engine = $0 }
            )) {
                ForEach(DownloadEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            Text(L("aria2：多连接分块下载，大文件更快更稳（推荐）；内置引擎：系统原生 URLSession，单连接。切换引擎后新任务生效。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // 同时并发下载数
            Stepper(value: Binding(
                get: { settingsStore.settings.maxConcurrentDownloads },
                set: { settingsStore.settings.download.maxConcurrent = $0 }
            ), in: 1...20) {
                LabeledContent(L("同时下载文件数"), value: "\(settingsStore.settings.maxConcurrentDownloads)")
            }

            // 保存路径
            HStack {
                TextField(L("保存路径"), text: Binding(
                    get: { settingsStore.settings.download.saveDirBase },
                    set: { settingsStore.settings.download.saveDirBase = $0 }
                ))
                Button(L("选择…")) { selectSaveDir() }
                    .buttonStyle(.glass)
            }

            // 按账号建子目录（替代原"目录模板"）
            Toggle(L("按账号创建子文件夹"), isOn: Binding(
                get: { settingsStore.settings.accountSubfolderEnabled },
                set: { settingsStore.settings.download.accountSubfolder = $0 }
            ))
            if settingsStore.settings.accountSubfolderEnabled {
                Text(L("开启后，资源将保存到「保存路径/昵称-@用户名」文件夹中，如：") + "\(settingsStore.settings.download.saveDirBase)/abc-@123")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 文件名模板（单一输入 + 实时预览）
            TextField(L("文件名模板"), text: Binding(
                get: { settingsStore.settings.download.fileNameTemplate },
                set: { settingsStore.settings.download.fileNameTemplate = $0 }
            ))

            LabeledContent(L("预览")) {
                Text(FileNameTemplate.resolve(
                    template: settingsStore.settings.download.fileNameTemplate,
                    data: SettingsView.exampleTemplateData
                ))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            // 变量选择器（默认展开）
            TemplateVariablePicker()

            // 跳过相同文件
            Toggle(L("跳过已存在的相同文件"), isOn: Binding(
                get: { settingsStore.settings.download.sameFileSkip },
                set: { settingsStore.settings.download.sameFileSkip = $0 }
            ))
        } header: {
            Label(L("下载"), systemImage: "arrow.down.circle")
        }
    }

    // MARK: - 主页设置

    private var homeSection: some View {
        Section {
            Toggle(L("自动加载媒体"), isOn: Binding(
                get: { settingsStore.settings.autoLoadMediaEnabled },
                set: { settingsStore.settings.download.autoLoadMedia = $0 }
            ))
            Text(L("关闭后，主页仅显示用户信息与下载配置，需要时点击「加载媒体」手动加载，可显著节省流量。媒体网格始终使用缩略图展示，下载原图不受影响。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label(L("主页"), systemImage: "house")
        }
    }

    // MARK: - 隐私设置

    private var privacySection: some View {
        Section {
            Toggle(L("自动删除下载历史记录"), isOn: Binding(
                get: { settingsStore.settings.autoClearDownloadHistoryEnabled },
                set: { settingsStore.settings.app.autoClearDownloadHistory = $0 }
            ))
            Toggle(L("自动删除搜索记录"), isOn: Binding(
                get: { settingsStore.settings.autoClearSearchHistoryEnabled },
                set: { settingsStore.settings.app.autoClearSearchHistory = $0 }
            ))
            Text(L("开启后，每次离开对应页面时自动清空相应历史记录。仅删除记录，不删除已下载的文件。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label(L("隐私"), systemImage: "hand.raised")
        }
    }

    // MARK: - 代理设置

    private var proxySection: some View {
        Section {
            Toggle(L("启用代理"), isOn: Binding(
                get: { settingsStore.settings.proxy.enable },
                set: { settingsStore.settings.proxy.enable = $0 }
            ))

            if settingsStore.settings.proxy.enable {
                Toggle(L("使用系统代理"), isOn: Binding(
                    get: { settingsStore.settings.proxy.useSystem },
                    set: { settingsStore.settings.proxy.useSystem = $0 }
                ))

                if !settingsStore.settings.proxy.useSystem {
                    TextField(L("代理地址"), text: Binding(
                        get: { settingsStore.settings.proxy.url },
                        set: { settingsStore.settings.proxy.url = $0 }
                    ))
                }
            }
        } header: {
            Label(L("代理"), systemImage: "globe")
        }
    }

    // MARK: - 数据（清理）

    private var dataSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Button(L("清除所有应用数据…"), role: .destructive) { showCleanupDialog = true }
                    .buttonStyle(.glass)
                Text(L("应用数据统一存放在 Application Support/XSpiderMac、Caches/XSpiderMac 和 Logs/XSpiderMac，已下载的媒体文件不受影响。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label(L("数据"), systemImage: "externaldrive")
        }
        .confirmationDialog(
            L("确定清除所有应用数据？"),
            isPresented: $showCleanupDialog,
            titleVisibility: .visible
        ) {
            Button(L("删除并退出应用"), role: .destructive) {
                AppDirectories.cleanupAll()
                exit(0)
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(cleanupTargetsDescription)
        }
    }

    private var cleanupTargetsDescription: String {
        let lines = AppDirectories.cleanupTargets.map { "• \($0.label)：\($0.url.path)" }
        return L("将删除以下应用创建的目录（已下载的媒体文件不受影响）：\n") + lines.joined(separator: "\n")
    }

    // MARK: - 外观（字体大小 + 语言）

    private var appearanceSection: some View {
        Section {
            Picker(L("界面字体大小"), selection: Binding(
                get: { settingsStore.fontSize },
                set: { settingsStore.fontSize = $0 }
            )) {
                ForEach([12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0], id: \.self) { size in
                    Text("\(Int(size)) pt").tag(size)
                }
            }

            Picker(L("语言/Language"), selection: Binding(
                get: { settingsStore.language },
                set: { newLang in
                    guard newLang != settingsStore.language else { return }
                    settingsStore.language = newLang
                    restartDialogVisible = true
                }
            )) {
                ForEach(Settings.Language.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
        } header: {
            Label(L("外观"), systemImage: "textformat")
        }
        // 字号修改提示：字体环境在部分原生控件上需要重启才能完全生效
        .onChange(of: settingsStore.fontSize) { old, new in
            guard old != new else { return }
            restartDialogVisible = true
        }
        .confirmationDialog(
            L("需要重启应用才能完全生效"),
            isPresented: $restartDialogVisible,
            titleVisibility: .visible
        ) {
            Button(L("立刻重启"), role: .destructive) { restartApp() }
            Button(L("暂不重启")) { /* 保留设置，用户稍后自行重启 */ }
        } message: {
            Text(L("字号与语言修改已保存。部分界面元素将在重启后应用新设置。"))
        }
    }

    @State private var restartDialogVisible = false

    /// 重启应用：启动新进程后退出当前进程
    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = bundleURL.appendingPathComponent("Contents/MacOS/XSpiderMac")
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            AppLogger.error(L("重启失败，请手动退出并重新打开应用"), category: "APP", ["error": error.localizedDescription])
        }
    }

    // MARK: - 电源（防休眠）

    private var powerSection: some View {
        Section {
            Toggle(L("有下载任务时阻止系统休眠"), isOn: Binding(
                get: { settingsStore.settings.app.preventSleepDuringDownload },
                set: { settingsStore.settings.app.preventSleepDuringDownload = $0 }
            ))
            Text(L("使用系统电源断言机制，仅在下载进行期间保持唤醒，不会修改系统设置"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label(L("电源"), systemImage: "zzz")
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            Toggle(L("开启日志记录"), isOn: Binding(
                get: { settingsStore.settings.app.writeLogs },
                set: { settingsStore.settings.app.writeLogs = $0 }
            ))
            Text(L("日志记录网络请求、下载任务、错误等信息，用于问题排查"))
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent(L("日志位置")) {
                Text(AppLogger.currentLogFile.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button(L("在 Finder 中显示")) { showLogsInFinder() }
                    .buttonStyle(.glass)
                Button(L("导出日志…")) { exportLogs() }
                    .buttonStyle(.glass)
                Button(L("删除所有日志"), role: .destructive) { confirmDeleteLogs = true }
                    .buttonStyle(.glass)
                if AppLogger.logFileCount > 0 {
                    Text("\(AppLogger.logFileCount) " + L("个日志文件"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        } header: {
            Label(L("日志"), systemImage: "doc.text")
        }
        .confirmationDialog(
            L("确定删除所有日志文件？"),
            isPresented: $confirmDeleteLogs,
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) {
                AppLogger.deleteAllLogs()
                AppLogger.info("日志已全部删除", category: "APP")
                exportMessage = L("日志已全部删除")
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("此操作不可撤销，当前日志与历史轮转文件都会被删除。"))
        }
    }

    @State private var confirmDeleteLogs = false

    // MARK: - 辅助

    private func selectSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.download.saveDirBase = url.path
        }
    }

    private func showLogsInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppLogger.logDirectory.path)
    }

    private func exportLogs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let files = try AppLogger.exportLogs(to: url)
                exportMessage = files.isEmpty ? L("暂无日志文件可导出") : "已导出 \(files.count) 个文件到 \(url.path)"
            } catch {
                exportMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    /// 上游 EXAMPLE_USER / EXAMPLE_POST / EXAMPLE_MEDIA（示例数据，供模板预览）
    static let exampleTemplateData: FileNameTemplateData = {
        let user = TwitterUser(
            screenName: "userscreenname",
            avatar: "",
            name: L("这是用户昵称"),
            id: "1145141919",
            mediaCount: 8888,
            registerTime: nil
        )
        let post = TwitterPost(
            id: "1145141919810",
            user: user,
            createdAt: TwitterDate.parse("Sat Jan 20 15:15:36 +0000 2024"),
            fullText: L("这里是推文内容,这里是推文内容，这里是推文内容，这里是推文内容，这里是推文内容，这里是推文内容。"),
            tags: [L("标签1"), L("标签2")],
            views: 13496,
            lang: "ja",
            retweeted: false,
            retweetCount: 24,
            replyCount: 21,
            possiblySensitive: false,
            favorited: false,
            favoriteCount: 228,
            bookmarkCount: 1,
            bookmarked: false,
            medias: [
                TwitterMedia(
                    id: "1748695771262889984",
                    url: "https://pbs.twimg.com/media/GESdifpaMAA6rth.jpg",
                    width: 1323,
                    height: 1136,
                    type: .photo,
                    videoInfo: nil
                )
            ]
        )
        return FileNameTemplateData(post: post, media: post.medias![0])
    }()
}

// MARK: - 模板变量选择器（默认展开）

struct TemplateVariablePicker: View {
    @State private var copiedVariable: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("可用变量（点击复制）"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 6) {
                ForEach(FileNameTemplate.variableDescriptions, id: \.name) { variable in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("%\(variable.name)%", forType: .string)
                        copiedVariable = variable.name
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copiedVariable = nil
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("%\(variable.name)%")
                                    .font(.system(.caption, design: .monospaced))
                                if copiedVariable == variable.name {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(variable.desc)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(variable.params.isEmpty ? "" : "参数：\(variable.params.map { "\($0.name)：\($0.desc)（默认 \($0.defaultValue)）" }.joined(separator: "；"))")
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}
