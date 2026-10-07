import XCTest
@testable import XSpiderMac

/// 媒体记录层（`MEDIA_RECORDS.md` §4/§5/§6/§9）回归测试。
///
/// 覆盖：记录读写往返、两种形态、合并/覆盖、原子落盘、
/// 文件名唯一标识与判定、文件夹命名与解析、设置旧键映射与模板清理。
final class MediaRecordsTests: XCTestCase {

    private var tempDir: URL!
    private var records: MediaRecords!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaRecordsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        records = MediaRecords(centralRoot: tempDir.appendingPathComponent("central"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 下载记录 · 往返与形状

    func testDownloadRecordRoundTrip() throws {
        let url = records.distributedDownloadURL(accountDir: tempDir.path)
        let record = DownloadRecord(userId: "13298072", ids: ["2", "1", "1"])
        try records.writeDownload(record, fileURL: url)

        let back = try XCTUnwrap(records.loadDownload(fileURL: url))
        XCTAssertEqual(back.version, 1)
        XCTAssertEqual(back.kind, "xspider.download-record")
        XCTAssertEqual(back.userId, "13298072")
        XCTAssertEqual(back.ids, ["1", "2"], "ids 必须是去重 + 字典序（输出稳定）")

        // 磁盘上的原文也必须是契约形状（不是靠缓存读出来的假象）
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"kind\": \"xspider.download-record\""), "实际：\(text)")
        XCTAssertTrue(text.contains("\"user_id\": \"13298072\""), "实际：\(text)")
    }

    func testDownloadRecordRejectsWrongKindOrVersion() throws {
        let url = tempDir.appendingPathComponent("bad.json")
        try Data(#"{"version":2,"kind":"xspider.download-record","user_id":"1","ids":[]}"#.utf8).write(to: url)
        XCTAssertNil(records.loadDownload(fileURL: url), "version 不符必须整份丢弃")

        try Data(#"{"version":1,"kind":"something-else","user_id":"1","ids":[]}"#.utf8).write(to: url)
        XCTAssertNil(records.loadDownload(fileURL: url), "kind 不符必须整份丢弃")

        try Data("{}".utf8).write(to: url)
        XCTAssertNil(records.loadDownload(fileURL: url), "空对象必须整份丢弃")
    }

    /// JSON 缩进 2 空格（契约 §4），且不残留临时文件
    func testJSONUsesTwoSpaceIndentAndNoTempLeftover() throws {
        let url = records.distributedDownloadURL(accountDir: tempDir.path)
        try records.writeDownload(DownloadRecord(userId: "1", ids: ["10"]), fileURL: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let topLevel = try XCTUnwrap(lines.first { $0.contains("\"version\"") })
        XCTAssertTrue(topLevel.hasPrefix("  \""), "顶层字段必须缩进 2 空格：\(topLevel)")
        XCTAssertFalse(text.contains("\t"), "不得用制表符缩进")

        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(names, [url.lastPathComponent],
                       "写入后目录里只应有记录文件（临时文件必须清掉）：\(names)")
    }

    // MARK: - 记录文件的字节形状（契约 §4：2 空格缩进、末尾换行、空数组单行、键序钉死）

    /// 空 `ids` 的**精确文本**：`"ids": []` 单行，不是 `[` 与 `]` 之间夹空行。
    func testDownloadRecordEmptyIdsIsExactText() throws {
        let url = records.distributedDownloadURL(accountDir: tempDir.path)
        try records.writeDownload(DownloadRecord(userId: "1", ids: []), fileURL: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, """
        {
          "version": 1,
          "kind": "xspider.download-record",
          "user_id": "1",
          "ids": []
        }

        """)
    }

    /// 非空 `ids` 的精确文本：键序必须是 `version, kind, user_id, ids`（**不是**字典序）。
    func testDownloadRecordFieldOrderIsContractOrder() throws {
        let url = records.distributedDownloadURL(accountDir: tempDir.path)
        try records.writeDownload(DownloadRecord(userId: "13298072", ids: ["b", "a"]), fileURL: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, """
        {
          "version": 1,
          "kind": "xspider.download-record",
          "user_id": "13298072",
          "ids": [
            "a",
            "b"
          ]
        }

        """)
    }

    /// 三种结构：末字节是 `\n`（规范第一条要求），且解码往返仍然成功。
    func testRecordFilesEndWithNewlineAndRoundTrip() throws {
        let downloadURL = records.distributedDownloadURL(accountDir: tempDir.path)
        let syncURL = records.distributedSyncURL(accountDir: tempDir.path)
        try records.writeDownload(DownloadRecord(userId: "1", ids: ["a"]), fileURL: downloadURL)
        try records.setSyncAccount(userId: "1", anchorDay: "2026-09-29", ids: [],
                                   fileURL: syncURL)
        let exportURL = tempDir.appendingPathComponent("export.json")
        try MediaRecordJSON.writeAtomically(
            try MediaRecordJSON.encode(RecordsExport(
                downloads: ["1": ["a"]],
                sync: ["1": SyncAccountRecord(anchorDay: "2026-09-29", ids: [])])),
            to: exportURL)

        for url in [downloadURL, syncURL, exportURL] {
            let data = try Data(contentsOf: url)
            XCTAssertEqual(data.last, 0x0A, "记录文件必须以一个换行结尾：\(url.lastPathComponent)")
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n\n"),
                           "不得有连续空行（空数组不能撑成三行）：\(url.lastPathComponent)")
        }

        // 解码往返：序列化器换了实现，解码路径仍然是同一套类型
        records.invalidate()
        XCTAssertEqual(records.loadDownload(fileURL: downloadURL)?.ids, ["a"])
        XCTAssertEqual(records.loadSync(fileURL: syncURL)?.accounts["1"]?.anchorDay, "2026-09-29")
        XCTAssertNotNil(RecordsExport.decode(from: try Data(contentsOf: exportURL)),
                        "导出包必须仍能被自己的解码器读回来")
    }

    /// 同步记录：键序 `version, kind, accounts`；账号键按字典序；空 ids 单行。
    func testSyncRecordExactTextShape() throws {
        let url = records.distributedSyncURL(accountDir: tempDir.path)
        try records.setSyncAccount(userId: "222", anchorDay: "2026-09-29", ids: ["m2"],
                                   fileURL: url)
        try records.setSyncAccount(userId: "111", anchorDay: "2026-09-28", ids: [],
                                   fileURL: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, """
        {
          "version": 1,
          "kind": "xspider.sync-record",
          "accounts": {
            "111": {
              "anchor_day": "2026-09-28",
              "ids": []
            },
            "222": {
              "anchor_day": "2026-09-29",
              "ids": [
                "m2"
              ]
            }
          }
        }

        """)
    }

    /// 导出包：键序 `version, kind, downloads, sync`；空字典写 `{}`。
    func testExportRecordExactTextShape() throws {
        let text = try String(data: MediaRecordJSON.encode(RecordsExport()), encoding: .utf8)
        XCTAssertEqual(text, """
        {
          "version": 1,
          "kind": "xspider.records-export",
          "downloads": {},
          "sync": {}
        }

        """)
    }

    /// 导出包（有内容）：嵌套字典与数组的缩进也必须逐字对齐规范 §4.3。
    func testExportRecordWithContentExactTextShape() throws {
        let export = RecordsExport(
            downloads: ["13298072": ["2098843532463411200"]],
            sync: ["13298072": SyncAccountRecord(anchorDay: "2026-09-29",
                                                 ids: ["2104966797669830656"])])
        let text = try String(data: MediaRecordJSON.encode(export), encoding: .utf8)
        XCTAssertEqual(text, """
        {
          "version": 1,
          "kind": "xspider.records-export",
          "downloads": {
            "13298072": [
              "2098843532463411200"
            ]
          },
          "sync": {
            "13298072": {
              "anchor_day": "2026-09-29",
              "ids": [
                "2104966797669830656"
              ]
            }
          }
        }

        """)
    }

    // MARK: - 集中式：一账号一文件、只回写该账号那一份

    func testCentralizedDownloadIsOneFilePerAccount() throws {
        XCTAssertTrue(records.appendCentralDownloadId("m1", userId: "111"))
        XCTAssertTrue(records.appendCentralDownloadId("m2", userId: "222"))
        XCTAssertTrue(records.appendCentralDownloadId("m3", userId: "111"))

        let url111 = records.centralDownloadURL(userId: "111")
        let url222 = records.centralDownloadURL(userId: "222")
        XCTAssertEqual(url111.lastPathComponent, "111.json")
        XCTAssertTrue(url111.path.hasPrefix(tempDir.appendingPathComponent("central").path),
                      "集中式落在注入的根目录下：\(url111.path)")

        XCTAssertEqual(records.loadCentralDownload(userId: "111")?.ids, ["m1", "m3"])
        XCTAssertEqual(records.loadCentralDownload(userId: "222")?.ids, ["m2"])
        XCTAssertEqual(records.loadCentralDownload(userId: "111")?.userId, "111")

        // 只回写该账号那一份：改 111 不影响 222 的字节
        let before = try Data(contentsOf: url222)
        XCTAssertTrue(records.appendCentralDownloadId("m4", userId: "111"))
        XCTAssertEqual(try Data(contentsOf: url222), before, "另一个账号的记录文件不得被改写")

        // 重复 append 幂等：不再写入、内容不变
        let snapshot = try Data(contentsOf: url111)
        XCTAssertFalse(records.appendCentralDownloadId("m4", userId: "111"))
        XCTAssertEqual(try Data(contentsOf: url111), snapshot)
    }

    /// 文件里的 user_id 与文件名不符 → 视为损坏（一账号一文件的自洽性）
    func testCentralizedMismatchedUserIdIsIgnored() throws {
        let dir = tempDir.appendingPathComponent("central/downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("999.json")
        try Data(#"{"version":1,"kind":"xspider.download-record","user_id":"123","ids":["m"]}"#.utf8)
            .write(to: url)
        XCTAssertNil(records.loadCentralDownload(userId: "999"), "user_id 与文件名不符必须忽略")
    }

    func testDownloadRecordMergeAndOverwrite() throws {
        let url = records.distributedDownloadURL(accountDir: tempDir.path)
        try records.writeDownload(DownloadRecord(userId: "1", ids: ["a"]), fileURL: url)

        // 合并 = id 并集（幂等：再合并一次不增加）
        try records.mergeDownloadIds(["b", "a", "c"], userId: "1", fileURL: url)
        XCTAssertEqual(records.loadDownload(fileURL: url)?.ids, ["a", "b", "c"])
        try records.mergeDownloadIds(["b", "a", "c"], userId: "1", fileURL: url)
        XCTAssertEqual(records.loadDownload(fileURL: url)?.ids, ["a", "b", "c"], "重复合并必须幂等")

        // 覆盖 = 整体替换
        try records.overwriteDownloadIds(["z"], userId: "1", fileURL: url)
        XCTAssertEqual(records.loadDownload(fileURL: url)?.ids, ["z"])
    }

    // MARK: - 同步记录

    func testSyncRecordRoundTripAndMerge() throws {
        let url = records.distributedSyncURL(accountDir: tempDir.path)
        XCTAssertEqual(url.lastPathComponent, ".synced.json")

        try records.setSyncAccount(userId: "13298072", anchorDay: "2026-09-29", ids: ["m1"],
                                   fileURL: url)
        let back = try XCTUnwrap(records.loadSync(fileURL: url))
        XCTAssertEqual(back.kind, "xspider.sync-record")
        XCTAssertEqual(back.accounts["13298072"]?.anchorDay, "2026-09-29")
        XCTAssertEqual(back.accounts["13298072"]?.ids, ["m1"])
        XCTAssertEqual(back.accounts.count, 1)
    }

    /// 合并语义（契约 §7）：anchor_day 取较晚者 + ids 并集
    func testSyncMergeTakesLaterAnchorAndUnionsIds() throws {
        let url = records.distributedSyncURL(accountDir: tempDir.path)
        try records.setSyncAccount(userId: "1", anchorDay: "2026-09-20", ids: ["a"], fileURL: url)
        try records.setSyncAccount(userId: "2", anchorDay: "2026-09-01", ids: ["x"], fileURL: url)

        let incoming = SyncRecord(accounts: [
            "1": SyncAccountRecord(anchorDay: "2026-09-25", ids: ["b", "a"]),
            "3": SyncAccountRecord(anchorDay: "2026-10-01", ids: ["z"]),
        ])
        try records.mergeSync(incoming, fileURL: url)

        let back = try XCTUnwrap(records.loadSync(fileURL: url))
        XCTAssertEqual(back.accounts["1"]?.anchorDay, "2026-09-25", "anchor_day 取较晚者")
        XCTAssertEqual(back.accounts["1"]?.ids, ["a", "b"], "ids 取并集")
        XCTAssertEqual(back.accounts["2"]?.anchorDay, "2026-09-01", "未涉及的账号保持原样")
        XCTAssertEqual(back.accounts["3"]?.ids, ["z"], "新账号应加入")

        // 幂等：再合并一次结果不变
        try records.mergeSync(incoming, fileURL: url)
        XCTAssertEqual(records.loadSync(fileURL: url), back, "重复导入同一份必须幂等")
    }

    /// 集中式同步记录：所有账号一个文件，不拆
    func testCentralizedSyncIsSingleFile() throws {
        XCTAssertEqual(records.centralSyncURL.lastPathComponent, "sync.json")
        try records.setSyncAccount(userId: "1", anchorDay: "2026-09-01", ids: ["a"],
                                   fileURL: records.centralSyncURL)
        try records.setSyncAccount(userId: "2", anchorDay: "2026-09-02", ids: ["b"],
                                   fileURL: records.centralSyncURL)
        let back = try XCTUnwrap(records.loadSync(fileURL: records.centralSyncURL))
        XCTAssertEqual(Set(back.accounts.keys), ["1", "2"], "两个账号应在同一份文件里")
        let files = try FileManager.default.contentsOfDirectory(
            atPath: tempDir.appendingPathComponent("central").path)
        XCTAssertEqual(files, ["sync.json"])
    }

    // MARK: - 缓存与失效

    func testInvalidateReloadsFromDisk() throws {
        let url = records.distributedDownloadURL(accountDir: tempDir.path)
        try records.writeDownload(DownloadRecord(userId: "1", ids: ["a"]), fileURL: url)
        XCTAssertEqual(records.loadDownload(fileURL: url)?.ids, ["a"])

        // 绕过记录层直接改盘（模拟"另一个进程/导入改写了文件"）
        try MediaRecordJSON.writeAtomically(
            try MediaRecordJSON.encode(DownloadRecord(userId: "1", ids: ["a", "b"])), to: url)

        XCTAssertEqual(records.loadDownload(fileURL: url)?.ids, ["a"], "缓存命中：未失效前读到旧值")
        records.invalidate()
        XCTAssertEqual(records.loadDownload(fileURL: url)?.ids, ["a", "b"], "失效后应重读磁盘")
    }

    // MARK: - 文件名（唯一标识 + 判定）

    private func samplePost(mediaIds: [String] = ["2098843532463411200"],
                            userName: String = "Tesla",
                            screenName: String = "Tesla") -> TwitterPost {
        let user = TwitterUser(screenName: screenName, avatar: "", name: userName,
                               id: "13298072", mediaCount: nil, registerTime: nil)
        let medias = mediaIds.map {
            TwitterMedia(id: $0, url: "https://pbs.twimg.com/media/\($0).jpg",
                         width: 100, height: 100, type: .photo, videoInfo: nil)
        }
        return TwitterPost(id: "2098843535730725124", user: user,
                           createdAt: ISO8601DateFormatter().date(from: "2026-09-12T18:37:48Z"),
                           fullText: "x", tags: nil, views: nil, lang: nil, retweeted: nil,
                           retweetCount: nil, replyCount: nil, possiblySensitive: nil,
                           favorited: nil, favoriteCount: nil, bookmarkCount: nil, bookmarked: nil,
                           medias: medias)
    }

    func testUniqueIdSuffixIsBeforeExtension() {
        XCTAssertEqual(
            MediaJudgement.appendingUniqueId("2026-09-12 18-37-48 Tesla.jpg", mediaId: "2098843532463411200"),
            "2026-09-12 18-37-48 Tesla[2098843532463411200].jpg")
        XCTAssertEqual(MediaJudgement.appendingUniqueId("name", mediaId: "42"), "name[42]",
                       "没有扩展名时追加在末尾")
        XCTAssertEqual(MediaJudgement.appendingUniqueId("name.jpg", mediaId: nil), "name.jpg",
                       "媒体 id 缺失时不追加")
        XCTAssertEqual(MediaJudgement.appendingUniqueId("name.jpg", mediaId: ""), "name.jpg")
    }

    func testFileNameTemplateResolvesThenSuffix() {
        let post = samplePost()
        let media = post.medias![0]
        let template = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID% %EXT%"

        let withId = MediaJudgement.fileName(post: post, media: media,
                                             template: template, appendUniqueId: true)
        XCTAssertEqual(withId,
                       "2026-09-12 18-37-48 Tesla 2098843535730725124[2098843532463411200].jpg")

        let without = MediaJudgement.fileName(post: post, media: media,
                                              template: template, appendUniqueId: false)
        // 不追加时**如实保留模板解析结果**：默认模板在 `%EXT%` 前有一个字面空格，
        // 所以这里带空格（与旧版记录模式下的落盘名一致）。追加路径会先收掉它，
        // 以对齐契约 §5.2 的例子。
        XCTAssertEqual(without, "2026-09-12 18-37-48 Tesla 2098843535730725124 .jpg")

        // 同推文多张媒体在"追加唯一标识"下必须得到不同文件名
        let post2 = samplePost(mediaIds: ["m1", "m2"])
        let n1 = MediaJudgement.fileName(post: post2, media: post2.medias![0],
                                         template: template, appendUniqueId: true)
        let n2 = MediaJudgement.fileName(post: post2, media: post2.medias![1],
                                         template: template, appendUniqueId: true)
        XCTAssertNotEqual(n1, n2, "唯一标识让同推文多张媒体互不覆盖")
    }

    func testFileNameJudgementChecksTheFileSystem() throws {
        let name = "2026-09-12 Tesla_2098843532463411200.jpg"
        XCTAssertFalse(MediaJudgement.isDownloaded(fileName: name, in: tempDir.path))
        try Data([0xFF, 0xD8]).write(to: tempDir.appendingPathComponent(name))
        XCTAssertTrue(MediaJudgement.isDownloaded(fileName: name, in: tempDir.path))

        // 判定就是文件存在性：改掉名字即视为未下载（记录模式的差异正在这里）
        XCTAssertFalse(MediaJudgement.isDownloaded(fileName: "other.jpg", in: tempDir.path))
        XCTAssertFalse(MediaJudgement.isDownloaded(fileName: name, in: ""))
    }

    // MARK: - 模板变量

    func testTemplateNoLongerHasMediaIdVariable() {
        let names = FileNameTemplate.variableDescriptions.map(\.name)
        XCTAssertFalse(names.contains("MEDIA_ID"), "契约 §5.3：%MEDIA_ID% 已删除")
        XCTAssertTrue(names.contains("MEDIA_INDEX"), "%MEDIA_INDEX% 保留")

        // 旧模板里的 %MEDIA_ID% 不再被替换（加载设置时会被清理掉，见下）
        let post = samplePost()
        let resolved = FileNameTemplate.resolve(
            template: "%MEDIA_ID%", data: FileNameTemplateData(post: post, media: post.medias![0]))
        XCTAssertEqual(resolved, "%MEDIA_ID%", "变量表里没有它 → 原样留着（由设置清理兜底）")
    }

    // MARK: - 账号文件夹命名

    func testAccountFolderName() {
        XCTAssertEqual(AccountFolder.name(name: "Tesla", screenName: "Tesla", userId: "13298072"),
                       "Tesla-Tesla[13298072]")
        // 斜杠与控制字符转义为 -
        XCTAssertEqual(AccountFolder.name(name: "a/b", screenName: "c\\d", userId: "1"),
                       "a-b-c-d[1]")
        // 用户名/昵称缺失也能拼出带 id 的文件夹
        XCTAssertEqual(AccountFolder.name(name: "", screenName: "", userId: "1"), "-[1]")
    }

    func testAccountFolderIdParsing() {
        XCTAssertEqual(AccountFolder.accountId(fromFolderName: "Tesla-Tesla[13298072]"), "13298072")
        XCTAssertEqual(AccountFolder.accountId(fromFolderName: "a[1]-b[2]"), "2",
                       "昵称自带方括号时取最后一个（数字 id 后缀总是最后拼上）")
        // 旧命名（昵称-@用户名）解析不出 → nil，这是"不兼容旧命名"的实现方式
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "ニックネーム-@screen_name"))
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "Tesla-Tesla[abc]"))
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "Tesla-Tesla[]"))
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "Tesla-Tesla"))
    }

    /// F5 回归：`Character.isNumber` 会把非 ASCII 数字也判成"数字"，
    /// 于是这些文件夹会被当成账号（实测确认）。只认 ASCII 0-9。
    func testAccountFolderIdRejectsNonASCIIDigits() {
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "x[١٢٣]"), "阿拉伯-印度数字不得认")
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "x[۱۲۳]"), "波斯数字不得认")
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "x[①]"), "圈号不得认")
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "x[½]"), "分数不得认")
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "x[１２３]"), "全角数字不得认")
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "x[٣]"), "单个非 ASCII 数字不得认")
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "x[१२३]"), "天城文数字不得认")
        // 正常例仍然通过（含 0 与 9 的边界）
        XCTAssertEqual(AccountFolder.accountId(fromFolderName: "x[0]"), "0")
        XCTAssertEqual(AccountFolder.accountId(fromFolderName: "x[2098843532463411200]"),
                       "2098843532463411200")
        // 混进一个非 ASCII 数字 → 整段不认（不能截出一半）
        XCTAssertNil(AccountFolder.accountId(fromFolderName: "x[123٤]"))
    }

    /// F3 回归：同一 user id 永远指向同一个账号文件夹。
    ///
    /// 用户改昵称 / 用户名后，若直接拿当前昵称拼名字就会出现第二个文件夹、
    /// 记录写进新的空文件，旧记录读不到 → 整个账号的媒体被当成没下过（整库重下）。
    func testAccountFolderKeepsExistingFolderForSameUserId() throws {
        let saveDir = tempDir.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        AccountFolder.invalidateIndex()
        defer { AccountFolder.invalidateIndex() }

        // 旧昵称下的已有文件夹
        let old = saveDir.appendingPathComponent("OldNick-old_name[13298072]", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)

        // 改名后：仍指向旧文件夹
        let dir = AccountFolder.directory(saveDir: saveDir.path,
                                          name: "NewNick", screenName: "new_name",
                                          userId: "13298072")
        XCTAssertEqual(dir, old.path, "同一 user id 必须复用已有文件夹")

        // 不同的 id 才新建（用当前昵称）
        let other = AccountFolder.directory(saveDir: saveDir.path,
                                            name: "NewNick", screenName: "new_name", userId: "42")
        XCTAssertEqual((other as NSString).lastPathComponent, "NewNick-new_name[42]")

        // 缓存被失效后（保存路径变更 / 记录刷新）仍然指向旧文件夹（重新扫盘的结果）
        AccountFolder.invalidateIndex()
        XCTAssertEqual(AccountFolder.directory(saveDir: saveDir.path,
                                               name: "NewestNick", screenName: "newest",
                                               userId: "13298072"),
                       old.path)
    }

    /// 只算过名字、目录还没落盘时改名：按当前昵称重算（不能把没落盘的名字当"已有文件夹"）
    func testNotYetMaterializedFolderFollowsRename() throws {
        let saveDir = tempDir.appendingPathComponent("rename-before-write", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        AccountFolder.invalidateIndex()
        defer { AccountFolder.invalidateIndex() }

        let first = AccountFolder.directory(saveDir: saveDir.path, name: "A", screenName: "a",
                                            userId: "7")
        XCTAssertEqual((first as NSString).lastPathComponent, "A-a[7]")
        // 目录还没建（用户只点了下载判定/预览），此时改名 → 用新昵称
        let renamed = AccountFolder.directory(saveDir: saveDir.path, name: "B", screenName: "b",
                                              userId: "7")
        XCTAssertEqual((renamed as NSString).lastPathComponent, "B-b[7]",
                       "目录不存在时改名必须跟着改（否则会写到一个永远不会被读到的新名字下）")
    }

    /// 扫描结果在缓存里：即使磁盘上突然多出一个同 id 的文件夹，未失效前的结论也不变
    /// （证明判定路径上的高频调用不会每次都扫盘）。
    func testAccountFolderIndexIsCachedUntilInvalidated() throws {
        let saveDir = tempDir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        AccountFolder.invalidateIndex()
        defer { AccountFolder.invalidateIndex() }

        // 磁盘上先有一个 "A-a[7]" 文件夹
        let a = saveDir.appendingPathComponent("A-a[7]", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)

        let first = AccountFolder.directory(saveDir: saveDir.path, name: "A", screenName: "a",
                                            userId: "7")
        XCTAssertEqual(first, a.path)
        // 磁盘上出现另一个同 id 的文件夹（模拟外部改动）
        let intruder = saveDir.appendingPathComponent("Other-other[7]", isDirectory: true)
        try FileManager.default.createDirectory(at: intruder, withIntermediateDirectories: true)
        XCTAssertEqual(AccountFolder.directory(saveDir: saveDir.path, name: "B", screenName: "b",
                                               userId: "7"),
                       first, "缓存命中：未失效前不重扫，结论不变")
        AccountFolder.invalidateIndex()
        XCTAssertEqual(AccountFolder.directory(saveDir: saveDir.path, name: "B", screenName: "b",
                                               userId: "7"),
                       a.path,
                       "失效后重扫：同 id 取名字字典序最小者（A-a[7] < Other-other[7]），结果确定")
    }

    // MARK: - 设置：键值直通与模板清理

    /// 解码只管"把键读出来"：三值（含 `centralized`）与认不出来的值都**原样保留**。
    ///
    /// 旧值映射（`recordFile` / `syncRecordFile`）已随本轮新默认值一并删除——
    /// 老配置由 `Settings.applySchemaDefaultsOnce` 一次性覆盖，不再做语义映射。
    func testCheckModeValuesPassThroughDecodeUnchanged() throws {
        for mode in SameFileCheckMode.allCases {
            let json = Data(#"{"sameFileCheckMode":"\#(mode.rawValue)"}"#.utf8)
            let decoded = try JSONDecoder().decode(DownloadSettings.self, from: json)
            XCTAssertEqual(decoded.sameFileCheckMode, mode.rawValue,
                           "新值 \(mode.rawValue) 必须原样通过（尤其 centralized，否则重启即回退）")
        }
        for mode in SyncCheckMode.allCases {
            let json = Data(#"{"syncCheckMode":"\#(mode.rawValue)"}"#.utf8)
            let decoded = try JSONDecoder().decode(SyncSettings.self, from: json)
            XCTAssertEqual(decoded.syncCheckMode, mode.rawValue)
        }
        // 认不出来的值也原样保留（取值解析在 Settings 的 getter 里兜底，不在解码期改写）
        let odd = try JSONDecoder().decode(
            DownloadSettings.self, from: Data(#"{"sameFileCheckMode":"garbage"}"#.utf8))
        XCTAssertEqual(odd.sameFileCheckMode, "garbage")
    }

    /// 回归：用户选了 `centralized` / `distributed` → 持久化 → 重启解码，值不得被改。
    func testCheckModeSurvivesPersistAndReload() throws {
        var settings = Settings()
        settings.sameFileCheckModeValue = .centralized
        settings.syncCheckModeValue = .centralized

        let data = try JSONEncoder().encode(settings)
        let reloaded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(reloaded.sameFileCheckModeValue, .centralized,
                       "重启后下载判定不得被改回按文件名")
        XCTAssertEqual(reloaded.syncCheckModeValue, .centralized,
                       "重启后同步判定不得被改回分布式")
    }

    /// 旧值不再映射（映射已删除）：解码后仍是原样的旧串，
    /// 但用户不会看到它——`SettingsStore.load` 会把这 4 个键一次性覆盖成新默认值。
    func testLegacySettingsDecodeNoLongerMapsValues() throws {
        let legacy = #"""
        {"saveDirBase":"/tmp/x","sameFileCheckMode":"recordFile","recordFileName":".downloaded.json",
         "fileNameTemplate":"%POST_TIME% %MEDIA_ID% %EXT%"}
        """#
        let decoded = try JSONDecoder().decode(DownloadSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.sameFileCheckMode, "recordFile",
                       "解码不做映射（旧值的失联由 SettingsStore 的一次性覆盖负责）")
        XCTAssertEqual(decoded.fileNameTemplate, "%POST_TIME% %EXT%",
                       "加载设置时移除 %MEDIA_ID%（并收掉多余空格）")
        XCTAssertNil(decoded.appendUniqueId, "旧配置无此键 → nil（语义为默认打开）")

        // 一次性覆盖把旧值顶成新默认值（`MEDIA_RECORDS.md` 的「不做旧数据兼容」）
        var settings = Settings()
        settings.download = decoded
        XCTAssertEqual(settings.sameFileCheckModeValue, .centralized,
                       "覆盖前：旧串认不出来 → getter 兜底 centralized（本轮新默认）")
        XCTAssertTrue(settings.applySchemaDefaultsOnce())
        XCTAssertEqual(settings.sameFileCheckModeValue, .centralized)
        XCTAssertEqual(settings.recordsFormValue, .centralized)
        XCTAssertTrue(settings.appendUniqueIdUserEnabled)
        XCTAssertEqual(settings.recordFileNameValue, ".downloadedrecord.json",
                       "历史默认名视为未设置 → 用新默认，避免继续读写旧文件")
    }

    func testCustomRecordFileNameIsPreserved() throws {
        let json = #"{"recordFileName":"my-records.json"}"#
        let decoded = try JSONDecoder().decode(DownloadSettings.self, from: Data(json.utf8))
        var settings = Settings()
        settings.download = decoded
        XCTAssertEqual(settings.recordFileNameValue, "my-records.json", "用户自定义名原样保留")
    }

    func testTemplateCleanupIsMinimal() {
        XCTAssertEqual(DownloadSettings.cleaningLegacyTemplate("%A% %MEDIA_ID% %B%"), "%A% %B%")
        XCTAssertEqual(DownloadSettings.cleaningLegacyTemplate("%MEDIA_ID% %B%"), "%B%")
        XCTAssertEqual(DownloadSettings.cleaningLegacyTemplate("%A%%EXT%"), "%A%%EXT%",
                       "不含该 token 的模板一个字节都不动")
        XCTAssertEqual(DownloadSettings.cleaningLegacyTemplate("x-%MEDIA_ID%.jpg"), "x-.jpg")
    }

    // MARK: - 设置：唯一标识开关的联动（契约 §6.2）

    func testAppendUniqueIdForcedOnWhenAnyModeIsFileName() {
        var s = Settings()

        s.sameFileCheckModeValue = .distributed
        s.syncCheckModeValue = .centralized
        s.appendUniqueIdUserEnabled = false
        XCTAssertFalse(s.appendUniqueIdEnabled, "两条都不是按文件名 → 尊重用户开关")
        XCTAssertFalse(s.appendUniqueIdLocked)

        s.appendUniqueIdUserEnabled = true
        XCTAssertTrue(s.appendUniqueIdEnabled)

        // 下载判定选按文件名 → 强制打开 + 锁定
        s.sameFileCheckModeValue = .fileName
        s.appendUniqueIdUserEnabled = false
        XCTAssertTrue(s.appendUniqueIdEnabled, "下载判定按文件名 → 强制打开")
        XCTAssertTrue(s.appendUniqueIdLocked)

        // 只有同步判定选按文件名 → 同样强制打开
        s.sameFileCheckModeValue = .centralized
        s.syncCheckModeValue = .fileName
        s.appendUniqueIdUserEnabled = false
        XCTAssertTrue(s.appendUniqueIdEnabled, "同步判定按文件名 → 强制打开")
        XCTAssertTrue(s.appendUniqueIdLocked)

        // 默认（全新设置）：开关默认打开
        XCTAssertTrue(Settings().appendUniqueIdEnabled)
    }

    // MARK: - DownloadStore 接线（targetDir 命名与目录解析）

    @MainActor
    func testTargetDirUsesAccountFolderNaming() {
        let post = samplePost()
        let base = tempDir.path
        let originalSaveDir = SettingsStore.shared.settings.download.saveDirBase
        let originalSubfolder = SettingsStore.shared.settings.download.accountSubfolder
        defer {
            SettingsStore.shared.settings.download.saveDirBase = originalSaveDir
            SettingsStore.shared.settings.download.accountSubfolder = originalSubfolder
            DownloadStore.shared.invalidateJudgements()
        }
        SettingsStore.shared.settings.download.saveDirBase = base
        SettingsStore.shared.settings.download.accountSubfolder = true

        let dir = DownloadStore.shared.targetDir(for: post)
        XCTAssertEqual(dir, (base as NSString).appendingPathComponent("Tesla-Tesla[13298072]"))
        XCTAssertEqual(AccountFolder.accountId(fromFolderName: (dir as NSString).lastPathComponent),
                       "13298072")

        SettingsStore.shared.settings.download.accountSubfolder = false
        XCTAssertEqual(DownloadStore.shared.targetDir(for: post), base,
                       "关闭子文件夹时回落到保存路径根目录")
    }

    /// F3 回归（store 层）：按旧昵称建的文件夹 + 记录，改名后判定与下载仍落在旧文件夹。
    @MainActor
    func testTargetDirAndJudgementSurviveNicknameChange() throws {
        let base = tempDir.appendingPathComponent("rename", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let originalSaveDir = SettingsStore.shared.settings.download.saveDirBase
        let originalSubfolder = SettingsStore.shared.settings.download.accountSubfolder
        let originalMode = SettingsStore.shared.settings.download.sameFileCheckMode
        defer {
            SettingsStore.shared.settings.download.saveDirBase = originalSaveDir
            SettingsStore.shared.settings.download.accountSubfolder = originalSubfolder
            SettingsStore.shared.settings.download.sameFileCheckMode = originalMode
            DownloadStore.shared.invalidateJudgements()
        }
        SettingsStore.shared.settings.download.saveDirBase = base.path
        SettingsStore.shared.settings.download.accountSubfolder = true
        SettingsStore.shared.settings.download.sameFileCheckMode = SameFileCheckMode.distributed.rawValue
        DownloadStore.shared.refreshDownloadedCaches()

        // 旧昵称下的文件夹 + 一条记录（媒体 id 已知）
        let mediaId = "2098843532463411200"
        let oldDir = base.appendingPathComponent("OldNick-old_name[13298072]", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let recordURL = oldDir.appendingPathComponent(MediaRecords.defaultDownloadRecordName)
        try MediaRecords.shared.writeDownload(
            DownloadRecord(userId: "13298072", ids: [mediaId]), fileURL: recordURL)
        AccountFolder.invalidateIndex()
        DownloadStore.shared.refreshDownloadedCaches()

        // 改名后：目标目录仍是旧文件夹，判定命中
        let renamed = samplePost(userName: "NewNick", screenName: "new_name")
        let media = renamed.medias![0]
        let dir = DownloadStore.shared.targetDir(for: renamed)
        XCTAssertEqual(dir, oldDir.path, "改昵称不得换文件夹（否则整库重下）")
        XCTAssertTrue(DownloadStore.shared.hasDownloaded(media: media, dir: dir, post: renamed),
                      "旧文件夹里的记录必须仍被判定命中")
        // 改名后新下一个媒体：必须写进**旧文件夹**那份记录（不是新建文件夹里的空文件）
        let newMediaId = "2999999999999999999"
        DownloadStore.shared.recordDownloaded(mediaId: newMediaId, post: renamed,
                                              media: media, dir: dir)
        XCTAssertTrue(MediaRecords.shared.loadDownload(fileURL: recordURL)?
            .ids.contains(newMediaId) == true,
            "改名后的新记录必须进旧文件夹的那份文件")
        XCTAssertTrue(DownloadStore.shared.hasDownloaded(media: media, dir: dir, post: renamed))
        // 记录文件没有被写到第二个文件夹
        let siblings = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(siblings, ["OldNick-old_name[13298072]"],
                       "不得因为改名而新建第二个账号文件夹：\(siblings)")
    }

    // MARK: - F9：判据与落盘名一致（唯一标识下不做「 (n)」重命名）

    /// 目标名已被占时，连续三次"下载同一媒体"必须复用同一个名字：
    /// 不产生第二份副本，判定返回 true。
    ///
    /// 以前落盘会把重名改成 `… (2).jpg`，而判定只查模板算出的那一个名字 →
    /// 界面永远显示未下载、每点一次多一份副本（隔离复现：(2)/(3)/(4)，hasDownloaded 恒 false）。
    @MainActor
    func testSameMediaDownloadedThreeTimesKeepsOneCopy() throws {
        let dir = tempDir.appendingPathComponent("f9", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let originalMode = SettingsStore.shared.settings.download.sameFileCheckMode
        let originalUnique = SettingsStore.shared.settings.download.appendUniqueId
        let originalTemplate = SettingsStore.shared.settings.download.fileNameTemplate
        defer {
            SettingsStore.shared.settings.download.sameFileCheckMode = originalMode
            SettingsStore.shared.settings.download.appendUniqueId = originalUnique
            SettingsStore.shared.settings.download.fileNameTemplate = originalTemplate
            DownloadStore.shared.invalidateJudgements()
        }
        SettingsStore.shared.settings.download.sameFileCheckMode = SameFileCheckMode.fileName.rawValue
        SettingsStore.shared.settings.download.appendUniqueId = true
        SettingsStore.shared.settings.download.fileNameTemplate = "%POST_ID% %EXT%"
        DownloadStore.shared.refreshDownloadedCaches()

        let post = samplePost()
        let media = post.medias![0]
        let expected = MediaJudgement.fileName(post: post, media: media,
                                               template: "%POST_ID% %EXT%", appendUniqueId: true)
        XCTAssertEqual(expected, "2098843535730725124[2098843532463411200].jpg")
        // 「目标名已被占」：同名的旧文件先放进去（同一个媒体，之前下过）
        try Data("already".utf8).write(to: dir.appendingPathComponent(expected))

        for round in 1...3 {
            // 重名消解不得改名（带唯一标识）
            let landing = DownloadStore.shared.resolvedFileName(post: post, media: media,
                                                                dir: dir.path)
            XCTAssertEqual(landing, expected, "第 \(round) 次仍然落在唯一标识给出的名字上")
            // 判定必须看见它（否则界面上"未下载"永远不消失）
            XCTAssertTrue(MediaJudgement.isDownloaded(fileName: landing, in: dir.path))
            // 模仿一次落盘（组件在同一路径上覆盖写）
            try Data("round\(round)".utf8).write(to: dir.appendingPathComponent(landing))
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files, [expected], "三次下载同一媒体只允许一份副本，实际：\(files)")
        XCTAssertTrue(DownloadStore.shared.hasDownloaded(media: media, dir: dir.path, post: post))
    }

    /// F9 回归（整条链）：文件已在 → `createDownloadTask` 判重跳过、返回 nil，
    /// 界面上的"已下载"与"再点一次"因此一致（不会再堆副本）。
    ///
    /// 这条会走到 `notify`（系统通知），但**不会**走到 `dl.enqueue`：
    /// 判重命中在 `start(task)` 之前就返回了，所以不需要组件、不碰网络。
    @MainActor
    func testCreateDownloadTaskSkipsWhenUniqueIdNameAlreadyOnDisk() async throws {
        let dir = tempDir.appendingPathComponent("f9-store", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let originalMode = SettingsStore.shared.settings.download.sameFileCheckMode
        let originalSubfolder = SettingsStore.shared.settings.download.accountSubfolder
        let originalSaveDir = SettingsStore.shared.settings.download.saveDirBase
        let originalSkip = SettingsStore.shared.settings.download.sameFileSkip
        let originalUnique = SettingsStore.shared.settings.download.appendUniqueId
        defer {
            SettingsStore.shared.settings.download.sameFileCheckMode = originalMode
            SettingsStore.shared.settings.download.accountSubfolder = originalSubfolder
            SettingsStore.shared.settings.download.saveDirBase = originalSaveDir
            SettingsStore.shared.settings.download.sameFileSkip = originalSkip
            SettingsStore.shared.settings.download.appendUniqueId = originalUnique
            DownloadStore.shared.invalidateJudgements()
        }
        SettingsStore.shared.settings.download.sameFileCheckMode = SameFileCheckMode.fileName.rawValue
        SettingsStore.shared.settings.download.accountSubfolder = false
        SettingsStore.shared.settings.download.saveDirBase = dir.path
        SettingsStore.shared.settings.download.sameFileSkip = true
        SettingsStore.shared.settings.download.appendUniqueId = true
        DownloadStore.shared.refreshDownloadedCaches()

        let post = samplePost()
        let media = post.medias![0]
        let name = DownloadStore.shared.resolvedFileName(post: post, media: media, dir: dir.path)
        try Data("already".utf8).write(to: dir.appendingPathComponent(name))

        let task = await DownloadStore.shared.createDownloadTask(post: post, media: media, silent: true)
        XCTAssertNil(task, "同名（唯一标识）文件已存在时必须跳过，不得再建任务")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files, [name], "不得因为再点一次而产生第二份副本：\(files)")
    }

    /// 没有唯一标识时（记录模式）保留重名保护：后来的不覆盖先前的
    func testWithoutUniqueIdCollisionStillGetsSuffix() throws {
        let dir = tempDir.appendingPathComponent("f9-no-id", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        XCTAssertEqual(MediaJudgement.landingFileName("a.jpg", hasUniqueId: false, dir: dir.path),
                       "a (2).jpg")
        XCTAssertEqual(MediaJudgement.landingFileName("a.jpg", hasUniqueId: true, dir: dir.path),
                       "a.jpg", "带唯一标识时原样落盘")
        XCTAssertEqual(MediaJudgement.landingFileName("b.jpg", hasUniqueId: false, dir: dir.path),
                       "b.jpg", "不冲突时不动名字")
    }

    // MARK: - F7：账号无法确定不得静默（三种场景）

    /// 场景 (a)：作者 id 缺失、但用户在账号文件夹里（文件夹名带 `[数字id]`）→ 用文件夹兜底。
    @MainActor
    func testAuthorIdFallsBackToAccountFolderName() {
        var post = samplePost()
        // 作者 id 缺失（响应形态变化 / 解析漏字段）
        post = replant(post, userId: "")
        let media = post.medias![0]
        let dir = tempDir.appendingPathComponent("Nick-nick[13298072]", isDirectory: true).path
        XCTAssertEqual(DownloadStore.shared.accountIdForRecord(post: post, media: media, dir: dir),
                       "13298072", "分布式场景本就有文件夹名里的数字 id，必须兜底")
    }

    /// 场景 (b)：作者 id 缺失、文件夹名里也没有数字 id → 返回 nil（调用方据此**不写**记录 + 告警）。
    @MainActor
    func testAuthorIdIsNilWhenNeitherSourceHasIt() {
        let post = replant(samplePost(), userId: "")
        let media = post.medias![0]
        XCTAssertNil(DownloadStore.shared.accountIdForRecord(post: post, media: media, dir: tempDir.path))
        XCTAssertNil(DownloadStore.shared.accountIdForRecord(
            post: post, media: media,
            dir: tempDir.appendingPathComponent("no-id-here", isDirectory: true).path))
    }

    /// 场景 (b) 的落盘行为：账号判不出来时**不写记录文件**（不是写一个空 user_id 的）
    @MainActor
    func testRecordDownloadedSkipsWriteWhenAccountIsUnknown() throws {
        let dir = tempDir.appendingPathComponent("f7-unknown", isDirectory: true)
        let originalMode = SettingsStore.shared.settings.download.sameFileCheckMode
        defer {
            SettingsStore.shared.settings.download.sameFileCheckMode = originalMode
            DownloadStore.shared.invalidateJudgements()
        }
        SettingsStore.shared.settings.download.sameFileCheckMode = SameFileCheckMode.distributed.rawValue
        DownloadStore.shared.refreshDownloadedCaches()

        let post = replant(samplePost(), userId: "")
        DownloadStore.shared.recordDownloaded(mediaId: "m1", post: post,
                                              media: post.medias![0], dir: dir.path)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(MediaRecords.defaultDownloadRecordName).path),
            "账号无法确定时不得写记录（写下去就是一条会被导入/导出丢弃的坏记录）")

        // 有账号文件夹可兜底时正常写入，且 user_id 取文件夹里的数字 id
        let accountDir = tempDir.appendingPathComponent("Nick-nick[13298072]", isDirectory: true)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        DownloadStore.shared.recordDownloaded(mediaId: "m2", post: post,
                                              media: post.medias![0], dir: accountDir.path)
        let record = try XCTUnwrap(MediaRecords.shared.loadDownload(
            fileURL: accountDir.appendingPathComponent(MediaRecords.defaultDownloadRecordName)))
        XCTAssertEqual(record.userId, "13298072", "user_id 取目标文件夹里的数字 id")
        XCTAssertEqual(record.ids, ["m2"])
    }

    /// 场景 (c)：作者 id 正常时直接用作者 id（文件夹名不参与）
    @MainActor
    func testAuthorIdPrefersPostAuthor() {
        let post = samplePost()
        let dir = tempDir.appendingPathComponent("Nick-nick[999]", isDirectory: true).path
        XCTAssertEqual(DownloadStore.shared.accountIdForRecord(
            post: post, media: post.medias![0], dir: dir),
            "13298072", "作者 id 优先于文件夹名")
    }

    /// 造一个换了 `userId` 的推文（其余字段不变）
    private func replant(_ post: TwitterPost, userId: String) -> TwitterPost {
        let user = TwitterUser(screenName: post.user.screenName, avatar: post.user.avatar,
                               name: post.user.name, id: userId,
                               mediaCount: nil, registerTime: nil)
        return TwitterPost(id: post.id, user: user, createdAt: post.createdAt,
                           fullText: post.fullText, tags: post.tags, views: post.views,
                           lang: post.lang, retweeted: post.retweeted,
                           retweetCount: post.retweetCount, replyCount: post.replyCount,
                           possiblySensitive: post.possiblySensitive, favorited: post.favorited,
                           favoriteCount: post.favoriteCount, bookmarkCount: post.bookmarkCount,
                           bookmarked: post.bookmarked, medias: post.medias)
    }

    // MARK: - F3（同步侧）：同步记录写账号文件夹也按 user id 复用

    @MainActor
    func testSyncAccountDirectoryReusesFolderForSameUserId() throws {
        let base = tempDir.appendingPathComponent("sync-rename", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let old = base.appendingPathComponent("OldNick-old_name[13298072]", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let originalSaveDir = SettingsStore.shared.settings.download.saveDirBase
        defer {
            SettingsStore.shared.settings.download.saveDirBase = originalSaveDir
            AccountFolder.invalidateIndex()
        }
        SettingsStore.shared.settings.download.saveDirBase = base.path
        AccountFolder.invalidateIndex()
        DownloadStore.shared.refreshDownloadedCaches()

        XCTAssertEqual(SyncStore.accountDirectory(name: "NewNick", screenName: "new_name",
                                                  userId: "13298072"),
                       old.path, "改昵称后同步记录仍写进旧文件夹（否则窗口记录读不到）")
        XCTAssertEqual(SyncStore.accountDirectory(name: "NewNick", screenName: "new_name",
                                                  userId: "42"),
                       (base.path as NSString).appendingPathComponent("NewNick-new_name[42]"),
                       "没有旧文件夹的账号才按当前昵称新建")
    }

    /// F5b：主页把输入当推文 id 的校验只认 ASCII 数字
    @MainActor
    func testTweetIdExtractionOnlyAcceptsASCIIDigits() {
        XCTAssertEqual(HomepageStore.extractTweetID(from: "2098843535730725124"),
                       "2098843535730725124")
        XCTAssertEqual(HomepageStore.extractTweetID(from: " 2098843535730725124 "),
                       "2098843535730725124", "首尾空白去掉")
        // 非 ASCII 数字一律不认
        XCTAssertNil(HomepageStore.extractTweetID(from: "①②③④⑤⑥⑦⑧⑨⑩"))
        XCTAssertNil(HomepageStore.extractTweetID(from: "１２３４５６７８９０１"))
        XCTAssertNil(HomepageStore.extractTweetID(from: "١٩٩٩٩٩٩٩٩٩٩"))
        XCTAssertNil(HomepageStore.extractTweetID(from: "123٤٥٦٧٨٩٠١٢٣"), "混一个非 ASCII 就不认")
        // 链接分支的正则本来就是 ASCII（`[0-9]{10,}`）：带 /status/<数字> 的输入按链接解析
        XCTAssertEqual(HomepageStore.extractTweetID(from: "example.com/status/12345678901"),
                       "12345678901", "链接分支只认 ASCII 数字段")
        // 链接路径仍然解析（链接里是 ASCII 数字）
        XCTAssertEqual(HomepageStore.extractTweetID(from: "x.com/tesla/status/2098843535730725124"),
                       "2098843535730725124")
        XCTAssertEqual(HomepageStore.extractTweetID(
            from: "https://x.com/tesla/status/2098843535730725124?ref=abc"),
            "2098843535730725124", "带 query 后缀")
    }
}
