import XCTest
@testable import XSpiderMac

/// 本轮（`Settings.currentSchemaVersion = 2`）拍板的 4 个默认值。
///
/// 这些断言是**契约**：改动默认值必须同时 +1 版本号并更新本文件的期望，
/// 否则老用户拿不到新默认值（一次性覆盖不会再触发）。
final class SettingsSchemaDefaultsTests: XCTestCase {

    /// 全新安装（无持久化数据）：4 个键必须是本轮拍板的新默认值，且已打标记。
    func testFreshInstallUsesNewDefaults() {
        let (settings, didOverride) = SettingsStore.load(from: nil)

        XCTAssertTrue(didOverride, "全新安装也要打标记（否则每次启动都会重走覆盖）")
        XCTAssertEqual(settings.settingsSchemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(settings.sameFileCheckModeValue, .centralized, "下载判定依据默认集中式")
        XCTAssertEqual(settings.syncCheckModeValue, .centralized, "同步判定依据默认集中式")
        XCTAssertTrue(settings.appendUniqueIdUserEnabled, "文件名追加唯一标识默认打开")
        XCTAssertEqual(settings.recordsFormValue, .centralized, "导入/导出/重建形态默认集中式")
    }

    /// `Settings()` 的默认构造必须和覆盖后的值一致——
    /// 否则"新装用户"与"老用户被覆盖后"会看到两套默认值。
    func testDefaultInitMatchesOverriddenDefaults() {
        let fresh = Settings()
        XCTAssertEqual(fresh.sameFileCheckModeValue, .centralized)
        XCTAssertEqual(fresh.syncCheckModeValue, .centralized)
        XCTAssertTrue(fresh.appendUniqueIdUserEnabled)
        XCTAssertEqual(fresh.recordsFormValue, .centralized)
    }

    /// 老配置（无标记 + 旧值）→ 4 个键被直接顶成新默认值，标记写上。
    ///
    /// 「旧值失联是预期结果」：`recordFile` / `syncRecordFile` **不做**语义映射。
    ///
    /// 老配置的字节由**真实编码**产生（`Settings` 的嵌套对象用的是合成 Codable，
    /// 手写半截 JSON 会因缺键解不出来——那不是产品行为，是 fixture 不真实），
    /// 再逐键塞进旧值：其余设置一律给哨兵值，用来证明"只覆盖这 4 个键"。
    func testLegacyConfigIsOverriddenOnce() throws {
        var legacy = Settings()
        legacy.settingsSchemaVersion = nil          // 老配置：标记缺失
        // ── 4 个目标键的旧值 ──
        legacy.download.sameFileCheckMode = "recordFile"
        legacy.sync.syncCheckMode = "syncRecordFile"
        legacy.download.appendUniqueId = false
        legacy.download.recordsForm = nil
        // ── 其余设置的哨兵值（用来断言"一个字节都不动"）──
        legacy.download.saveDirBase = "/tmp/legacy"
        legacy.download.accountSubfolder = false
        legacy.download.recordFileName = ".downloaded.json"
        legacy.sync.layout = "honeycomb"
        legacy.app.language = "en"
        legacy.app.fontSize = 16
        legacy.proxy.enable = true
        legacy.proxy.useSystem = false
        legacy.proxy.url = "http://127.0.0.1:17890"

        let data = try JSONEncoder().encode(legacy)
        // 断言 fixture 本身可信：编码后确实**没有**版本标记（nil 会被省略）
        let rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(rawObject["settingsSchemaVersion"], "老配置的字节里没有版本标记——这正是覆盖的触发条件")

        let (settings, didOverride) = SettingsStore.load(from: data)

        XCTAssertTrue(didOverride, "老配置必须被覆盖")
        XCTAssertEqual(settings.settingsSchemaVersion, Settings.currentSchemaVersion, "标记已打")

        // ── 被覆盖的 4 个键 ──
        XCTAssertEqual(settings.sameFileCheckModeValue, .centralized,
                       "旧值 recordFile 不映射，直接覆盖成 centralized")
        XCTAssertEqual(settings.syncCheckModeValue, .centralized,
                       "旧值 syncRecordFile 不映射，直接覆盖成 centralized")
        XCTAssertTrue(settings.appendUniqueIdUserEnabled, "旧的 appendUniqueId=false 被覆盖成打开")
        XCTAssertEqual(settings.recordsFormValue, .centralized)

        // ── 其余设置一个字节都不动 ──
        XCTAssertEqual(settings.download.saveDirBase, "/tmp/legacy", "保存路径不得被碰")
        XCTAssertEqual(settings.download.accountSubfolder, false, "子文件夹开关不得被碰")
        XCTAssertEqual(settings.download.recordFileName, ".downloaded.json", "记录文件名不得被碰")
        XCTAssertEqual(settings.sync.layout, "honeycomb", "同步页布局不得被碰")
        XCTAssertEqual(settings.app.language, "en", "语言不得被碰")
        XCTAssertEqual(settings.app.fontSize, 16, "字号不得被碰")
        XCTAssertEqual(settings.proxy.enable, true, "代理不得被碰")
        XCTAssertEqual(settings.proxy.url, "http://127.0.0.1:17890")
    }

    /// 已打标记且用户选了别的值 → 原样尊重，不被覆盖。
    ///
    /// 这是"此后完全尊重用户的选择"那条要求的回归：少了它，用户每次启动
    /// 都会被改回集中式（上一轮 `migratedCheckMode` 就是这个毛病）。
    func testAlreadyMarkedConfigRespectsUserChoice() throws {
        var chosen = Settings()
        chosen.settingsSchemaVersion = 2            // 已打过标记
        // 用户主动改成了这四个"非默认"值
        chosen.sameFileCheckModeValue = .fileName
        chosen.syncCheckModeValue = .fileName
        chosen.appendUniqueIdUserEnabled = false
        chosen.recordsFormValue = .distributed
        chosen.download.saveDirBase = "/tmp/mine"

        let data = try JSONEncoder().encode(chosen)
        let (settings, didOverride) = SettingsStore.load(from: data)

        XCTAssertFalse(didOverride, "已打标记 → 不再覆盖")
        XCTAssertEqual(settings.settingsSchemaVersion, 2)
        XCTAssertEqual(settings.sameFileCheckModeValue, .fileName, "用户选的按文件名必须保留")
        XCTAssertEqual(settings.syncCheckModeValue, .fileName)
        XCTAssertFalse(settings.appendUniqueIdUserEnabled, "用户主动关掉的开关必须保留")
        XCTAssertEqual(settings.recordsFormValue, .distributed, "用户选的记录形态必须保留")
        XCTAssertEqual(settings.download.saveDirBase, "/tmp/mine")
    }

    /// 更高版本标记（将来 v3 写的配置被旧版读到）也**不**覆盖——
    /// 只认"缺失或 < 当前版本"，不比大小以外的东西。
    func testFutureSchemaVersionIsNotOverridden() throws {
        var future = Settings()
        future.settingsSchemaVersion = 99
        future.sameFileCheckModeValue = .fileName

        let data = try JSONEncoder().encode(future)
        let (settings, didOverride) = SettingsStore.load(from: data)
        XCTAssertFalse(didOverride)
        XCTAssertEqual(settings.sameFileCheckModeValue, .fileName, "版本号更高时不得回退用户值")
    }

    /// 覆盖只跑一次：连续两次载入同一份老配置，第二次不再覆盖
    /// （模拟"覆盖后落盘 → 下次启动读到的是已打标记的版本"）。
    func testOverrideIsIdempotent() throws {
        var legacy = Settings()
        legacy.settingsSchemaVersion = nil
        legacy.download.sameFileCheckMode = "recordFile"
        legacy.download.appendUniqueId = false
        let legacyData = try JSONEncoder().encode(legacy)

        let (first, didOverrideFirst) = SettingsStore.load(from: legacyData)
        XCTAssertTrue(didOverrideFirst)

        // 模拟落盘（设置被编码写回）
        let persisted = try JSONEncoder().encode(first)
        let (second, didOverrideSecond) = SettingsStore.load(from: persisted)
        XCTAssertFalse(didOverrideSecond, "第二次载入不得再覆盖")
        XCTAssertEqual(second.settingsSchemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(second.sameFileCheckModeValue, .centralized)
    }

    /// 损坏的持久化数据（解不出来）→ 落到全新默认值，且打上标记。
    func testCorruptDataFallsBackToDefaults() {
        let (settings, didOverride) = SettingsStore.load(from: Data("not json at all".utf8))
        XCTAssertTrue(didOverride)
        XCTAssertEqual(settings.sameFileCheckModeValue, .centralized)
        XCTAssertEqual(settings.recordsFormValue, .centralized)
        XCTAssertTrue(settings.appendUniqueIdUserEnabled)
    }

    /// 覆盖只碰 4 个键 + 版本标记：编码一轮后逐键比对（防"顺手多改了一个"）。
    func testOverrideTouchesExactlyFourKeysPlusMarker() throws {
        var before = Settings()
        before.download.saveDirBase = "/tmp/x"
        before.download.recordFileName = "my.json"
        before.sameFileCheckModeValue = .fileName
        before.syncCheckModeValue = .fileName
        before.appendUniqueIdUserEnabled = false
        before.recordsFormValue = .distributed
        before.settingsSchemaVersion = nil

        var after = before
        XCTAssertTrue(after.applySchemaDefaultsOnce())

        // 4 个目标键都变了
        XCTAssertEqual(after.sameFileCheckModeValue, .centralized)
        XCTAssertEqual(after.syncCheckModeValue, .centralized)
        XCTAssertTrue(after.appendUniqueIdUserEnabled)
        XCTAssertEqual(after.recordsFormValue, .centralized)
        // 标记写上
        XCTAssertEqual(after.settingsSchemaVersion, Settings.currentSchemaVersion)

        // 覆盖前后的**逐键 diff**：不同的键集必须恰好是这 4 个 + 版本标记。
        //
        // 逐键摊平后比较而不是比原始字节：`JSONEncoder` 对同一个值不保证逐字节稳定
        // （实测长度相同、键序不同 → 字节比较会假红）。
        let beforeFlat = try flatten(JSONSerialization.jsonObject(with: JSONEncoder().encode(before)))
        let afterFlat = try flatten(JSONSerialization.jsonObject(with: JSONEncoder().encode(after)))
        let changed = Set(beforeFlat.keys).union(afterFlat.keys).sorted()
            .filter { beforeFlat[$0] != afterFlat[$0] }
        XCTAssertEqual(changed, [
            "download.appendUniqueId",
            "download.recordsForm",
            "download.sameFileCheckMode",
            "settingsSchemaVersion",
            "sync.syncCheckMode",
        ], "覆盖只允许碰这 4 个键与版本标记，实际不同的键：\(changed)")
    }

    /// 把嵌套 JSON 摊平成 `路径 → 值`，便于逐键比对并指出**哪个键**不同。
    private func flatten(_ object: Any, prefix: String = "") throws -> [String: String] {
        guard let dict = object as? [String: Any] else {
            throw NSError(domain: "flatten", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(prefix) 不是 JSON 对象"])
        }
        var out: [String: String] = [:]
        for (key, value) in dict {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                out.merge(try flatten(nested, prefix: path)) { _, new in new }
            } else {
                out[path] = "\(value)"
            }
        }
        return out
    }
}

// MARK: - F4：导入/导出/重建的形态不跟判定依据走

/// 形态解析是从设置读的纯逻辑，不依赖视图。
///
/// 回归：此前 `SettingsView.currentForm` 从**下载判定**推断——
/// 判定选「按文件名」时一律按分布式走，于是集中式记录既导不出也写不回。
@MainActor
final class RecordFormSettingTests: XCTestCase {

    /// 关键回归：**判定依据怎么变，都不影响形态**。
    func testRecordFormDoesNotFollowCheckMode() {
        var settings = Settings()

        // 判定选「按文件名」（旧实现下这一支会强制走分布式）
        settings.sameFileCheckModeValue = .fileName
        settings.recordsFormValue = .centralized
        XCTAssertEqual(settings.recordsFormValue, .centralized,
                       "判定按文件名时，形态仍须是用户显式选的那一个")

        // 判定选分布式，形态选集中式
        settings.sameFileCheckModeValue = .distributed
        XCTAssertEqual(settings.recordsFormValue, .centralized)

        // 同步判定也不得影响它
        settings.syncCheckModeValue = .fileName
        XCTAssertEqual(settings.recordsFormValue, .centralized)
    }

    /// 缺省（老配置没有这个键 / 值认不出来）→ 集中式。
    func testMissingOrUnknownFormFallsBackToCentralized() {
        var settings = Settings()
        settings.download.recordsForm = nil
        XCTAssertEqual(settings.recordsFormValue, .centralized, "缺省 = 集中式")

        settings.download.recordsForm = "garbage"
        XCTAssertEqual(settings.recordsFormValue, .centralized, "认不出来也落到集中式")
    }

    /// 形态随持久化往返不丢。
    func testRecordFormSurvivesPersistAndReload() throws {
        var settings = Settings()
        settings.recordsFormValue = .distributed
        let data = try JSONEncoder().encode(settings)
        let reloaded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(reloaded.recordsFormValue, .distributed, "重启后形态不得被改")
    }

    /// 「记录文件名」的可编辑条件：判定依据**或**记录形态任一是分布式。
    ///
    /// 这个名字有两个消费方：下载判定（走判定依据）与三个记录入口（走记录形态）。
    /// 只按判定依据禁用，会让「判定集中式 + 形态分布式」的用户改不了
    /// 那三个入口正在用的文件名。
    func testRecordFileNameIsEditableWhenEitherSideUsesDistributed() {
        var settings = Settings()

        // 两边都集中式 → 不可编辑（这个名字没人用）
        settings.sameFileCheckModeValue = .centralized
        settings.recordsFormValue = .centralized
        XCTAssertFalse(settings.recordFileNameEditable)

        // 判定集中式 + 形态分布式 → **可编辑**（三个入口在用）
        settings.recordsFormValue = .distributed
        XCTAssertTrue(settings.recordFileNameEditable)

        // 判定分布式 + 形态集中式 → 可编辑（下载判定在用）
        settings.sameFileCheckModeValue = .distributed
        settings.recordsFormValue = .centralized
        XCTAssertTrue(settings.recordFileNameEditable)

        // 判定按文件名（不用记录）但形态分布式 → 可编辑
        settings.sameFileCheckModeValue = .fileName
        settings.recordsFormValue = .distributed
        XCTAssertTrue(settings.recordFileNameEditable)
    }
}

// MARK: - F8：判定缓存自动失效真的接上了

/// 回归：`SettingsStore.applyJudgementIfChanged()` 曾是死代码（全仓无调用点），
/// 指纹空转；实际只靠设置界面里手写的 `refreshDownloadedCaches()` 兜着，
/// 于是「选择…」按钮（`selectSaveDir`）漏了刷新。
@MainActor
final class JudgementInvalidationTests: XCTestCase {

    /// 指纹变化 → 走一次失效；指纹不变 → 不动（设置页每次按键都会 save）。
    func testFingerprintChangesOnlyOnJudgementInputs() {
        let store = SettingsStore.shared
        let baseVersion = DownloadStore.shared.judgementVersion

        // 与判定无关的设置变更：指纹不变 → 版本号不得变
        let originalWriteLogs = store.settings.app.writeLogs
        store.settings.app.writeLogs = !originalWriteLogs
        XCTAssertEqual(DownloadStore.shared.judgementVersion, baseVersion,
                       "写日志开关与判定无关，不得触发失效")
        store.settings.app.writeLogs = originalWriteLogs

        // 保存路径变化（「选择…」按钮那条路径）→ 失效
        let originalDir = store.settings.download.saveDirBase
        store.settings.download.saveDirBase = originalDir + "-wf-test"
        XCTAssertGreaterThan(DownloadStore.shared.judgementVersion, baseVersion,
                             "保存路径变化必须让判定失效（selectSaveDir 漏刷新就是这条）")
        store.settings.download.saveDirBase = originalDir

        // 复原也要能再次失效（指纹是双向的，不是单向递增）
        let afterRestore = DownloadStore.shared.judgementVersion
        store.settings.download.saveDirBase = originalDir + "-wf-test-2"
        XCTAssertGreaterThan(DownloadStore.shared.judgementVersion, afterRestore)
        store.settings.download.saveDirBase = originalDir
    }

    /// 判定依据 / 同步判定 / 唯一标识 三个键任一变化都要失效。
    func testEachJudgementKeyTriggersInvalidation() {
        let store = SettingsStore.shared
        let snapshot = StoreSnapshot()
        defer { snapshot.restore() }

        let mutations: [(String, () -> Void)] = [
            ("下载判定", { store.settings.download.sameFileCheckMode = SameFileCheckMode.fileName.rawValue }),
            ("同步判定", { store.settings.sync.syncCheckMode = SyncCheckMode.fileName.rawValue }),
            ("唯一标识", { store.settings.download.appendUniqueId = false }),
            ("跳过开关", { store.settings.download.sameFileSkip = false }),
            ("子文件夹", { store.settings.download.accountSubfolder = false }),
        ]
        for (label, mutate) in mutations {
            let before = DownloadStore.shared.judgementVersion
            mutate()
            XCTAssertGreaterThan(DownloadStore.shared.judgementVersion, before,
                                 "\(label)变化必须让判定失效")
        }
    }
}

// MARK: - F10：界面文案与规范一致
/// 回归：「按账号创建子文件夹」的提示还写着旧命名「保存路径/昵称-@用户名」，
/// 与 `MEDIA_RECORDS.md` §5.1 的 `昵称-用户名[数字id]` 不符——
/// 用户按提示去核对目录会找不到（旧文件夹根本不会被读取）。
final class AccountFolderHintTests: XCTestCase {

    /// 规范 §5.1 的例子：昵称 Tesla、用户名 Tesla、id 13298072 → `Tesla-Tesla[13298072]`
    private let specExample = "Tesla-Tesla[13298072]"

    func testHintMatchesSpecNaming() {
        for lang in [Settings.Language.zhHans, .zhHant, .en] {
            L10n.language = lang
            let hint = L("开启后，资源将保存到「保存路径/昵称-用户名[数字id]」文件夹中，例如：Tesla-Tesla[13298072]。")
            XCTAssertFalse(hint.contains("@"),
                           "\(lang.rawValue)：提示里不得再出现旧命名的 @（用户会去找不存在的目录）")
            XCTAssertTrue(hint.contains(specExample),
                          "\(lang.rawValue)：提示必须给出规范 §5.1 的例子 \(specExample)，实际：\(hint)")
        }
        L10n.language = .zhHans
    }

    /// 旧命名与规范命名必须是**两条不同的 key**——否则改了视图会连带
    /// 改到另一条带「，如：」的变体（它属于别的界面）。
    func testOldAndNewHintsAreDistinctKeys() {
        L10n.language = .zhHans
        let newHint = L("开启后，资源将保存到「保存路径/昵称-用户名[数字id]」文件夹中，例如：Tesla-Tesla[13298072]。")
        let legacyVariant = L("开启后，资源将保存到「保存路径/昵称-@用户名」文件夹中，如：")
        XCTAssertNotEqual(newHint, legacyVariant, "两条提示是不同 key，不得互相顶掉")
        XCTAssertTrue(legacyVariant.contains("@"),
                      "带有「，如：」的那条是另一个界面的文案，本轮的 key 必须与它完全一致")
    }

    /// 规范里的解析规则：文件夹名的 `[数字id]` 是唯一身份依据（§5.1）。
    /// 提示给出的例子必须真的能解析出同一个 id。
    func testHintExampleParsesBackToUserId() {
        XCTAssertEqual(AccountFolder.accountId(fromFolderName: specExample), "13298072",
                       "提示给出的例子必须能被 AccountFolder 反解出账号 id")
    }
}
