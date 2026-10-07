import SwiftUI

/// 设置页：下载（保存路径/账号子目录/文件名模板/跳过相同文件）+ 代理 + 外观（字体/语言）+ 日志 + 防休眠。
struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared
    @State private var statusStore = AccountStatusStore.shared
    @State private var exportMessage: String?
    @State private var showCleanupDialog = false
    /// 模板输入框的插入器（点「可用变量」时把 `%XXX%` 插到光标处）
    @State private var templateInserter: TemplateTextField.Inserter?
    /// 同步清单管理弹窗
    @State private var showSyncListManager = false
    /// 自动翻译语言清单窗口
    @State private var showTranslationLanguages = false
    /// 组件区：两个二进制各自的版本与来源
    @State private var components: [ComponentEntry] = []
    /// 重启组件失败时的原文（成功或未尝试时为空）
    @State private var componentRestartError: String?
    @State private var componentBusy = false
    /// 组件更新指引弹窗
    @State private var showUpdateGuide = false

    var body: some View {
        // **排序原则**（需求：常用的摆前面）：按"普通用户的使用频率"从高到低，
        // 而不是按代码模块顺序。查看频率低的（日志、数据清理）沉到最底。
        //
        //   1-4  日常必看：主页 / 下载 / 引擎 / 外观
        //   5-8  按需调整：界面外观 / 翻译 / 代理 / 限流
        //   9-11 维护类：状态检测 / 缓存 / 同步
        //   12-15 低频：隐私 / 电源 / 数据清理 / 日志
        Form {
            homeSection
            downloadSection
            engineSection
            componentSection
            appearanceSection
            uiSection
            translationSection
            proxySection
            rateLimitSection
            statusProbeSection
            cacheSection
            syncSection
            privacySection
            powerSection
            dataSection
            logSection
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
        .task { statusStore.restartActiveProbeIfNeeded() }
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
                    InfoHint(text: L("开启后，资源将保存到「保存路径/昵称-用户名[数字id]」文件夹中，例如：Tesla-Tesla[13298072]。"))
                }
            }

            // 下载提示框（右下浮条）显示开关
            Toggle(isOn: Binding(
                get: { settingsStore.settings.showDownloadTipEnabled },
                set: { settingsStore.settings.app.showDownloadTip = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("显示下载提示框"))
                    InfoHint(text: L("右下角悬浮的下载进度提示框。关闭后仍在「下载管理」查看进度，只是不在主界面浮出，避免遮挡内容。"))
                }
            }

            // 文件名模板（单一输入 + 实时预览）
            // 用 AppKit 包一层：点下面的「可用变量」要插到**光标处**（见 TemplateTextField）
            TemplateTextField(
                text: Binding(
                    get: { settingsStore.settings.download.fileNameTemplate },
                    set: {
                        settingsStore.settings.download.fileNameTemplate = $0
                        DownloadStore.shared.refreshDownloadedCaches()
                    }
                ),
                onReady: { templateInserter = $0 }
            )
            .frame(height: 22)

            LabeledContent(L("预览")) {
                Text(FileNameTemplate.resolve(
                    template: settingsStore.settings.download.fileNameTemplate,
                    data: SettingsView.exampleTemplateData
                ))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }

            // 变量选择器（默认展开）：点击插入到光标处（输入框未聚焦则无事发生）
            TemplateVariablePicker { snippet in
                templateInserter?.insert(snippet)
            }

            // 跳过相同文件
            Toggle(L("跳过已存在的相同文件"), isOn: Binding(
                get: { settingsStore.settings.download.sameFileSkip },
                set: { settingsStore.settings.download.sameFileSkip = $0 }
            ))

            // 判定依据（跳过相同文件的子选项，类似代理的"手动/系统"联动）
            if settingsStore.settings.download.sameFileSkip {
                Picker(L("判定依据"), selection: Binding(
                    get: { settingsStore.settings.sameFileCheckModeValue },
                    set: {
                        settingsStore.settings.download.sameFileCheckMode = $0.rawValue
                        DownloadStore.shared.refreshDownloadedCaches()
                    }
                )) {
                    ForEach(SameFileCheckMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 16)
                .infoHint(L("按文件名：用文件名模板算出文件名（含下方唯一标识后缀），目标文件夹里存在即算已下载。改名或移动文件后会被视为未下载。\n记录文件·分布式：读账号文件夹里的记录文件，媒体 id 命中即算。\n记录文件·集中式：读应用数据目录里的记录，媒体 id 命中即算。\n两种记录模式都只查记录、不回查文件，因此改文件名模板、重命名或移动文件都不会让记录失效。"))
            }

            // 文件名追加唯一标识（契约 §6.2 联动：任一判定选「按文件名」→ 强制打开且不可改）
            Toggle(isOn: Binding(
                get: { settingsStore.settings.appendUniqueIdEnabled },
                set: {
                    settingsStore.settings.appendUniqueIdUserEnabled = $0
                    DownloadStore.shared.refreshDownloadedCaches()
                }
            )) {
                HStack(spacing: 6) {
                    Text(L("文件名追加唯一标识"))
                    InfoHint(text: L("在扩展名前用「[媒体ID]」追加资源唯一标识，例如：\n2026-09-12 18-37-48 Tesla 2098843535730725124[2098843532463411200].jpg\n\n判定依据或同步判定依据选「按文件名」时强制打开（此时文件名就是判据），其余情况可自行开关。"))
                }
            }
            .disabled(settingsStore.settings.appendUniqueIdLocked)

            // 记录文件名（仅分布式形态创建在每个账号文件夹里）
            //
            // 可编辑条件 = **判定依据选分布式 或 记录形态选分布式**：
            // 这个名字有两个消费方——下载判定（`DownloadStore.distributedRecordURL`）
            // 与三个记录入口（`RecordsIO`，形态由上一行的「记录形态」决定）。
            // 只按判定依据禁用，会让"判定集中式 + 形态分布式"的用户改不了
            // 那三个入口正在用的文件名。
            TextField(L("记录文件名"), text: Binding(
                get: { settingsStore.settings.recordFileNameRaw },
                set: {
                    settingsStore.settings.recordFileNameRaw = $0
                    DownloadStore.shared.refreshDownloadedCaches()
                }
            ))
            .disabled(settingsStore.settings.sameFileCheckModeValue != .distributed
                      && settingsStore.settings.recordsFormValue != .distributed)
            .infoHint(L("分布式记录的文件名（默认 .downloadedrecord.json），创建在每个账号文件夹里。\n判定依据或记录形态选「分布式」时可改；集中式记录固定放在应用数据目录、不用这个名字。"))

            // 记录导入导出 / 按文件名重建（契约 §7/§8）
            recordButtons
        } header: {
            Label(L("下载"), systemImage: "arrow.down.circle")
        }
    }

    // MARK: - 引擎设置

    /// 组件状态（绿灯 = 进程真的起来并握手成功）。
    struct ComponentState {
        var isReady: Bool
        var label: String
    }
    @State private var componentState = ComponentState(isReady: false, label: L("组件未启动"))

    private func refreshComponentState() async {
        if let info = XSpiderComponent.shared.currentInfo {
            let aria2 = XSpiderComponent.locate("aria2next") != nil
            componentState = ComponentState(
                isReady: true,
                label: L("组件就绪") + " · " + info.transport + " · 契约 " + info.contractVersion
                    + (aria2 ? " · aria2Next 可用" : " · 未找到 aria2Next（仅内置后端）"))
        } else {
            componentState = ComponentState(isReady: false, label: L("组件未启动（首次取数或下载时自动拉起）"))
        }
    }

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

            // 组件状态与更新入口都移到下面的「组件」区（`componentSection`）。

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

    // MARK: - 组件

    /// 组件区的一行：一个二进制文件 + 它的版本与来源。
    struct ComponentEntry: Identifiable {
        var name: String
        var role: String
        var version: String?
        var origin: XSpiderComponent.BinaryOrigin?
        var running: Bool?
        var id: String { name }
    }

    /// 来源文案：它决定"换了文件到底有没有生效"。
    private func originLabel(_ origin: XSpiderComponent.BinaryOrigin) -> String {
        switch origin {
        case .external: return L("外部目录（优先）")
        case .bundled: return L("应用内置（兜底）")
        case .path: return "PATH"
        }
    }

    /// `xspiderd 0.1.0 (契约版本 x.y.z)` → `版本 0.1.0 · 契约 x.y.z`
    static func sidecarVersionLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let numbers = raw
            .split(whereSeparator: { !$0.isNumber && $0 != "." })
            .map(String.init)
            .filter { $0.contains(".") && $0.allSatisfy { $0.isNumber || $0 == "." } }
        guard let build = numbers.first else { return raw }
        if numbers.count >= 2 { return L("版本") + " \(build) · " + L("契约") + " \(numbers[1])" }
        return L("版本") + " \(build)"
    }

    /// `Aria2 Next version 2.7.5` → `版本 2.7.5`
    static func ariaVersionLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let range = raw.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) else { return raw }
        return L("版本") + " " + String(raw[range])
    }

    /// 探一次两个组件的版本与来源：只跑 `--version`，不拉起常驻进程。
    private func refreshComponents() async {
        await refreshComponentState()
        let sidecar = XSpiderComponent.locate("xspiderd")
        let aria = XSpiderComponent.locate("aria2next")
        let sidecarVersion = await XSpiderComponent.binaryVersion("xspiderd")
        let ariaVersion = await XSpiderComponent.binaryVersion("aria2next")
        components = [
            ComponentEntry(
                name: "xspiderd",
                role: L("取数 / 写操作 / 下载 / 爬取——应用的网络请求全部经它"),
                version: Self.sidecarVersionLabel(sidecarVersion),
                origin: sidecar.map { XSpiderComponent.origin(of: $0) },
                running: XSpiderComponent.shared.isRunning
            ),
            ComponentEntry(
                name: "aria2next",
                role: L("下载引擎（多连接、断点续传）"),
                version: Self.ariaVersionLabel(ariaVersion),
                origin: aria.map { XSpiderComponent.origin(of: $0) },
                running: nil
            ),
        ]
    }

    private var componentSection: some View {
        Section {
            // 状态行的判据是**进程真的起来并完成了握手**，不是"文件存在"——
            // 文件在但被隔离/未签名时会以 137 静默死掉，那种情况下"文件存在"是假绿灯。
            HStack {
                Circle()
                    .fill(componentState.isReady ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(componentState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(components) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.callout.monospaced())
                        if let running = entry.running {
                            Text(running ? L("运行中") : L("未启动"))
                                .font(.caption2)
                                .foregroundStyle(running ? Color.green : Color.secondary)
                        }
                        Spacer()
                        if let origin = entry.origin {
                            Text(originLabel(origin))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(entry.role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.version ?? L("未找到——组件目录里没有这个文件"))
                        .font(.caption)
                        .foregroundStyle(entry.version == nil ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }

            if let componentRestartError {
                Text(componentRestartError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button(L("重新检查")) {
                    Task { await refreshComponents() }
                }
                Button(L("重启组件")) {
                    Task {
                        componentBusy = true
                        componentRestartError = nil
                        do {
                            _ = try await XSpiderComponent.shared.restart()
                        } catch {
                            componentRestartError = error.localizedDescription
                        }
                        await refreshComponents()
                        componentBusy = false
                    }
                }
                .disabled(componentBusy)
                Button(L("更新组件")) { showUpdateGuide = true }
                Spacer()
            }
            .compatGlassButton()
        } header: {
            Label(L("组件"), systemImage: "shippingbox")
        }
        .task { await refreshComponents() }
        .sheet(isPresented: $showUpdateGuide) { ComponentUpdateGuideSheet() }
    }

    // MARK: - 限流缓解

    /// 限流状态分两组展示：core API 调用与媒体 CDN 下载。
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
                        Button(L("重新检测")) {
                            Task { await statusStore.probeAndRecover() }
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
                    InfoHint(text: L("开启后，**只有**下方清单里列出的语言会自动翻译。\n语言未知的推文不翻译（由你手动点）。\n使用系统翻译，不消耗 X 的接口配额。"))
                }
            }

            if settingsStore.settings.autoTranslateEnabled {
                // 自动翻译语言清单（需求：可单独管理 + 预先下载语言包）
                Button {
                    showTranslationLanguages = true
                } label: {
                    HStack {
                        Text(L("自动翻译的语言"))
                        Spacer()
                        Text(languageSummary)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
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

            Text(L("语言包由系统提供、本地翻译。可在语言清单里预先下载，避免浏览时才等待下载。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        } header: {
            Label(L("翻译"), systemImage: "character.book.closed")
        }
        .sheet(isPresented: $showTranslationLanguages) {
            TranslationLanguageListSheet()
        }
    }

    /// 清单摘要（"日文、韩文" / "未设置"）
    private var languageSummary: String {
        let list = settingsStore.settings.autoTranslateLanguageList
        guard !list.isEmpty else { return L("未设置") }
        let names = list.prefix(3).map {
            Settings.displayLocale.localizedString(forLanguageCode: $0) ?? $0
        }
        return names.joined(separator: "、") + (list.count > 3 ? "…" : "")
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
            Toggle(isOn: Binding(
                get: { settingsStore.settings.fastSearchLoadingEnabled },
                set: { settingsStore.settings.app.fastSearchLoading = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("加快搜索页加载"))
                    InfoHint(text: L("设置时间范围后，用 X 的搜索接口按时间筛选（服务端完成），加载更快：\n· 每页可返回约 42 条媒体（时间线只有 10 条）\n· 账号有停更空窗期时也不会卡住\n\n搜索浏览可能有极个别遗漏，但「下载」始终由内置爬虫逐页抓取，会把这些遗漏补上。\n关闭则改用时间线逐页加载 + 本地筛选，速度较慢但不依赖搜索接口。"))
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

    // MARK: - 状态检测

    /// 状态检测区：主动检测开关 + 间隔。
    ///
    /// 与侧边栏底部状态栏配合：那里显示**被动**采集的结论，
    /// 这里决定要不要**额外主动**去探（会消耗 X 请求配额）。
    private var statusProbeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsStore.settings.activeStatusProbeEnabled },
                set: { settingsStore.settings.app.activeStatusProbe = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(L("主动检测连接状态"))
                    InfoHint(text: L("开启：按下方间隔主动探测与 X 的连通性，状态变化能更快反映到边栏（例如断网后不必等下次操作）。代价是会按间隔消耗少量 X 请求配额。\n\n关闭：只在真实操作遇阻时被动更新状态（不发任何额外请求），更省配额但状态更新滞后。\n\n两种方式都会遵守限流：处于 429 时不会硬探。"))
                }
            }
            if settingsStore.settings.activeStatusProbeEnabled {
                NumberStepperField(
                    title: L("检测间隔（秒）"),
                    value: Binding(
                        get: { settingsStore.settings.activeStatusProbeIntervalSeconds },
                        set: { settingsStore.settings.app.activeStatusProbeInterval = max(5, $0) }
                    ),
                    range: 5...3600
                )
                .infoHint(L("两次主动检测之间的间隔，最低 5 秒。\n间隔过短会被 X 视为异常流量，反而更容易触发限流，建议 30 秒以上。"))
                if let last = statusStore.lastActiveProbeAt {
                    HStack {
                        Text(L("上次检测"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(last.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label(L("状态检测"), systemImage: "heart.text.square")
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
                set: {
                    settingsStore.settings.sync.syncCheckMode = $0.rawValue
                    DownloadStore.shared.refreshDownloadedCaches()
                }
            )) {
                ForEach(SyncCheckMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .padding(.leading, 16)
            .infoHint(L("按文件名：与下载判定依据的「按文件名」一致（同一个实现）。\n记录文件·分布式：读账号文件夹里的同步记录（每个被同步账号一个条目：最新媒体日期 + 窗口内媒体 id），只检索该日期之后的时间线，可显著加快同步速度。\n记录文件·集中式：同上，记录放在应用数据目录，与媒体文件分离。"))
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
                    ForEach([100, 200, 300, 500, 1000, 2000], id: \.self) { mb in
                        Text("\(mb) MB").tag(mb)
                    }
                    // 无上限：不做容量控制（用 0 作哨兵值，见 Settings.unlimitedCacheLimitMB）
                    Text(L("无上限")).tag(Settings.unlimitedCacheLimitMB)
                }
                .infoHint(L("超过上限后自动清理最旧的缓存文件。「无上限」= 不限制缓存占用。"))

                // 超限回收目标：超过上限后回收，直到占用降到上限的这个百分比
                NumberStepperField(
                    title: L("超限回收目标（占上限 %）"),
                    value: Binding(
                        get: { settingsStore.settings.cacheReclaimTargetPercent },
                        set: {
                            let r = Settings.cacheReclaimTargetRange
                            settingsStore.settings.app.cacheReclaimTargetPercent = min(r.upperBound, max(r.lowerBound, $0))
                        }
                    ),
                    range: Settings.cacheReclaimTargetRange
                )
                .infoHint(L("占用超过上限时，从最旧的文件开始删除，直到占用降到「上限 × 这个百分比」为止。\n\n例：上限 1 GB、此项 60%，占用涨到 2 GB 时会删到只剩 600 MB。留出的这段余量，能让后续写入长时间不再触发清理。\n\n0% 表示超限后全部清空。"))
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

    // MARK: - 记录导入 / 导出 / 重建（契约 `MEDIA_RECORDS.md` §7/§8）

    /// 待导入的来源（选中文件/目录后先弹「覆盖 / 追加 / 取消」，选定才真的写）
    @State private var pendingImport: RecordImportSource?
    @State private var showImportStrategyDialog = false
    /// 待重建的保存路径（同一套「覆盖 / 追加」选择）
    @State private var pendingRebuildDir: String?
    @State private var showRebuildStrategyDialog = false
    /// 结果文案（成功/失败/报告都走这里，短暂显示在按钮下方）
    @State private var recordMessage: String?

    private var recordButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 这三个入口读写哪一份记录，由**独立的形态设置**决定，不再从下载判定推断
            // （此前判定选「按文件名」时一律按分布式走，于是集中式记录既导不出也写不回）。
            Picker(L("记录形态"), selection: Binding(
                get: { settingsStore.settings.recordsFormValue },
                set: {
                    settingsStore.settings.recordsFormValue = $0
                    DownloadStore.shared.refreshDownloadedCaches()
                }
            )) {
                ForEach(RecordForm.allCases, id: \.self) { form in
                    Text(SettingsView.recordFormName(form)).tag(form)
                }
            }
            .pickerStyle(.segmented)
            .infoHint(L("导出记录… / 导入记录… / 按文件名重建记录… 读写哪一份记录。\n分布式：读账号文件夹里的记录文件（跟随保存路径）。\n集中式：读应用数据目录里的记录（默认，与媒体文件分离，搬走媒体文件夹也不丢判定）。\n与「判定依据」无关——判定决定怎么算已下载，这里决定记录读写在哪。"))

            HStack(spacing: 8) {
                Button(L("导出记录…")) { exportRecords() }
                    .compatGlassButton()
                Menu(L("导入记录…")) {
                    Button(L("从文件…")) { importFromFile() }
                    Button(L("从保存路径扫描…")) { importFromSavePath() }
                }
                .compatGlassButton()
                Button(L("按文件名重建记录…")) { rebuildRecords() }
                    .compatGlassButton()
            }
            if let recordMessage {
                Text(recordMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .confirmationDialog(
            L("导入方式"),
            isPresented: $showImportStrategyDialog,
            titleVisibility: .visible
        ) {
            Button(L("追加（合并）")) { runPendingImport(strategy: .merge) }
            Button(L("覆盖"), role: .destructive) { runPendingImport(strategy: .overwrite) }
            Button(L("取消"), role: .cancel) { pendingImport = nil }
        } message: {
            Text(L("追加：id 合并去重，重复导入同一份文件不会重复计数。\n覆盖：导入包里出现的账号，其记录被导入内容整体替换（其余账号不动）。"))
        }
        .confirmationDialog(
            L("重建方式"),
            isPresented: $showRebuildStrategyDialog,
            titleVisibility: .visible
        ) {
            Button(L("追加（合并）")) { runPendingRebuild(strategy: .merge) }
            Button(L("覆盖"), role: .destructive) { runPendingRebuild(strategy: .overwrite) }
            Button(L("取消"), role: .cancel) { pendingRebuildDir = nil }
        } message: {
            Text(L("按文件名解析出的媒体 id 写入记录。\n追加：与现有记录合并去重。\n覆盖：识别到媒体 id 的账号，其记录被整体替换（其余账号不动）。"))
        }
    }

    /// 导出到用户选的 `.json` 文件
    private func exportRecords() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xspider-records.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let export = try RecordsIO.exportRecords(
                form: currentForm, saveDir: saveDirForRecords,
                recordFileName: settingsStore.settings.recordFileNameValue)
            let data = try MediaRecordJSON.encode(export)
            try MediaRecordJSON.writeAtomically(data, to: url)
            recordMessage = String(format: L("已导出 %d 个账号的下载记录、%d 个账号的同步记录"),
                                   export.downloads.count, export.sync.count)
            AppLogger.info("记录已导出", category: "REC", [
                "file": url.path, "form": currentForm.rawValue,
                "downloads": "\(export.downloads.count)", "sync": "\(export.sync.count)",
            ])
        } catch {
            recordMessage = String(format: L("导出失败：%@"), error.localizedDescription)
            AppLogger.warn("导出记录失败", category: "REC", ["error": error.localizedDescription])
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImport = .exportFile(url)
        showImportStrategyDialog = true
    }

    private func importFromSavePath() {
        guard !saveDirForRecords.isEmpty else {
            recordMessage = L("保存路径为空，无法扫描")
            return
        }
        pendingImport = .distributedRecords(saveDir: saveDirForRecords)
        showImportStrategyDialog = true
    }

    private func runPendingImport(strategy: RecordImportStrategy) {
        guard let source = pendingImport else { return }
        pendingImport = nil
        runImport(source: source, strategy: strategy)
    }

    private func runImport(source: RecordImportSource, strategy: RecordImportStrategy) {
        do {
            let report = try RecordsIO.importRecords(
                from: source, into: currentForm, strategy: strategy,
                saveDir: saveDirForRecords,
                recordFileName: settingsStore.settings.recordFileNameValue)
            DownloadStore.shared.refreshDownloadedCaches()   // 判定立即跟着刷新
            recordMessage = String(format: L("导入完成：识别 %d 个账号，新增 %d 条，无法识别 %d 条"),
                                   report.recognizedAccounts, report.addedEntries,
                                   report.unrecognizedEntries)
            AppLogger.info("记录已导入", category: "REC", [
                "form": currentForm.rawValue, "strategy": "\(strategy)",
                "accounts": "\(report.recognizedAccounts)", "added": "\(report.addedEntries)",
                "unrecognized": "\(report.unrecognizedEntries)",
            ])
        } catch {
            recordMessage = String(format: L("导入失败：%@"), error.localizedDescription)
            AppLogger.warn("导入记录失败", category: "REC", ["error": error.localizedDescription])
        }
    }

    private func rebuildRecords() {
        guard !saveDirForRecords.isEmpty else {
            recordMessage = L("保存路径为空，无法扫描")
            return
        }
        pendingRebuildDir = saveDirForRecords
        showRebuildStrategyDialog = true
    }

    private func runPendingRebuild(strategy: RecordImportStrategy) {
        guard let dir = pendingRebuildDir else { return }
        pendingRebuildDir = nil
        do {
            let report = try RecordsIO.rebuildFromFileNames(
                saveDir: dir, into: currentForm, strategy: strategy,
                recordFileName: settingsStore.settings.recordFileNameValue)
            DownloadStore.shared.refreshDownloadedCaches()
            recordMessage = String(format: L("重建完成：识别 %d 个，新增 %d 条，无法识别 %d 个"),
                                   report.recognized, report.added, report.unrecognized)
            AppLogger.info("按文件名重建记录", category: "REC", [
                "form": currentForm.rawValue, "strategy": "\(strategy)",
                "recognized": "\(report.recognized)", "added": "\(report.added)",
                "unrecognized": "\(report.unrecognized)",
            ])
        } catch {
            recordMessage = String(format: L("重建失败：%@"), error.localizedDescription)
            AppLogger.warn("按文件名重建记录失败", category: "REC", ["error": error.localizedDescription])
        }
    }

    /// 导入导出写哪个形态：由「记录形态」设置显式决定（默认集中式）。
    ///
    /// **不再从下载判定推断**——旧实现里判定选「按文件名」时一律返回 `.distributed`，
    /// 于是集中式记录（`~/Library/Application Support/XSpiderMac/records/downloads/*.json`）
    /// 既导不出（导出包 downloads 为空）也写不回（导入/重建写进了账号文件夹）。
    private var currentForm: RecordForm {
        settingsStore.settings.recordsFormValue
    }

    /// 记录形态的显示名（复用判定依据那两个已有译文，两种说法指的是同一件事）。
    static func recordFormName(_ form: RecordForm) -> String {
        switch form {
        case .distributed: return L("记录文件·分布式")
        case .centralized: return L("记录文件·集中式")
        }
    }

    /// 记录文件的保存路径（与下载一致；空则回落到 ~/Downloads）
    private var saveDirForRecords: String {
        let base = settingsStore.settings.download.saveDirBase
        if !base.isEmpty { return base }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?.path ?? ""
    }

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

    /// 模板预览示例数据
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
            createdAt: Date(timeIntervalSince1970: 1_705_763_736),
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
    /// 点某个变量时收到 `%XXX%`；父视图把它插到模板输入框的光标处。
    var onPick: (String) -> Void

    @State private var flashVariable: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("可用变量（点击插入到光标处）"))
                .font(.subheadline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 6) {
                ForEach(FileNameTemplate.variableDescriptions, id: \.name) { variable in
                    Button {
                        // 插到光标处；输入框没聚焦时 `insert` 返回 false、什么都不做
                        let snippet = "%\(variable.name)%"
                        onPick(snippet)
                        // 无论插没插进去都给一下反馈（点了没反应会让人以为按钮坏了）
                        flashVariable = variable.name
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            flashVariable = nil
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("%\(variable.name)%")
                                    .font(.system(.caption, design: .monospaced))
                                if flashVariable == variable.name {
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
/// 组件更新指引（设置 → 组件 → 更新组件）。
///
/// 组件与应用**分开更新**：换掉外部目录里的文件即可，不必重新构建应用。
/// 这里只讲怎么做，不替用户执行——替换可执行文件是要用户自己确认的动作。
struct ComponentUpdateGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// 外部组件目录的**绝对路径**。
    /// 命令里不能写 `~`：它在引号内不会被 shell 展开，抄进去会找不到文件。
    private var directory: String {
        XSpiderComponent.externalDirectory?.path
            ?? "\(NSHomeDirectory())/Library/Application Support/"
            + "\(Bundle.main.bundleIdentifier ?? "moe.keli.xspider.mac")/XSpiderCore"
    }

    private var commands: String {
        """
        xattr -cr "\(directory)"
        codesign --force --sign - "\(directory)"/xspiderd "\(directory)"/aria2next
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("更新组件"))
                .font(.title3.weight(.semibold))

            Text(L("组件与应用分开更新：换掉下面目录里的文件即可，不必重新构建应用。"))
                .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("1. 拿到最新的 xspiderd 与 aria2next（来自 x-spider-core 项目）。"))

                Text(L("2. 把两个文件放进："))
                Text(directory)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.leading, 14)
                Text(L("应用优先用外部目录里的这份，bundle 内的只作兜底。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)

                Text(L("3. 清掉隔离属性并重新签名，两件都要做："))
            }
            .font(.callout)

            Text(commands)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            Text(L("第 3 步不能省：从浏览器下载来的文件带隔离属性，带它的可执行文件会被系统直接杀掉（退出码 137，没有任何输出），而应用只会写一行日志——表现是「组件整个不工作」。只清属性仍会被杀，所以要再补一次签名。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(L("放好之后点「重新检查」，上面的版本号应当随之更新。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(copied ? L("已复制") : L("复制命令")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commands, forType: .string)
                    copied = true
                }
                Button(L("打开组件目录")) {
                    if let url = XSpiderComponent.externalDirectory {
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button(L("关闭")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

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
