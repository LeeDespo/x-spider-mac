import XCTest
@testable import XSpiderMac

/// 导入导出 / 按文件名重建（`MEDIA_RECORDS.md` §7/§8）回归测试。
///
/// 全部在临时目录里跑：`MediaRecords` 用注入的临时 `centralRoot`，
/// 保存路径与导出文件也都在临时目录，**绝不触碰**用户真实的
/// `~/Library/Application Support/XSpiderMac` 与下载目录。
///
/// 覆盖：导出→导入往返、追加合并（id 并集 / anchor 取较晚）、
/// 从分布式扫描导入、按文件名重建（识别与无法识别）、覆盖模式、重复导入幂等、
/// 非原子跳过（导入包里没有的账号不动）。
final class RecordsIOTests: XCTestCase {

    private var tempDir: URL!
    private var saveDir: URL!
    private var records: MediaRecords!

    /// 一个"账号"的媒体文件所在文件夹（契约 §5.1 的命名）
    private func accountDir(_ name: String, _ screenName: String, _ userId: String) -> URL {
        saveDir.appendingPathComponent(AccountFolder.name(name: name, screenName: screenName,
                                                          userId: userId), isDirectory: true)
    }

    /// 造一个看着像本应用下载的媒体文件（adoptMode 检测的是**没有被 adopt 的**数据库）
    private func makeMediaFile(in dir: URL, named name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: dir.appendingPathComponent(name))
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordsIOTests-\(UUID().uuidString)")
        saveDir = tempDir.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        records = MediaRecords(centralRoot: tempDir.appendingPathComponent("central"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 导出

    func testExportCentralizedCollectsBothKinds() throws {
        let first = records.centralDownloadURL(userId: "13298072")
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["b", "a"]), fileURL: first)
        try records.writeDownload(DownloadRecord(userId: "999", ids: ["z"]),
                                  fileURL: records.centralDownloadURL(userId: "999"))
        try records.setSyncAccount(userId: "13298072", anchorDay: "2026-09-29", ids: ["m1", "m2"],
                                   fileURL: records.centralSyncURL)

        let export = try RecordsIO.exportRecords(form: .centralized, saveDir: saveDir.path,
                                                 records: records)
        XCTAssertTrue(export.isValid)
        XCTAssertEqual(export.downloads["13298072"], ["a", "b"], "ids 必须去重 + 字典序")
        XCTAssertEqual(export.downloads["999"], ["z"])
        XCTAssertEqual(export.sync["13298072"]?.anchorDay, "2026-09-29")
        XCTAssertEqual(export.sync["13298072"]?.ids, ["m1", "m2"])
    }

    /// 分布式导出 = 扫保存路径下所有账号文件夹合并
    func testExportDistributedScansAccountFolders() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        let other = accountDir("别的昵称", "other", "42")
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["m1", "m2"]),
                                  fileURL: records.distributedDownloadURL(accountDir: tesla.path))
        try records.writeDownload(DownloadRecord(userId: "42", ids: ["m3"]),
                                  fileURL: records.distributedDownloadURL(accountDir: other.path))
        try records.writeSync(SyncRecord(accounts: ["13298072": SyncAccountRecord(anchorDay: "2026-09-29", ids: ["m1"])]),
                              fileURL: records.distributedSyncURL(accountDir: tesla.path))

        let export = try RecordsIO.exportRecords(form: .distributed, saveDir: saveDir.path,
                                                 records: records)
        XCTAssertEqual(export.downloads["13298072"], ["m1", "m2"])
        XCTAssertEqual(export.downloads["42"], ["m3"])
        XCTAssertEqual(export.sync["13298072"]?.anchorDay, "2026-09-29")

        // 旧命名的文件夹（没有 [数字id]）不被读取：不迁移、不兼容
        let legacy = saveDir.appendingPathComponent("Tesla-@Tesla", isDirectory: true)
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["old"]),
                                  fileURL: records.distributedDownloadURL(accountDir: legacy.path))
        let after = try RecordsIO.exportRecords(form: .distributed, saveDir: saveDir.path,
                                                records: records)
        XCTAssertEqual(after.downloads["13298072"], ["m1", "m2"], "旧命名文件夹不得被读进来")
    }

    // MARK: - 导出 → 导入 往返

    func testExportImportRoundTrip() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["m1", "m2"]),
                                  fileURL: records.distributedDownloadURL(accountDir: tesla.path))
        // 同步记录写在分布式形态里（导出「当前形态」，这里形态 = distributed）
        try records.setSyncAccount(userId: "13298072", anchorDay: "2026-09-29", ids: ["m1"],
                                   fileURL: records.distributedSyncURL(accountDir: tesla.path))
        let export = try RecordsIO.exportRecords(form: .distributed, saveDir: saveDir.path,
                                                 records: records)
        let exportURL = tempDir.appendingPathComponent("export.json")
        try MediaRecordJSON.writeAtomically(try MediaRecordJSON.encode(export), to: exportURL)

        // 清空后用导出文件导入集中式形态
        records.invalidate()
        try FileManager.default.removeItem(at: saveDir)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: records.centralRoot)
        records.invalidate()

        let report = try RecordsIO.importRecords(from: .exportFile(exportURL), into: .centralized,
                                                 strategy: .merge, saveDir: saveDir.path,
                                                 records: records)
        XCTAssertEqual(report.addedEntries, 3, "m1/m2 下载 + m1 同步，共 3 条对")
        XCTAssertEqual(report.unrecognizedEntries, 0)
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids, ["m1", "m2"])
        XCTAssertEqual(records.loadSync(fileURL: records.centralSyncURL)?.accounts["13298072"]?.anchorDay,
                       "2026-09-29")

        // 导出 → 导入 → 再导出：内容一致（往返无损）
        let again = try RecordsIO.exportRecords(form: .centralized, saveDir: saveDir.path,
                                                records: records)
        XCTAssertEqual(again.downloads, export.downloads)
        XCTAssertEqual(again.sync, export.sync)
    }

    func testImportRejectsBrokenExportFile() throws {
        let bad = tempDir.appendingPathComponent("bad.json")
        try Data(#"{"version":1,"kind":"xspider.download-record","ids":[]}"#.utf8).write(to: bad)

        XCTAssertThrowsError(try RecordsIO.importRecords(from: .exportFile(bad), into: .centralized,
                                                         strategy: .merge, saveDir: saveDir.path,
                                                         records: records)) { error in
            XCTAssertEqual(error as? RecordIOError, .invalidExportFile)
        }

        let missing = tempDir.appendingPathComponent("nope.json")
        XCTAssertThrowsError(try RecordsIO.importRecords(from: .exportFile(missing), into: .centralized,
                                                         strategy: .merge, saveDir: saveDir.path,
                                                         records: records))
    }

    // MARK: - 追加合并（并集 / 较晚 anchor）

    func testMergeUnionsIdsAndTakesLaterAnchor() throws {
        // 现有：anchor 2026-09-28，ids [m1, m2]
        try records.setSyncAccount(userId: "13298072", anchorDay: "2026-09-28", ids: ["m1", "m2"],
                                   fileURL: records.centralSyncURL)
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["m1"]),
                                  fileURL: records.centralDownloadURL(userId: "13298072"))

        let incoming = RecordsExport(
            downloads: ["13298072": ["m2", "m3"]],
            sync: ["13298072": SyncAccountRecord(anchorDay: "2026-09-29", ids: ["m3"])])
        let url = tempDir.appendingPathComponent("in.json")
        try MediaRecordJSON.writeAtomically(try MediaRecordJSON.encode(incoming), to: url)

        let report = try RecordsIO.importRecords(from: .exportFile(url), into: .centralized,
                                                 strategy: .merge, saveDir: saveDir.path,
                                                 records: records)
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids, ["m1", "m2", "m3"],
                       "追加 = id 并集")
        XCTAssertEqual(records.loadSync(fileURL: records.centralSyncURL)?.accounts["13298072"]?.anchorDay,
                       "2026-09-29", "anchor 取较晚者")
        XCTAssertEqual(records.loadSync(fileURL: records.centralSyncURL)?.accounts["13298072"]?.ids,
                       ["m1", "m2", "m3"])
        XCTAssertEqual(report.addedEntries, 3,
                       "下载侧 m2/m3 是新的（2 条）+ 同步侧只有 m3 是新的（1 条）")
    }

    /// anchor 更早的导入不得把现有 anchor 拉回去
    func testMergeKeepsLaterAnchorWhenIncomingIsOlder() throws {
        try records.setSyncAccount(userId: "1", anchorDay: "2026-09-29", ids: ["a"],
                                   fileURL: records.centralSyncURL)
        let incoming = RecordsExport(sync: ["1": SyncAccountRecord(anchorDay: "2026-09-25", ids: ["b"])])
        let url = tempDir.appendingPathComponent("old.json")
        try MediaRecordJSON.writeAtomically(try MediaRecordJSON.encode(incoming), to: url)

        _ = try RecordsIO.importRecords(from: .exportFile(url), into: .centralized,
                                        strategy: .merge, saveDir: saveDir.path, records: records)
        let entry = records.loadSync(fileURL: records.centralSyncURL)?.accounts["1"]
        XCTAssertEqual(entry?.anchorDay, "2026-09-29", "较晚的 anchor 必须保留")
        XCTAssertEqual(entry?.ids, ["a", "b"])
    }

    // MARK: - 重复导入幂等

    func testRepeatedImportIsIdempotent() throws {
        let incoming = RecordsExport(
            downloads: ["13298072": ["m1", "m2"]],
            sync: ["13298072": SyncAccountRecord(anchorDay: "2026-09-29", ids: ["m1"])])
        let url = tempDir.appendingPathComponent("in.json")
        try MediaRecordJSON.writeAtomically(try MediaRecordJSON.encode(incoming), to: url)

        let first = try RecordsIO.importRecords(from: .exportFile(url), into: .centralized,
                                                strategy: .merge, saveDir: saveDir.path,
                                                records: records)
        let afterFirst = try MediaRecordJSON.encode(
            records.loadCentralDownload(userId: "13298072")!) + MediaRecordJSON.encode(
            records.loadSync(fileURL: records.centralSyncURL)!)

        let second = try RecordsIO.importRecords(from: .exportFile(url), into: .centralized,
                                                 strategy: .merge, saveDir: saveDir.path,
                                                 records: records)
        let afterSecond = try MediaRecordJSON.encode(
            records.loadCentralDownload(userId: "13298072")!) + MediaRecordJSON.encode(
            records.loadSync(fileURL: records.centralSyncURL)!)

        XCTAssertEqual(first.addedEntries, 3)
        XCTAssertEqual(second.addedEntries, 0, "第二次导入不得新增任何条目")
        XCTAssertEqual(second.recognizedAccounts, 1)
        XCTAssertEqual(afterFirst, afterSecond, "重复导入必须不改动记录（逐字节相同）")

        // 幂等也覆盖同步条目（anchor 与 ids 都不变）
        XCTAssertEqual(records.loadSync(fileURL: records.centralSyncURL)?.accounts["13298072"]?.ids, ["m1"])
    }

    // MARK: - 从分布式记录文件导入

    func testImportFromDistributedRecords() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        let other = accountDir("Other", "other", "42")
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["m1", "m2"]),
                                  fileURL: records.distributedDownloadURL(accountDir: tesla.path))
        try records.writeDownload(DownloadRecord(userId: "42", ids: ["m3"]),
                                  fileURL: records.distributedDownloadURL(accountDir: other.path))
        try records.writeSync(SyncRecord(accounts: [
            "13298072": SyncAccountRecord(anchorDay: "2026-09-29", ids: ["m1"]),
            "42": SyncAccountRecord(anchorDay: "2026-09-20", ids: ["m3"]),
        ]), fileURL: records.distributedSyncURL(accountDir: tesla.path))

        // 再导入回分布式：两个账号的记录都要回来
        let report = try RecordsIO.importRecords(from: .distributedRecords(saveDir: saveDir.path),
                                                 into: .distributed, strategy: .merge,
                                                 saveDir: saveDir.path, records: records)
        XCTAssertEqual(report.recognizedAccounts, 2, "扫到 13298072 与 42 两个账号")
        XCTAssertEqual(report.addedEntries, 0, "原样导入自己的记录 = 没有新增")

        // 清空集中式目标形态，再导入 → 记录被搬回来
        try? FileManager.default.removeItem(at: records.centralRoot)
        records.invalidate()
        let report2 = try RecordsIO.importRecords(from: .distributedRecords(saveDir: saveDir.path),
                                                  into: .centralized, strategy: .merge,
                                                  saveDir: saveDir.path, records: records)
        XCTAssertEqual(report2.addedEntries, 5,
                       "下载 3 条（13298072 两条 + 42 一条）+ 同步 2 条 = 5 条对")
        XCTAssertEqual(report2.recognizedAccounts, 2)
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids, ["m1", "m2"])
        XCTAssertEqual(records.loadCentralDownload(userId: "42")?.ids, ["m3"])
    }

    /// 从分布式导入到集中式：跨形态搬运
    func testImportFromDistributedIntoCentralized() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["m1"]),
                                  fileURL: records.distributedDownloadURL(accountDir: tesla.path))
        try records.writeSync(SyncRecord(accounts: ["13298072": SyncAccountRecord(anchorDay: "2026-09-29", ids: ["m1"])]),
                              fileURL: records.distributedSyncURL(accountDir: tesla.path))

        let report = try RecordsIO.importRecords(from: .distributedRecords(saveDir: saveDir.path),
                                                 into: .centralized, strategy: .merge,
                                                 saveDir: saveDir.path, records: records)
        XCTAssertEqual(report.addedEntries, 2)
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids, ["m1"])
        XCTAssertEqual(records.loadSync(fileURL: records.centralSyncURL)?.accounts["13298072"]?.anchorDay,
                       "2026-09-29")
    }

    // MARK: - F7：账号无法确定不得静默

    /// 分布式记录文件里的 `user_id` 为空（写记录时作者 id 取不到留下的）：
    /// 账号按**文件夹名**兜底收下，id 不许无声消失。
    func testDistributedRecordWithEmptyUserIdFallsBackToFolderName() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        try FileManager.default.createDirectory(at: tesla, withIntermediateDirectories: true)
        let url = records.distributedDownloadURL(accountDir: tesla.path)
        // 绕过 writeDownload 的 user_id 归位：直接落一份 user_id 为空的记录
        try Data(#"{"version":1,"kind":"xspider.download-record","user_id":"","ids":["m1","m2"]}"#.utf8)
            .write(to: url)
        records.invalidate()

        let report = try RecordsIO.importRecords(from: .distributedRecords(saveDir: saveDir.path),
                                                 into: .centralized, strategy: .merge,
                                                 saveDir: saveDir.path, records: records)
        XCTAssertEqual(report.unrecognizedEntries, 0, "账号可定位（文件夹名就是身份），不算无法定位")
        XCTAssertEqual(report.recognizedAccounts, 1)
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids, ["m1", "m2"],
                       "空 user_id 的 id 必须按文件夹名兜底收下，不许静默丢")
    }

    /// 导出：同一份空 `user_id` 的分布式记录也要按文件夹名归属，不许静默丢。
    func testExportDistributedWithEmptyUserIdDoesNotDrop() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        try FileManager.default.createDirectory(at: tesla, withIntermediateDirectories: true)
        try Data(#"{"version":1,"kind":"xspider.download-record","user_id":"","ids":["m1"]}"#.utf8)
            .write(to: records.distributedDownloadURL(accountDir: tesla.path))
        records.invalidate()

        let report = try RecordsIO.exportRecordsWithReport(form: .distributed,
                                                           saveDir: saveDir.path, records: records)
        XCTAssertEqual(report.export.downloads["13298072"], ["m1"],
                       "空 user_id 的 id 必须按文件夹名归属（以前导出会整条丢掉）")
        XCTAssertEqual(report.unlocatableEntries, 0)
    }

    /// 保存路径根下（关闭子文件夹）的共享记录 `user_id` 为空：账号无从得知 →
    /// 告警 + 计入「无法定位」，不许静默返回"0 条"。
    func testRootSharedRecordWithEmptyUserIdIsReported() throws {
        try Data(#"{"version":1,"kind":"xspider.download-record","user_id":"","ids":["m1"]}"#.utf8)
            .write(to: saveDir.appendingPathComponent(MediaRecords.defaultDownloadRecordName))
        records.invalidate()

        let report = try RecordsIO.importRecords(from: .distributedRecords(saveDir: saveDir.path),
                                                 into: .centralized, strategy: .merge,
                                                 saveDir: saveDir.path, records: records)
        XCTAssertEqual(report.unrecognizedEntries, 1, "账号无法定位必须计数")
        XCTAssertEqual(report.addedEntries, 0)
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids ?? [], [])

        let export = try RecordsIO.exportRecordsWithReport(form: .distributed,
                                                           saveDir: saveDir.path, records: records)
        XCTAssertEqual(export.unlocatableEntries, 1, "导出同样必须把无法定位报出来")
        XCTAssertTrue(export.export.downloads.isEmpty, "无法定位的 id 不得凭空归到某个账号")
    }

    /// 导出包里有账号为空的条目：计入报告并告警，不许静默 continue。
    func testExportFileWithEmptyAccountIsReported() throws {
        let url = tempDir.appendingPathComponent("empty-account.json")
        try Data(#"""
        {"version":1,"kind":"xspider.records-export",
         "downloads":{"":["m1"],"13298072":["m2"]},
         "sync":{"":{"anchor_day":"2026-09-29","ids":["m3"]}}}
        """#.utf8).write(to: url)

        let report = try RecordsIO.importRecords(from: .exportFile(url), into: .centralized,
                                                 strategy: .merge, saveDir: saveDir.path,
                                                 records: records)
        XCTAssertEqual(report.unrecognizedEntries, 2, "空账号的下载条目与同步条目各计一条")
        XCTAssertEqual(report.addedEntries, 1, "正常账号的 m2 仍然导入")
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids, ["m2"])
    }

    /// 没有 `[数字id]` 的目录里装着记录文件：账号无法定位 → 计入报告，不许整目录静默跳过。
    func testDirWithoutAccountIdIsReportedOnImportAndExport() throws {
        let orphan = saveDir.appendingPathComponent("NoAccountIdFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(#"{"version":1,"kind":"xspider.download-record","user_id":"","ids":["m1"]}"#.utf8)
            .write(to: orphan.appendingPathComponent(MediaRecords.defaultDownloadRecordName))
        records.invalidate()

        let report = try RecordsIO.importRecords(from: .distributedRecords(saveDir: saveDir.path),
                                                 into: .centralized, strategy: .merge,
                                                 saveDir: saveDir.path, records: records)
        XCTAssertEqual(report.unrecognizedEntries, 1, "没有数字 id 的目录里的记录必须计入无法定位")
        XCTAssertEqual(report.addedEntries, 0)

        let export = try RecordsIO.exportRecordsWithReport(form: .distributed,
                                                           saveDir: saveDir.path, records: records)
        XCTAssertEqual(export.unlocatableEntries, 1)
    }

    /// 重建：没有 `[数字id]` 的目录里能解析出媒体 id 的文件计入"无法识别"，
    /// 不许整个目录静默跳过（以前用户只看到"导入完成 0 条"）。
    func testRebuildCountsFilesInDirWithoutAccountId() throws {
        let orphan = saveDir.appendingPathComponent("NoAccountIdFolder", isDirectory: true)
        try makeMediaFile(in: orphan, named: "a[2098843532463411200].jpg")
        try makeMediaFile(in: orphan, named: "readme.txt")

        let report = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .centralized,
                                                        strategy: .merge, records: records)
        XCTAssertEqual(report.recognized, 0)
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.unrecognized, 1, "有媒体 id 但账号无从得知 → 无法识别（readme 忽略）")
    }

    // MARK: - 覆盖模式

    func testOverwriteReplacesOnlyImportedAccounts() throws {
        try records.writeDownload(DownloadRecord(userId: "A", ids: ["a1", "a2", "a3"]),
                                  fileURL: records.centralDownloadURL(userId: "A"))
        try records.writeDownload(DownloadRecord(userId: "B", ids: ["b1"]),
                                  fileURL: records.centralDownloadURL(userId: "B"))
        try records.setSyncAccount(userId: "A", anchorDay: "2026-09-29", ids: ["a1", "a2"],
                                   fileURL: records.centralSyncURL)

        let incoming = RecordsExport(
            downloads: ["A": ["a9"]],
            sync: ["A": SyncAccountRecord(anchorDay: "2026-09-01", ids: ["a9"])])
        let url = tempDir.appendingPathComponent("in.json")
        try MediaRecordJSON.writeAtomically(try MediaRecordJSON.encode(incoming), to: url)

        _ = try RecordsIO.importRecords(from: .exportFile(url), into: .centralized,
                                        strategy: .overwrite, saveDir: saveDir.path, records: records)
        records.invalidate()
        XCTAssertEqual(records.loadCentralDownload(userId: "A")?.ids, ["a9"], "A 被整体替换")
        XCTAssertEqual(records.loadSync(fileURL: records.centralSyncURL)?.accounts["A"]?.ids, ["a9"])
        XCTAssertEqual(records.loadSync(fileURL: records.centralSyncURL)?.accounts["A"]?.anchorDay,
                       "2026-09-01", "覆盖也接受更早的 anchor")
        XCTAssertEqual(records.loadCentralDownload(userId: "B")?.ids, ["b1"],
                       "导入包里没有的账号一个字节都不能动")
    }

    func testOverwriteDistributedMigratesTheForm() throws {
        let a = accountDir("A", "a", "111")
        try records.writeDownload(DownloadRecord(userId: "111", ids: ["m1", "m2"]),
                                  fileURL: records.distributedDownloadURL(accountDir: a.path))

        let incoming = RecordsExport(downloads: ["111": ["m9"]])
        let url = tempDir.appendingPathComponent("in.json")
        try MediaRecordJSON.writeAtomically(try MediaRecordJSON.encode(incoming), to: url)

        _ = try RecordsIO.importRecords(from: .exportFile(url), into: .distributed,
                                        strategy: .overwrite, saveDir: saveDir.path, records: records)
        records.invalidate()
        XCTAssertEqual(records.loadDownload(
            fileURL: records.distributedDownloadURL(accountDir: a.path))?.ids, ["m9"],
            "覆盖写回分布式形态（写进已有账号文件夹）")
    }

    /// 分布式导入：账号文件夹存在就写进去；一个账号文件夹都没有就写根下（§3.4）
    func testDistributedImportFallsBackToRootWhenNoAccountFolders() throws {
        let incoming = RecordsExport(downloads: ["13298072": ["m1"]])
        let url = tempDir.appendingPathComponent("in.json")
        try MediaRecordJSON.writeAtomically(try MediaRecordJSON.encode(incoming), to: url)

        let report = try RecordsIO.importRecords(from: .exportFile(url), into: .distributed,
                                                 strategy: .merge, saveDir: saveDir.path,
                                                 records: records)
        XCTAssertEqual(report.recognizedAccounts, 1)
        XCTAssertEqual(report.unrecognizedEntries, 0)
        records.invalidate()
        let root = saveDir.appendingPathComponent(MediaRecords.defaultDownloadRecordName)
        XCTAssertEqual(records.loadDownload(fileURL: root)?.ids, ["m1"])
    }

    /// 有别的账号文件夹、偏偏没有它的 → 不写（写根下不会被判定读到），计入"无法识别"
    func testDistributedImportWithoutAccountFolderIsReported() throws {
        let other = accountDir("Other", "other", "999")
        try makeMediaFile(in: other, named: "x.jpg")

        let incoming = RecordsExport(downloads: ["13298072": ["m1"]])
        let url = tempDir.appendingPathComponent("in.json")
        try MediaRecordJSON.writeAtomically(try MediaRecordJSON.encode(incoming), to: url)

        let report = try RecordsIO.importRecords(from: .exportFile(url), into: .distributed,
                                                 strategy: .merge, saveDir: saveDir.path,
                                                 records: records)
        XCTAssertEqual(report.recognizedAccounts, 0)
        XCTAssertEqual(report.unrecognizedEntries, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: saveDir.appendingPathComponent(MediaRecords.defaultDownloadRecordName).path),
            "不该在根下写一份永远不会生效的记录")
    }

    /// 同步记录**不回落根目录**：没有账号文件夹时同步条目被计为"无法定位"
    /// （与下载记录不同——`SyncStore` 一律按账号文件夹写 `SyncStore.accountDirectory`）
    func testDistributedSyncImportNeverFallsBackToRoot() throws {
        let incoming = RecordsExport(sync: ["13298072": SyncAccountRecord(anchorDay: "2026-09-29", ids: ["m1"])])
        let url = tempDir.appendingPathComponent("in.json")
        try MediaRecordJSON.writeAtomically(try MediaRecordJSON.encode(incoming), to: url)

        let report = try RecordsIO.importRecords(from: .exportFile(url), into: .distributed,
                                                 strategy: .merge, saveDir: saveDir.path,
                                                 records: records)
        XCTAssertEqual(report.recognizedAccounts, 0)
        XCTAssertEqual(report.unrecognizedEntries, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: saveDir.appendingPathComponent(MediaRecords.defaultSyncRecordName).path),
            "根下的 .synced.json 永远不会被 SyncStore 读到")
    }

    // MARK: - 按文件名重建

    func testRebuildFromFileNames() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        // 命名形态（契约 §5.2 的例子）：`<模板解析>[<媒体id>].<ext>`
        try makeMediaFile(in: tesla, named: "2026-09-12 18-37-48 Tesla 2098843535730725124[2098843532463411200].jpg")
        try makeMediaFile(in: tesla, named: "2026-09-12 18-37-48 Tesla 2098843535730725125[2098843532463411201].mp4")
        // 解析不出媒体 id：模板没带唯一标识的存量
        try makeMediaFile(in: tesla, named: "2026-09-12 18-37-48 Tesla.jpg")
        // 数字串太短（不是媒体 id）
        try makeMediaFile(in: tesla, named: "note_12345.jpg")
        let other = accountDir("Other", "other", "42")
        try makeMediaFile(in: other, named: "2026-01-01 Other[2104966797669830656].jpg")

        let report = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .centralized,
                                                        strategy: .merge, records: records)
        XCTAssertEqual(report.recognized, 3, "两个 tesla + 一个 other")
        XCTAssertEqual(report.added, 3)
        XCTAssertEqual(report.unrecognized, 2, "无 id 的那张 + 太短的数字串")
        records.invalidate()
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids,
                       ["2098843532463411200", "2098843532463411201"])
        XCTAssertEqual(records.loadCentralDownload(userId: "42")?.ids, ["2104966797669830656"])
    }

    /// 重建是"追加"的：再跑一次不新增
    func testRebuildIsIdempotentWithMerge() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        try makeMediaFile(in: tesla, named: "a[2098843532463411200].jpg")

        let first = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .distributed,
                                                       strategy: .merge, records: records)
        let second = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .distributed,
                                                        strategy: .merge, records: records)
        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.recognized, 1)
    }

    /// 重建 · 覆盖：该账号的记录被解析结果整体替换
    func testRebuildWithOverwrite() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        try makeMediaFile(in: tesla, named: "a[2098843532463411200].jpg")
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["old1", "old2"]),
                                  fileURL: records.centralDownloadURL(userId: "13298072"))

        let report = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .centralized,
                                                        strategy: .overwrite, records: records)
        XCTAssertEqual(report.added, 1)
        records.invalidate()
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids, ["2098843532463411200"],
                       "覆盖：解析结果整体替换旧记录")
    }

    /// 根下的文件：有媒体 id 但账号无从得知 → 无法识别（不能瞎猜账号）
    /// **残留下来的旧 id 必须被覆盖清掉**：账号文件夹里一个能解析的文件都没有时，
    /// 覆盖模式也要把它写成空（而不是"没扫到就跳过"）。
    ///
    /// 真实场景：上一版命名（下划线连接）解析出来的 id 留在记录里，
    /// 而新版解析器不认那些文件名；如果覆盖时跳过"零命中"的账号，
    /// 残留就永远清不掉，判定会把这些媒体一直当成"已下载"。
    func testRebuildOverwriteClearsResidueForAccountWithNoMatches() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        // 文件夹里只有解析不出 id 的老命名文件
        try makeMediaFile(in: tesla, named: "2026-09-12 18-37-48 Tesla 2098843535730725124-1.jpg")
        // 记录里留着上一版解析写进去的 id
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["2104693937789399040"]),
                                  fileURL: records.centralDownloadURL(userId: "13298072"))

        let report = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .centralized,
                                                        strategy: .overwrite, records: records)
        XCTAssertEqual(report.recognized, 0, "老命名解析不出 id")
        records.invalidate()
        let after = records.loadCentralDownload(userId: "13298072")
        XCTAssertTrue(after?.ids.isEmpty ?? false,
                      "覆盖模式必须清掉残留（账号扫到 0 个也要写空），实际：\(after?.ids ?? [])")
    }

    /// 追加模式**不该**清残留——它的语义就是并集（用户明确选了保留）。
    func testRebuildMergeKeepsResidue() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        try makeMediaFile(in: tesla, named: "a[2098843532463411200].jpg")
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["2104693937789399040"]),
                                  fileURL: records.centralDownloadURL(userId: "13298072"))

        _ = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .centralized,
                                               strategy: .merge, records: records)
        records.invalidate()
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids.sorted(),
                       ["2098843532463411200", "2104693937789399040"],
                       "追加：并集，两条都在")
    }

    func testRebuildCountsRootFilesAsUnrecognized() throws {
        try makeMediaFile(in: saveDir, named: "a[2098843532463411200].jpg")
        try makeMediaFile(in: saveDir, named: "readme.txt")

        let report = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .centralized,
                                                        strategy: .merge, records: records)
        XCTAssertEqual(report.recognized, 0)
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.unrecognized, 1, "只有能解析出 id 的根下文件才算无法识别")
    }

    /// 记录文件与隐藏文件不参与重建（它们不是媒体）
    func testRebuildSkipsDotFilesAndSocialFiles() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        try makeMediaFile(in: tesla, named: "a[2098843532463411200].jpg")
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["x"]),
                                  fileURL: records.distributedDownloadURL(accountDir: tesla.path))
        try Data("junk".utf8).write(to: tesla.appendingPathComponent(".DS_Store"))

        let report = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .centralized,
                                                        strategy: .merge, records: records)
        XCTAssertEqual(report.recognized, 1)
        XCTAssertEqual(report.unrecognized, 0, "隐藏文件（记录文件 / .DS_Store）不参与解析")
    }

    /// 回归：组件的断点 / 临时文件（`.part.http` / `.part.aria2next` / `.part.*.aria2`）
    /// **不是媒体**，不得被解析成"已下载"。
    ///
    /// 它们的文件名里同样带着媒体 id，而记录模式只信记录、不回查文件：
    /// 一旦写进记录，这些从没下完的媒体就被永久判为已下载，再也不会被下载，
    /// 且没有任何告警。半成品与目标文件同目录、命名见组件
    /// `crates/xspider-download/src/http_backend.rs:674-686`（`part_path_for`）。
    func testRebuildSkipsEnginePartials() throws {
        let tesla = accountDir("Tesla", "Tesla", "13298072")
        // 一个真的下完的媒体
        try makeMediaFile(in: tesla, named: "a[2098843532463411200].jpg")
        // 三个从没下完的半成品（媒体 id 相同——正是被误判的那个）
        try makeMediaFile(in: tesla, named: "a[2098843532463411200].jpg.part.http")
        try makeMediaFile(in: tesla, named: "a[2098843532463411199].jpg.part.aria2next")
        try makeMediaFile(in: tesla, named: "a[2098843532463411199].jpg.part.aria2next.aria2")

        let report = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .centralized,
                                                        strategy: .merge, records: records)
        XCTAssertEqual(report.recognized, 1, "只有下完的那张算识别到")
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.unrecognized, 0, "断点文件整个忽略，不计入无法识别")
        records.invalidate()
        XCTAssertEqual(records.loadCentralDownload(userId: "13298072")?.ids,
                       ["2098843532463411200"], "半成品的媒体 id 不得进记录")
    }

    /// 保存路径根下的断点同样不算"有媒体但账号无从得知"
    func testRebuildSkipsEnginePartialsAtRoot() throws {
        try makeMediaFile(in: saveDir, named: "a[2098843532463411200].jpg.part.http")
        try makeMediaFile(in: saveDir, named: "a[2098843532463411199].jpg")

        let report = try RecordsIO.rebuildFromFileNames(saveDir: saveDir.path, into: .centralized,
                                                        strategy: .merge, records: records)
        XCTAssertEqual(report.recognized, 0)
        XCTAssertEqual(report.unrecognized, 1, "根下只有真媒体计入无法识别，断点不算")
    }

    func testEnginePartialRecognition() {
        XCTAssertTrue(MediaJudgement.isEnginePartial(fileName: "x.jpg.part.http"))
        XCTAssertTrue(MediaJudgement.isEnginePartial(fileName: "x.mp4.part.aria2next"))
        XCTAssertTrue(MediaJudgement.isEnginePartial(fileName: "x.mp4.part.http.aria2"))
        XCTAssertTrue(MediaJudgement.isEnginePartial(fileName: "x.mp4.part.aria2next.aria2"))
        XCTAssertFalse(MediaJudgement.isEnginePartial(fileName: "x[2098843532463411200].jpg"))
        XCTAssertFalse(MediaJudgement.isEnginePartial(fileName: "part.http.jpg"))
    }

    // MARK: - 文件名 → 媒体 id 解析

    /// 唯一标识是**最后一个** `[纯ASCII数字]` 组（15~25 位）。
    func testMediaIdParsing() {
        XCTAssertEqual(RecordsIO.mediaId(fromFileName: "2026-09-12 Tesla 2098843535730725124[2098843532463411200].jpg"),
                       "2098843532463411200")
        XCTAssertEqual(RecordsIO.mediaId(fromFileName: "x[2098843532463411200]"),
                       "2098843532463411200", "没有扩展名也能解析")
        XCTAssertEqual(RecordsIO.mediaId(fromFileName: "x[2098843532463411200] (2).jpg"),
                       "2098843532463411200", "序号后缀不影响解析")
        XCTAssertEqual(RecordsIO.mediaId(fromFileName: "x[123456789012345].jpg"),
                       "123456789012345", "15 位是下界")
        XCTAssertEqual(RecordsIO.mediaId(fromFileName: "x[1234567890123456789012345].jpg"),
                       "1234567890123456789012345", "25 位是上界")
    }

    /// **模板变量自身可能带方括号**（昵称、正文——用户名不含），
    /// 所以解析必须取**最后一个**满足条件的组，而不是第一个/任意一个。
    func testMediaIdParsingSkipsNonIdBrackets() {
        // 昵称里的方括号（X 昵称几乎允许任意字符）
        XCTAssertEqual(RecordsIO.mediaId(fromFileName: "Tesla [Fan] 2098843535730725124[2098843532463411200].jpg"),
                       "2098843532463411200")
        // 正文截断里的方括号
        XCTAssertEqual(RecordsIO.mediaId(fromFileName: "check [cool] thing 2098843535730725124[2098843532463411200].jpg"),
                       "2098843532463411200")
        // 昵称里形如年份的括号数字：位数窗口只是第二道保险，主要依据是"取最后一个"
        XCTAssertEqual(RecordsIO.mediaId(fromFileName: "[2026] 2098843535730725124[2098843532463411200].jpg"),
                       "2098843532463411200")
        // 紧挨着的两个括号组
        XCTAssertEqual(RecordsIO.mediaId(fromFileName: "Tesla [Fan][2098843532463411200].jpg"),
                       "2098843532463411200")
    }

    /// 认不出来的必须返回 nil——认错比不认更坏（会把别的媒体写成已下载）。
    func testMediaIdParsingRejectsWhatIsNotAnId() {
        XCTAssertNil(RecordsIO.mediaId(fromFileName: "x[12345].jpg"), "位数不够")
        XCTAssertNil(RecordsIO.mediaId(fromFileName: "x[12345678901234567890123456].jpg"), "26 位不认")
        XCTAssertNil(RecordsIO.mediaId(fromFileName: "x[2026].jpg"), "年份不是 id")
        XCTAssertNil(RecordsIO.mediaId(fromFileName: "x[abc].jpg"), "非数字")
        XCTAssertNil(RecordsIO.mediaId(fromFileName: "x[].jpg"), "空括号")
        XCTAssertNil(RecordsIO.mediaId(fromFileName: "x[١٢٣٤٥٦٧٨٩٠١٢٣٤٥].jpg"), "非 ASCII 数字不认")
        XCTAssertNil(RecordsIO.mediaId(fromFileName: "x[2098843532463411200.jpg"), "括号不闭合")
        XCTAssertNil(RecordsIO.mediaId(fromFileName: "2098843532463411200.jpg"), "没有方括号段")
        XCTAssertNil(RecordsIO.mediaId(fromFileName: "2026-09-12 Tesla.jpg"), "没有 id")
    }
}
