import SwiftUI

/// 上游 Settings.tsx 的移植：下载（保存路径/目录模板/文件名模板/跳过相同文件）+ 代理 + 应用设置。
/// 模板变量与实时预览对齐上游 VariablePicker + TemplateExample。
struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared

    var body: some View {
        Form {
            downloadSection
            proxySection
            appSection
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .frame(minWidth: 560)
    }

    // MARK: - 下载设置（上游 Section "下载"）

    private var downloadSection: some View {
        Section {
            // 保存路径（上游 SavePathSelector：文件夹选择器）
            HStack {
                TextField("保存路径", text: Binding(
                    get: { settingsStore.settings.download.saveDirBase },
                    set: { settingsStore.settings.download.saveDirBase = $0 }
                ))
                Button("选择…") {
                    selectSaveDir()
                }
                .buttonStyle(.glass)
            }

            // 目录模板（上游 FileNameTemplateInput：空 = 直接存保存路径）
            LabeledContent("目录模板") {
                TextField("为空时直接保存在保存路径", text: Binding(
                    get: { settingsStore.settings.download.dirTemplate },
                    set: { settingsStore.settings.download.dirTemplate = $0 }
                ))
            }

            // 文件名模板（上游 FileNameTemplateInput + TemplateExample 实时预览）
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("文件名模板") {
                    TextField("文件名模板", text: Binding(
                        get: { settingsStore.settings.download.fileNameTemplate },
                        set: { settingsStore.settings.download.fileNameTemplate = $0 }
                    ))
                }

                // 实时预览（上游 TemplateExample：用 EXAMPLE 数据渲染）
                let preview = FileNameTemplate.resolve(
                    template: settingsStore.settings.download.fileNameTemplate,
                    data: SettingsView.exampleTemplateData
                )
                LabeledContent("预览") {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // 变量选择器（上游 VariablePicker：点击复制）
                TemplateVariablePicker()
            }

            // 跳过相同文件（上游 Switch sameFileSkip）
            Toggle("跳过已存在的相同文件", isOn: Binding(
                get: { settingsStore.settings.download.sameFileSkip },
                set: { settingsStore.settings.download.sameFileSkip = $0 }
            ))
        } header: {
            Label("下载", systemImage: "arrow.down.circle")
        }
    }

    // MARK: - 代理设置（上游 Section "代理"：三态）

    private var proxySection: some View {
        Section {
            Toggle("启用代理", isOn: Binding(
                get: { settingsStore.settings.proxy.enable },
                set: { settingsStore.settings.proxy.enable = $0 }
            ))

            if settingsStore.settings.proxy.enable {
                Toggle("使用系统代理", isOn: Binding(
                    get: { settingsStore.settings.proxy.useSystem },
                    set: { settingsStore.settings.proxy.useSystem = $0 }
                ))

                if !settingsStore.settings.proxy.useSystem {
                    TextField("代理地址", text: Binding(
                        get: { settingsStore.settings.proxy.url },
                        set: { settingsStore.settings.proxy.url = $0 }
                    ))
                }
            }
        } header: {
            Label("代理", systemImage: "globe")
        }
    }

    // MARK: - 应用设置（上游 Section "应用"）

    private var appSection: some View {
        Section {
            Toggle("自动检查更新", isOn: Binding(
                get: { settingsStore.settings.app.autoCheckUpdate },
                set: { settingsStore.settings.app.autoCheckUpdate = $0 }
            ))
            Toggle("接受预发布版本", isOn: Binding(
                get: { settingsStore.settings.app.acceptPrerelease },
                set: { settingsStore.settings.app.acceptPrerelease = $0 }
            ))
            Toggle("写入日志文件", isOn: Binding(
                get: { settingsStore.settings.app.writeLogs },
                set: { settingsStore.settings.app.writeLogs = $0 }
            ))
        } header: {
            Label("应用", systemImage: "app")
        }
    }

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

    /// 上游 EXAMPLE_USER / EXAMPLE_POST / EXAMPLE_MEDIA（示例数据，供模板预览）
    static let exampleTemplateData: FileNameTemplateData = {
        let user = TwitterUser(
            screenName: "userscreenname",
            avatar: "",
            name: "这是用户昵称",
            id: "1145141919",
            mediaCount: 8888,
            registerTime: TwitterDate.parse("2024-01-01 00:00:00")
        )
        let post = TwitterPost(
            id: "1145141919810",
            user: user,
            createdAt: TwitterDate.parse("2024-01-20 15:15:36"),
            fullText: "这里是推文内容,这里是推文内容，这里是推文内容，这里是推文内容，这里是推文内容，这里是推文内容。",
            tags: ["标签1", "标签2"],
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

// MARK: - 模板变量选择器（上游 VariablePicker：点击复制到剪贴板）

struct TemplateVariablePicker: View {
    @State private var copiedVariable: String?

    var body: some View {
        DisclosureGroup("可用变量（点击复制）") {
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
            .padding(.top, 4)
        }
    }
}
