import SwiftUI

/// 「自动翻译语言」清单窗口。
///
/// 需求：列出**设置了检测到什么语言会自动翻译**，每种语言可单独下载语言包、可删除；
/// 右下角「增加检测语言」（进入语言选择窗口）与「取消」（退出窗口）。
struct TranslationLanguageListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var packStore = TranslationPackStore.shared
    /// 语言选择窗口
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("自动翻译的语言"))
                    .font(.headline)
                InfoHint(text: L("只有检测到这些语言的推文才会自动翻译。\n每种语言需要对应的翻译语言包（由系统提供、本地翻译，不消耗 X 配额）。"))
                Spacer()
                if !packStore.languages.isEmpty {
                    Button(L("刷新状态")) { Task { await packStore.refreshAll() } }
                        .compatGlassButton()
                        .controlSize(.small)
                }
            }
            .padding(16)

            Divider()

            if packStore.languages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(L("还没有设置自动翻译的语言"))
                        .foregroundStyle(.secondary)
                    Text(L("点击右下角「增加检测语言」来选择"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(packStore.languages, id: \.self) { code in
                            row(code)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 240, maxHeight: 380)
            }

            Divider()

            HStack {
                Spacer()
                Button(L("增加检测语言")) { showPicker = true }
                    .compatGlassProminentButton()
                Button(L("取消")) { dismiss() }
                    .compatGlassButton()
            }
            .padding(16)
        }
        .frame(width: 520)
        .sheet(isPresented: $showPicker) {
            TranslationLanguagePickerSheet { added in
                packStore.add(added)
                // 需求：添加后询问是否立刻下载语言包
                pendingDownloadConfirm = added
            }
        }
        .task { await packStore.refreshAll() }
        // 语言包下载需要一个挂 translationTask 的载体（macOS 15 的限制，见该文件注释）
        .background(TranslationPackDownloader())
        // 「是否立即下载」确认
        .confirmationDialog(
            L("立即下载所选语言的语言包？"),
            isPresented: Binding(get: { pendingDownloadConfirm != nil },
                                 set: { if !$0 { pendingDownloadConfirm = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("立即下载")) {
                if let list = pendingDownloadConfirm {
                    packStore.requestDownloadAll(list)
                }
                pendingDownloadConfirm = nil
            }
            Button(L("稍后"), role: .cancel) { pendingDownloadConfirm = nil }
        } message: {
            Text(L("语言包由系统提供并本地翻译，下载后可离线使用。\n下载期间系统可能弹出一次确认，这是系统行为。"))
        }
    }

    @State private var pendingDownloadConfirm: [String]?

    /// 单行：语言名 + 包状态 + 下载/删除
    private func row(_ code: String) -> some View {
        let status = packStore.statuses[code] ?? .unknown
        let isDownloading = packStore.downloadingLanguage == code
        return HStack(spacing: 10) {
            Text(displayName(for: code))
                .font(.callout)
            Text(code.uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            Spacer()

            // 语言包状态标签
            if isDownloading {
                ProgressView().controlSize(.small)
                Text(L("下载中…")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(status.isInstalled ? .green : .secondary)
            }

            // 下载按钮：仅"可下载"时可用
            Button {
                packStore.requestDownload(languageCode: code)
            } label: {
                Label(L("下载语言包"), systemImage: "arrow.down.circle")
                    .font(.caption)
            }
            .compatGlassButton()
            .controlSize(.small)
            .disabled(status.isInstalled || isDownloading || !status.canDownload)

            // 删除
            Button(role: .destructive) {
                packStore.remove(code)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help(L("从自动翻译清单中移除（不会卸载系统语言包）"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .task { await packStore.refreshStatus(for: code) }
    }

    /// 语言码 → 本地化语言名
    private func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

/// 语言选择窗口：搜索 + 多选（有 UI 反馈）+ 「添加所选」。
struct TranslationLanguagePickerSheet: View {
    /// 回调：用户确认要添加的语言码
    var onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = TranslationPackStore.shared
    @State private var all: [SupportedLanguage] = []
    @State private var selected: Set<String> = []
    @State private var searchText = ""
    @State private var loading = true

    private var filtered: [SupportedLanguage] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.displayName.lowercased().contains(q) || $0.code.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 搜索
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("搜索语言"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if loading {
                ProgressView(L("正在获取支持的语言…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { lang in
                            pickRow(lang)
                        }
                        if filtered.isEmpty {
                            Text(L("没有匹配的语言"))
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(20)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 280, maxHeight: 420)
            }

            Divider()

            HStack {
                Text(L("已选") + " \(selected.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("添加所选")) {
                    // 按 all 的顺序输出，保证顺序可预期
                    let picked = all.map(\.code).filter { selected.contains($0) }
                    onAdd(picked)
                    dismiss()
                }
                .compatGlassProminentButton()
                .disabled(selected.isEmpty)
                Button(L("取消")) { dismiss() }
                    .compatGlassButton()
            }
            .padding(16)
        }
        .frame(width: 460)
        .task {
            all = await store.allSupportedLanguages()
            loading = false
        }
    }

    /// 单行（点击切换选中；选中态有明确 UI 反馈）
    private func pickRow(_ lang: SupportedLanguage) -> some View {
        let isOn = selected.contains(lang.code)
        return Button {
            if isOn { selected.remove(lang.code) } else { selected.insert(lang.code) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Text(lang.displayName)
                    .foregroundStyle(.primary)
                Text(lang.code.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isOn ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
