import SwiftUI

/// 设置页：下载（保存路径/账号子目录/文件名模板/跳过相同文件）+ 代理 + 外观（字体/语言）+ 日志 + 防休眠。
struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared
    @State private var statusStore = AccountStatusStore.shared
    @State private var exportMessage: String?
    @State private var showCleanupDialog = false
    /// 同步清单管理弹窗
    @State private var showSyncListManager = false

    var body: some View {
        Form {
            engineSection
            downloadSection
            homeSection
            translationSection
            rateLimitSection
            proxySection
            uiSection
            appearanceSection
            privacySection
            powerSection
            logSection
            syncSection
            cacheSection
            dataSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.clear)
        .navigationTitle(L("设置"))
        .frame(minWidth: 620)
        // 底部留白：悬浮下载提示框可能遮挡最后一个设置项
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 72)
        }
    }

    // MARK: - 下载设置

    private var downloadSection: some View {
        Section {
            // 保存路径
            HStack {
                TextField(L("保存路径"), text: Binding(
                    get: { settingsStore.settings.download.saveDirBase },
                    set: {
                        settingsStore.settings.download.saveDirBase = $0
                        DownloadStore.shared.refreshDownloadedCaches()
                    }
                ))
                Button(L("选择…")) { selectSaveDir() }
                    .compatGlassButton()
            }

            // 按账号建子目录（替代原"目录模板"）
            Toggle(isOn: Binding(
                get: { settingsStore.settings.accountSubfolderEnabled },
                set: {
                    settingsStore.settings.download.accountSubfolder = $0
                    DownloadStore.shared.refreshDownloadedCaches()
                }
            )) {
                HStack(spacing: 6) {
                    Text(L("按账号创建子文件夹"))
                    InfoHint(text: L("开启后，资源将保存到「保存路径/昵称-@用户名」文件夹中。"))
                }
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
                .textSelection(.enabled)
            }

            // 变量选择器（默认展开）
            TemplateVariablePicker()

            // 跳过相同文件
            Toggle(L("跳过已存在的相同文件"), isOn: Binding(
                get: { settingsStore.settings.download.sameFileSkip },
                set: { settingsStore.settings.download.sameFileSkip = $0 }
            ))

            // 判定依据（跳过相同文件的子选项，类似代理的"手动/系统"联动）
            if settingsStore.settings.download.sameFileSkip {
                Picker(L("判定依据"), selection: Binding(
                    get: { settingsStore.settings.sameFileCheckModeValue },
                    set: { settingsStore.settings.download.sameFileCheckMode = $0.rawValue }
                )) {
                    ForEach(SameFileCheckMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 16)
                .infoHint(L("按文件名：下载时在文件名末尾追加资源索引（如「… 2.jpg」），判定即查找该文件是否存在。改名或移动文件后会被视为未下载。\n按下载记录文件：在保存路径维护 .downloaded.json，记录已下载媒体的资源索引；只查记录、不回查文件，因此改文件名模板、重命名或移动文件都不会让记录失效。"))
            }
        } header: {
            Label(L("下载"), systemImage: "arrow.down.circle")
        }
    }

    // MARK: - 引擎设置

    private var engineSection: some View {
        Section {
            // 下载引擎选择
            Picker(L("下载引擎"), selection: Binding(
                get: { settingsStore.settings.engineMode },
                set: { settingsStore.settings.download.engine = $0 }
            )) {
                ForEach(DownloadEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .infoHint(L("自动：按文件大小选择引擎——小于阈值用内置（省开销），大于阈值用 aria2Next（多连接更快更稳）。\naria2Next：全部走 aria2Next。\n内置引擎：系统原生 URLSession，单连接。"))

            // 自动模式的阈值
            if settingsStore.settings.engineMode == .auto {
                NumberStepperField(
                    title: L("超过此大小用 aria2Next (MB)"),
                    value: Binding(
                        get: { settingsStore.settings.aria2SizeThresholdMB },
                        set: { settingsStore.settings.download.aria2SizeThresholdMB = $0 }
                    ),
                    range: 1...2048
                )
                Text(L("大小未知时按媒体类型估算：视频与 GIF 走 aria2Next，图片走内置。")
                     + L("（不会为探测大小额外请求服务器）"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if settingsStore.settings.engineMode != .builtIn {
                // aria2 RPC 端口策略
                Picker(L("aria2 端口"), selection: Binding(
                    get: { settingsStore.settings.aria2PortMode },
                    set: { settingsStore.settings.download.aria2PortMode = $0.rawValue }
                )) {
                    ForEach(Aria2PortMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .infoHint(L("固定端口默认 6801，可与其它 aria2 软件共用；若端口被占用会启动失败。\n随机端口每次启动自动选一个空闲端口，适合同时装了其它 aria2 工具的情况。"))

                if settingsStore.settings.aria2PortMode == .fixed {
                    NumberStepperField(
                        title: L("端口号"),
                        value: Binding(
                            get: { settingsStore.settings.aria2Port },
                            set: { settingsStore.settings.download.aria2Port = $0 }
                        ),
                        range: 1024...65535
                    )
                }
            }

            if settingsStore.settings.engineMode != .builtIn {
                HStack {
                    // 连接状态：内核可执行文件在 + 可执行 = 绿灯
                    Circle()
                        .fill(Aria2Engine.isAvailable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(Aria2Engine.isAvailable ? L("aria2Next 连接正常") : L("aria2Next 内核未找到"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("重启内核")) {
                        Aria2Engine.shared.restart()
                    }
                    .compatGlassButton()
                }
                .padding(.leading, 16)
            }

            // 同时并发下载数（− 数字 +，数字可点击输入）
            NumberStepperField(
                title: L("同时下载文件数"),
                value: Binding(
                    get: { settingsStore.settings.maxConcurrentDownloads },
                    set: { settingsStore.settings.download.maxConcurrent = $0 }
                ),
                range: 1...20
            )

            // aria2 专属参数
            if settingsStore.settings.engineMode != .builtIn {
                NumberStepperField(
                    title: L("单文件最大连接数"),
                    value: Binding(
                        get: { settingsStore.settings.aria2Split },
                        set: { settingsStore.settings.download.aria2Split = $0 }
                    ),
                    range: 1...256
                )
                .infoHint(L("单个文件的最大连接数（aria2Next 的 stream-max-connections，默认 6）。\naria2Next 会先确认服务器支持分块，再对小文件自动降低实际连接数，\n因此调大不一定更快；服务器不支持分块时始终单连接。"))
                // 说明：旧的「最小分块大小」（--min-split-size）已从 aria2Next 退役
                // 并被引擎完全接管，故不再提供该项（保留只会是"改了没效果"的死设置）。
                Picker(L("文件分配方式"), selection: Binding(
                    get: { settingsStore.settings.aria2FileAllocation },
                    set: { settingsStore.settings.download.aria2FileAllocation = $0 }
                )) {
                    Text(L("预分配（推荐 HDD）")).tag("prealloc")
                    Text(L("快速分配（推荐 SSD）")).tag("falloc")
                    Text(L("不分配")).tag("none")
                }
            }
        } header: {
            Label(L("引擎"), systemImage: "cpu")
        }
    }

    // MARK: - 限流缓解

    /// 限流缓解：分两组——X API（GraphQL，管翻页/爬虫）与媒体 CDN（管图片视频下载）。
    /// 二者是不同域、不同配额，所以各自独立配置。
    private var rateLimitSection: some View {
        Section {
            Text(L("X API（翻页、爬取）"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(isOn: Binding(
                get: { settingsStore.settings.gateEnabled },
                set: { settingsStore.settings.app.rateLimit?.gateEnabled = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("请求闸门"))
                    InfoHint(text: L("开启后，所有对 X 的请求按类别排队并限速，避免短时间集中访问触发限流。\n关闭后请求不做节流（不推荐）。"))
                }
            }

            if settingsStore.settings.gateEnabled {
                NumberStepperField(
                    title: L("每时间窗请求数"),
                    value: Binding(
                        get: { settingsStore.settings.gateRequestsPerWindow },
                        set: { settingsStore.settings.app.rateLimit?.requestsPerWindow = $0 }
                    ),
                    range: 1...600
                )
                NumberStepperField(
                    title: L("时间窗（秒）"),
                    value: Binding(
                        get: { settingsStore.settings.gateWindowSeconds },
                        set: { settingsStore.settings.app.rateLimit?.windowSeconds = $0 }
                    ),
                    range: 1...300
                )
                Text(L("当前速率：约每 \(settingsStore.settings.gateWindowSeconds) 秒 \(settingsStore.settings.gateRequestsPerWindow) 个请求"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Toggle(isOn: Binding(
                    get: { settingsStore.settings.serializePerEndpoint },
                    set: { settingsStore.settings.app.rateLimit?.serializePerEndpoint = $0 }
                )) {
                    HStack(spacing: 6) {
                        Text(L("同类请求串行"))
                        InfoHint(text: L("同一类请求（如时间线）上一次返回前不发下一个，消除并发尖峰。建议保持开启。"))
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { settingsStore.settings.breakerEnabled },
                set: { settingsStore.settings.app.rateLimit?.breakerEnabled = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("触发限流后自动暂停"))
                    InfoHint(text: L("检测到 429 限流时，自动暂停该类请求一段时间，避免持续访问让限流加重。\n暂停期间不会发起新请求，到期自动恢复；也可在下方立即恢复。"))
                }
            }

            if settingsStore.settings.breakerEnabled {
                NumberStepperField(
                    title: L("暂停时长（秒）"),
                    value: Binding(
                        get: { settingsStore.settings.breakerCooldownSeconds },
                        set: { settingsStore.settings.app.rateLimit?.cooldownSeconds = $0 }
                    ),
                    range: 30...3600
                )
                if statusStore.breakerOpen {
                    HStack {
                        Text(L("当前有请求处于暂停中"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(L("立即恢复")) {
                            Task {
                                await RequestGate.shared.resetBreakers()
                                statusStore.breakerOpen = false
                            }
                        }
                        .compatGlassButton()
                    }
                }
            }

            Divider()
                .padding(.vertical, 2)

            Text(L("媒体 CDN（图片、视频下载）"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(isOn: Binding(
                get: { settingsStore.settings.cdnThrottleEnabled },
                set: { settingsStore.settings.app.rateLimit?.cdnThrottleEnabled = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("CDN 限流时降低下载并发"))
                    InfoHint(text: L("媒体服务器（pbs.twimg.com / video.twimg.com）返回 429 时，自动把同时下载数降到下面的值，避免越限越试。\n这与 X API 的限流是两个独立的配额。"))
                }
            }

            if settingsStore.settings.cdnThrottleEnabled {
                NumberStepperField(
                    title: L("限流时并发上限"),
                    value: Binding(
                        get: { settingsStore.settings.cdnMaxConcurrent },
                        set: { settingsStore.settings.app.rateLimit?.cdnMaxConcurrent = $0 }
                    ),
                    range: 1...10
                )
                NumberStepperField(
                    title: L("CDN 暂停时长（秒）"),
                    value: Binding(
                        get: { settingsStore.settings.cdnCooldownSeconds },
                        set: { settingsStore.settings.app.rateLimit?.cdnCooldownSeconds = $0 }
                    ),
                    range: 10...3600
                )
            }

            if statusStore.cdnThrottled {
                HStack {
                    Text(L("媒体下载当前受限"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(L("立即重试")) {
                        Task { await statusStore.probeCDN() }
                    }
                    .compatGlassButton()
                }
            }
        } header: {
            Label(L("限流缓解"), systemImage: "hand.raised.slash")
        }
    }

    // MARK: - 主页设置

    // MARK: - 翻译

    /// 翻译设置。使用系统 Translation 框架（**不消耗 X API 配额**）。
    private var translationSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsStore.settings.autoTranslateEnabled },
                set: { settingsStore.settings.app.autoTranslate = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("自动翻译"))
                    InfoHint(text: L("开启后，仅当推文语言与目标语言不同时才自动翻译（语言未知的不翻译，由你手动点）。\n使用系统翻译，不消耗 X 的接口配额。"))
                }
            }

            Picker(L("翻译目标语言"), selection: Binding(
                get: { settingsStore.settings.translateTargetLanguageRaw },
                set: { newValue in
                    settingsStore.settings.app.translateTargetLanguage = newValue.isEmpty ? nil : newValue
                    // 换目标语言后旧译文作废（它们对应旧语言）
                    TranslationStore.shared.clearAll()
                }
            )) {
                Text(L("跟随系统")).tag("")
                Text("简体中文").tag("zh-Hans")
                Text("繁體中文").tag("zh-Hant")
                Text("English").tag("en")
                Text("日本語").tag("ja")
                Text("한국어").tag("ko")
                Text("Français").tag("fr")
                Text("Deutsch").tag("de")
                Text("Español").tag("es")
                Text("Русский").tag("ru")
            }

            Text(L("首次翻译某语言时，系统会提示下载语言包；下载后可离线翻译。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        } header: {
            Label(L("翻译"), systemImage: "character.book.closed")
        }
    }

    private var homeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsStore.settings.autoLoadMediaEnabled },
                set: { settingsStore.settings.download.autoLoadMedia = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("自动加载媒体"))
                    InfoHint(text: L("关闭后，主页仅显示用户信息与下载配置，需要时点击「加载媒体」手动加载，可显著节省流量。"))
                }
            }
        } header: {
            Label(L("主页"), systemImage: "house")
        }
    }

    // MARK: - 隐私设置

    private var privacySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsStore.settings.autoClearDownloadHistoryEnabled },
                set: { settingsStore.settings.app.autoClearDownloadHistory = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("自动删除下载历史记录"))
                    InfoHint(text: L("开启后，每次离开对应页面时自动清空下载历史记录。仅删除记录，不删除已下载的文件。"))
                }
            }
            Toggle(isOn: Binding(
                get: { settingsStore.settings.autoClearSearchHistoryEnabled },
                set: { settingsStore.settings.app.autoClearSearchHistory = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("自动删除搜索记录"))
                    InfoHint(text: L("开启后，每次离开对应页面时自动清空搜索记录。仅删除记录。"))
                }
            }
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
                    TextField(L("代理用户名（可选）"), text: Binding(
                        get: { settingsStore.settings.proxy.username ?? "" },
                        set: { settingsStore.settings.proxy.username = $0.isEmpty ? nil : $0 }
                    ))
                    SecureField(L("代理密码（可选）"), text: Binding(
                        get: { settingsStore.settings.proxy.password ?? "" },
                        set: { settingsStore.settings.proxy.password = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
        } header: {
            Label(L("代理"), systemImage: "globe")
        }
    }

    // MARK: - 缓存设置

    // MARK: - 同步设置

    private var syncSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsStore.settings.autoSyncOnLaunchEnabled },
                set: { settingsStore.settings.sync.autoSyncOnLaunch = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("打开应用时自动同步"))
                    InfoHint(text: L("启动应用后自动开始同步清单内所有用户的最新媒体，同「同步」页的判定规则跳过已下载。"))
                }
            }

            Toggle(isOn: Binding(
                get: { settingsStore.settings.quitOnSyncCompleteEnabled },
                set: { settingsStore.settings.sync.quitOnSyncComplete = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("同步完成后自动关闭应用"))
                    InfoHint(text: L("所有用户同步结束且无失败时，应用在短暂展示完成状态后自动退出。若有失败会保留窗口等待处理。"))
                }
            }

            Picker(L("同步页面布局"), selection: Binding(
                get: { settingsStore.settings.syncLayout },
                set: { settingsStore.settings.syncLayout = $0; restartDialogVisible = true }
            )) {
                ForEach(SyncLayoutMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Button {
                showSyncListManager = true
            } label: {
                HStack {
                    Text(L("管理同步清单"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Picker(L("同步判定依据"), selection: Binding(
                get: { settingsStore.settings.syncCheckModeValue },
                set: { settingsStore.settings.sync.syncCheckMode = $0.rawValue }
            )) {
                ForEach(SyncCheckMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .padding(.leading, 16)
            .infoHint(L("按文件名：与下载判定依据的「按文件名」一致。\n按同步记录文件：在保存路径维护 .synced.json（记录每用户最新媒体日期与当天全部媒体 ID），同步只检索该日期之后的时间线，当天媒体按资源索引排除，可显著加快同步速度。"))
        } header: {
            Label(L("同步"), systemImage: "arrow.triangle.2.circlepath")
        }
        .sheet(isPresented: $showSyncListManager) {
            SyncListManagerSheet()
        }
    }

    private var cacheSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsStore.settings.cachingEnabled },
                set: { settingsStore.settings.app.cachingEnabled = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("启用图片缓存"))
                    InfoHint(text: L("缓存头像与媒体缩略图，重复加载时直接读本地，节省流量并加快刷新。"))
                }
            }

            if settingsStore.settings.cachingEnabled {
                ForEach(ImageCache.Category.allCases, id: \.self) { cat in
                    Toggle(L(cat.displayName), isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: cat.settingKey) as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: cat.settingKey) }
                    ))
                }

                Picker(L("缓存上限"), selection: Binding(
                    get: { settingsStore.settings.cacheLimitMB },
                    set: { settingsStore.settings.app.cacheLimitMB = $0 }
                )) {
                    ForEach([50, 100, 200, 300, 500], id: \.self) { mb in
                        Text("\(mb) MB").tag(mb)
                    }
                }
            }

            HStack {
                Button(L("立即清理缓存")) {
                    ImageCache.shared.clearAll()
                    cacheUsageText = L("已清理")
                }
                .compatGlassButton()
                InfoHint(text: L("删除 Cache/XSpiderMac/images 目录下全部缓存文件并重建索引。"))
                Text(cacheUsageText ?? ByteCountFormatter.string(fromByteCount: ImageCache.shared.currentBytes(), countStyle: .file))
                    .font(.caption)
            }
        } header: {
            Label(L("缓存"), systemImage: "square.stack.3d.down.forward")
        }
    }

    @State private var cacheUsageText: String?

    // MARK: - 数据（清理）

    private var dataSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button(L("清除所有应用数据…"), role: .destructive) { showCleanupDialog = true }
                        .compatGlassButton()
                    InfoHint(text: L("删除 ~/Library/Application Support/XSpiderMac（下载暂存、aria2 会话、图片缓存）、~/Library/Caches 与 ~/Library/Logs/XSpiderMac 下的应用数据及偏好设置。不影响已保存的媒体文件。"))
                }
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

    // MARK: - UI（液态玻璃）

    private var uiSection: some View {
        Section {
            Toggle(L("液态玻璃外观"), isOn: Binding(
                get: { settingsStore.settings.liquidGlassEnabled },
                set: { settingsStore.settings.app.liquidGlass = $0; restartDialogVisible = true }
            ))
            .disabled(!GlassCompat.supportsLiquidGlass)

            if !GlassCompat.supportsLiquidGlass {
                Text(L("当前系统版本不支持液态玻璃，已自动使用普通材质。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if GlassCompat.supportsLiquidGlass {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L("模糊度"))
                        Spacer()
                        Text("\(settingsStore.settings.glassBlur)%")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Slider(value: Binding(
                        get: { Double(settingsStore.settings.glassBlur) },
                        set: { settingsStore.settings.app.glassBlur = Int($0) }
                    ), in: 20...100, step: 5)
                }
            }
        } header: {
            Label(L("UI"), systemImage: "aqi.medium")
        }
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
            Toggle(isOn: Binding(
                get: { settingsStore.settings.app.preventSleepDuringDownload },
                set: { settingsStore.settings.app.preventSleepDuringDownload = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("有下载任务时阻止系统休眠"))
                    InfoHint(text: L("使用系统电源断言机制，仅在下载进行期间保持唤醒，不会修改系统设置。"))
                }
            }
        } header: {
            Label(L("电源"), systemImage: "zzz")
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsStore.settings.app.writeLogs },
                set: { settingsStore.settings.app.writeLogs = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("开启日志记录"))
                    InfoHint(text: L("日志记录网络请求、下载任务、错误等信息，用于问题排查。"))
                }
            }

            LabeledContent(L("日志位置")) {
                Text(AppLogger.currentLogFile.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack {
                Button(L("在 Finder 中显示")) { showLogsInFinder() }
                    .compatGlassButton()
                Button(L("导出日志…")) { exportLogs() }
                    .compatGlassButton()
                Button(L("删除所有日志"), role: .destructive) { confirmDeleteLogs = true }
                    .compatGlassButton()
                if AppLogger.logFileCount > 0 {
                    Text("\(AppLogger.logFileCount) " + L("个日志文件"))
                        .font(.caption)
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


// MARK: - 同步清单管理（设置页入口：检索 / 按添加顺序倒序 / 液态玻璃删除）

/// 列表式清单管理：最新添加排最前；可按用户名、昵称检索；液态玻璃删除按钮
struct SyncListManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = SyncStore.shared
    @State private var searchText = ""
    /// 排序：addition（默认，最新添加在最前）/ alphabet（用户名首字母）
    @State private var sortOrder: SyncListSortOrder = .addition

    /// 排序 + 检索过滤（用户名 / 昵称，不分大小写）
    private var filteredUsers: [SyncUser] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let base: [SyncUser]
        switch sortOrder {
        case .addition:
            base = Array(store.users.reversed())
        case .alphabet:
            base = store.users.sorted {
                $0.screenName.lowercased().compare($1.screenName.lowercased(), locale: .current) == .orderedAscending
            }
        }
        guard !q.isEmpty else { return base }
        let lowered = q.lowercased()
        return base.filter {
            $0.screenName.lowercased().contains(lowered) || $0.name.lowercased().contains(lowered)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题 + 检索框
            HStack(spacing: 12) {
                Picker(L("排序"), selection: $sortOrder) {
                    Text(L("添加顺序")).tag(SyncListSortOrder.addition)
                    Text(L("用户名首字母")).tag(SyncListSortOrder.alphabet)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("搜索用户名或昵称"), text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if store.users.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(L("清单为空"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredUsers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text(L("无匹配结果"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredUsers) { user in
                            listRow(user)
                        }
                    }
                    .padding(12)
                }
            }

            Divider()

            HStack {
                Text(L("共 \(store.users.count) 位用户"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .compatGlassProminentButton()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 520)
        .presentationBackground(.thinMaterial)
        .presentationBackgroundInteraction(.enabled)
    }

    /// 行：头像 + 昵称 + 用户名 + 液态玻璃删除按钮
    private func listRow(_ user: SyncUser) -> some View {
        HStack(spacing: 12) {
            CachedAvatarView(urlString: user.avatar, size: 36)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("@\(user.screenName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    store.removeUser(user.screenName)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 30, height: 30)
                    .liquidGlass(interactive: true, cornerRadius: 15)
            }
            .buttonStyle(.plain)
            .help(L("从清单移除"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}


/// 同步清单排序
enum SyncListSortOrder: Hashable, Sendable {
    case addition
    case alphabet
}
