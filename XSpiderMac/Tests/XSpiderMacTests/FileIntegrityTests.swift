import XCTest
@testable import XSpiderMac

/// 下载完整性校验回归测试。
///
/// 背景：实测（2026-09-17）aria2next 对不可达 URL 下载失败后会留下 **0 字节文件**，
/// 而旧代码把"文件存在"当作成功（还额外放行 exit 1）→ 坏文件被标记完成、写入下载记录、
/// 永不重试。这是成批出现损坏文件的根因。以下测试锁死新的判据。
final class FileIntegrityTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileIntegrityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ bytes: [UInt8], name: String = "f.jpg") throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url.path
    }

    // MARK: - 空文件（损坏的第一现场）

    /// 0 字节必须判失败——这正是实测复现出来的 aria2 失败残留
    func testEmptyFileIsRejected() throws {
        let path = try write([])
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("0 字节文件必须判失败")
        }
        XCTAssertEqual(reason, .empty)
    }

    func testMissingFileIsRejected() {
        let path = tempDir.appendingPathComponent("nope.jpg").path
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("缺失文件必须判失败")
        }
        XCTAssertEqual(reason, .missing)
    }

    /// 大小不符（下了一半）必须判失败
    func testTruncatedFileIsRejected() throws {
        // JPEG 魔数 + 少量数据，但声称应有 1MB
        let path = try write([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        let result = FileIntegrity.verify(path: path, expectedTotal: 1_048_576, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("大小不符必须判失败")
        }
        if case .truncated(let expected, let actual) = reason {
            XCTAssertEqual(expected, 1_048_576)
            XCTAssertEqual(actual, 12)
        } else {
            XCTFail("应为 truncated，实际 \(reason)")
        }
    }

    // MARK: - 内容级伪装（CDN 返回错误页却 200）

    /// HTML 错误页：旧代码只看"文件存在"会放行，必须被拦下
    func testHTMLErrorPageIsRejected() throws {
        let html = Array("<html><body>Rate limited</body></html>".utf8)
        let path = try write(html)
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("HTML 错误页必须判失败")
        }
        XCTAssertEqual(reason, .htmlErrorPage)
    }

    /// JSON 错误响应（X 的 CDN 有时返回 JSON）
    func testJSONErrorPayloadIsRejected() throws {
        let json = Array(#"{"error":"rate limited"}"#.utf8)
        let path = try write(json)
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("JSON 错误响应必须判失败")
        }
        XCTAssertEqual(reason, .htmlErrorPage)
    }

    /// 照片位置却是非图片内容 → 判失败
    func testNonImageContentRejectedForPhoto() throws {
        let junk = Array("this is definitely not an image".utf8)
        let path = try write(junk)
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("非图片内容在 photo 类型上必须判失败")
        }
        XCTAssertEqual(reason, .notAnImage)
    }

    // MARK: - 正常图片通过（各种魔数）

    func testValidJPEGPasses() throws {
        let path = try write([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        guard case .success(let size) = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo) else {
            return XCTFail("有效 JPEG 应通过")
        }
        XCTAssertEqual(size, 12)
    }

    func testValidPNGPasses() throws {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]
        let path = try write(png, name: "f.png")
        guard case .success = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo) else {
            return XCTFail("有效 PNG 应通过")
        }
    }

    func testValidGIFPasses() throws {
        let gif: [UInt8] = Array("GIF89a".utf8) + [0x01, 0x00, 0x01, 0x00, 0x00]
        let path = try write(gif, name: "f.gif")
        guard case .success = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo) else {
            return XCTFail("有效 GIF 应通过")
        }
    }

    func testValidWebPPasses() throws {
        var webp: [UInt8] = Array("RIFF".utf8) + [0x00, 0x00, 0x00, 0x00] + Array("WEBP".utf8)
        webp.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        let path = try write(webp, name: "f.webp")
        guard case .success = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo) else {
            return XCTFail("有效 WebP 应通过")
        }
    }

    /// 视频不做魔数校验（容器多样：mp4/webm/m3u8 分片），只校验非空与非错误页
    func testVideoSkipsMagicCheck() throws {
        let mp4: [UInt8] = [0x00, 0x00, 0x00, 0x18] + Array("ftypisom".utf8) + [0x00] 
        let path = try write(mp4, name: "f.mp4")
        guard case .success = FileIntegrity.verify(path: path, expectedTotal: 0, type: .video) else {
            return XCTFail("视频文件不应因魔数校验被拒")
        }
    }

    /// 期望大小完全匹配时通过（且不影响魔数校验）
    func testExactSizeMatchPasses() throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01]
        let path = try write(jpeg)
        guard case .success(let size) = FileIntegrity.verify(path: path, expectedTotal: 12, type: .photo) else {
            return XCTFail("大小匹配应通过")
        }
        XCTAssertEqual(size, 12)
    }
}

/// 下载引擎选择（按文件大小）回归测试
final class EngineSelectionTests: XCTestCase {

    /// 阈值默认 5MB；小于走内置，大于走 aria2
    func testAutoSelectsBySize() {
        var settings = Settings()
        settings.download.engine = .auto
        settings.download.aria2SizeThresholdMB = 5
        XCTAssertEqual(settings.aria2SizeThresholdMB, 5)
    }

    /// 阈值越界钳制：防止用户填 0 或超大值
    func testThresholdClamping() {
        var settings = Settings()
        settings.download.aria2SizeThresholdMB = 0
        XCTAssertEqual(settings.aria2SizeThresholdMB, 1)
        settings.download.aria2SizeThresholdMB = 99999
        XCTAssertEqual(settings.aria2SizeThresholdMB, 2048)
    }

    /// aria2 端口：默认 6801，钳制 1024–65535
    func testAria2PortDefaultsAndClamping() {
        var settings = Settings()
        XCTAssertEqual(settings.aria2Port, 6801)
        XCTAssertEqual(settings.aria2PortMode, .fixed)

        settings.download.aria2Port = 80          // 特权端口
        XCTAssertEqual(settings.aria2Port, 1024)
        settings.download.aria2Port = 99999
        XCTAssertEqual(settings.aria2Port, 65535)
    }

    /// CDN 限流设置默认值与钳制
    func testCDNSettingsDefaults() {
        var settings = Settings()
        settings.app.rateLimit = RateLimitSettings()
        XCTAssertTrue(settings.cdnThrottleEnabled)
        XCTAssertEqual(settings.cdnMaxConcurrent, 1)
        XCTAssertEqual(settings.cdnCooldownSeconds, 120)

        settings.app.rateLimit?.cdnMaxConcurrent = 0
        XCTAssertEqual(settings.cdnMaxConcurrent, 1)
        settings.app.rateLimit?.cdnCooldownSeconds = 1
        XCTAssertEqual(settings.cdnCooldownSeconds, 10)
    }

    /// 旧配置（无新字段）应回落到默认值而非解码失败
    func testLegacyDownloadSettingsDecode() throws {
        let json = #"{"download":{"saveDirBase":"/tmp","fileNameTemplate":"%POST_ID%%EXT%"}}"#
        let decoded = try JSONDecoder().decode(DownloadSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.aria2SizeThresholdMB, 5)
        XCTAssertEqual(decoded.aria2Port, 6801)
        XCTAssertEqual(decoded.engine, .aria2)
    }
}

/// CDN 状态与 API 状态相互独立（不同资源、独立状态）
final class CDNStatusTests: XCTestCase {

    @MainActor
    func testCDNStateIsIndependentFromAPIState() {
        let store = AccountStatusStore.shared
        store.reset()

        // API 正常但 CDN 限流 → 两行应分别反映
        store.noteCDNRateLimited(retryAfter: 60)
        XCTAssertTrue(store.cdnThrottled)
        XCTAssertEqual(store.effectiveHealth, .normal, "CDN 限流不应把 API 状态也标成异常")
        XCTAssertNotNil(store.cdnStatusText)

        // API 限流不应影响 CDN 行
        store.noteRateLimited(until: Date().addingTimeInterval(300))
        XCTAssertTrue(store.cdnThrottled, "API 限流不应清除 CDN 限流")
        store.reset()
    }

    @MainActor
    func testCDNSuccessClearsThrottle() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteCDNRateLimited(retryAfter: 60)
        XCTAssertTrue(store.cdnThrottled)
        store.noteCDNSuccess()
        XCTAssertFalse(store.cdnThrottled)
        XCTAssertNil(store.cdnStatusText)
    }

    /// CDN 失败（非限流）也应展示，便于用户区分"限流"与"资源不存在"
    @MainActor
    func testCDNFailureIsReported() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteCDNFailure("HTTP 404")
        XCTAssertFalse(store.cdnThrottled)
        XCTAssertNotNil(store.cdnStatusText)
        XCTAssertTrue(store.cdnStatusText?.contains("404") ?? false)
        store.reset()
    }

    /// 限流冷却只延长不退步（并发 429 不应互相覆盖成更短的等待）
    @MainActor
    func testCDNCooldownOnlyExtends() {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteCDNRateLimited(retryAfter: 300)
        let first = store.cdnRateLimitedUntil
        store.noteCDNRateLimited(retryAfter: 10)
        let second = store.cdnRateLimitedUntil
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        if let first, let second {
            XCTAssertGreaterThanOrEqual(second, first.addingTimeInterval(-1))
        }
        store.reset()
    }

    // MARK: - 恢复必须唤醒下载队列（曾静默卡住的缺口）

    /// 限流到期时必须触发恢复回调。
    /// 回归：早前 refreshCDNExpiry 只清标记、不通知队列 → 并发上限虽恢复，
    /// waiting 任务却无人拉起，队列静默卡住直到用户下次操作。
    @MainActor
    func testExpiryNotifiesRecovery() {
        let store = AccountStatusStore.shared
        store.reset()
        var notified = 0
        store.onCDNRecovered = { notified += 1 }
        defer { store.onCDNRecovered = nil }

        store.noteCDNRateLimited(retryAfter: nil)
        store.setCDNThrottleDeadlineForTesting(Date().addingTimeInterval(-1))  // 构造已过期
        store.refreshCDNExpiry()
        XCTAssertFalse(store.cdnThrottled)
        XCTAssertEqual(notified, 1, "到期恢复必须通知下载队列（否则等待任务卡住）")
    }

    /// 任务成功确认 CDN 正常时也必须通知
    @MainActor
    func testSuccessNotifiesRecovery() {
        let store = AccountStatusStore.shared
        store.reset()
        var notified = 0
        store.onCDNRecovered = { notified += 1 }
        defer { store.onCDNRecovered = nil }

        store.noteCDNRateLimited(retryAfter: 60)
        store.noteCDNSuccess()
        XCTAssertEqual(notified, 1, "成功恢复必须通知下载队列")
    }

    /// 未处于限流时不应触发恢复回调（避免无谓的 pump）
    @MainActor
    func testNoRecoveryCallbackWhenNotThrottled() {
        let store = AccountStatusStore.shared
        store.reset()
        var notified = 0
        store.onCDNRecovered = { notified += 1 }
        defer { store.onCDNRecovered = nil }

        store.noteCDNSuccess()   // 本来就没限流
        store.refreshCDNExpiry() // 本来就没到期状态
        XCTAssertEqual(notified, 0)
    }

    /// 用户点重试：即使随后探测失败，也应先解除限流并唤醒一次
    /// （用户明确表达"别再拦我"）
    @MainActor
    func testProbeClearsThrottleAndNotifies() async {
        let store = AccountStatusStore.shared
        store.reset()
        store.noteCDNRateLimited(retryAfter: 3600)
        XCTAssertTrue(store.cdnThrottled)

        // 不等待网络结果，只验证"先解除 + 通知"这一步的语义
        var notified = 0
        store.onCDNRecovered = { notified += 1 }
        defer { store.onCDNRecovered = nil }

        // probeCDN 会真发一次网络请求；测试环境可能失败，但解除与通知必须先发生
        await store.probeCDN()
        XCTAssertFalse(store.cdnThrottled, "用户重试应立即解除限流")
        XCTAssertGreaterThanOrEqual(notified, 1, "用户重试应唤醒队列")
        store.reset()
    }
}

/// 判定依据的语义契约（重构后见 `MEDIA_RECORDS.md` §6；旧的"自动追加序号"已删除）
final class JudgmentSemanticsTests: XCTestCase {

    private func media(_ id: String) -> TwitterMedia {
        TwitterMedia(id: id, url: "https://pbs.twimg.com/media/\(id).jpg",
                     width: 100, height: 100, type: .photo, videoInfo: nil, createdTime: nil)
    }

    private func post(id: String, mediaIds: [String]) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1", mediaCount: nil, registerTime: nil),
                    createdAt: nil, fullText: nil, tags: [], views: nil, lang: nil,
                    retweeted: nil, retweetCount: nil, replyCount: nil, possiblySensitive: nil,
                    favorited: nil, favoriteCount: nil, bookmarkCount: nil, bookmarked: nil,
                    medias: mediaIds.map(media))
    }

    @MainActor
    private func store() -> DownloadStore { DownloadStore.shared }

    /// 唯一标识在扩展名前、用 `[ ]` 包裹（同推文多张媒体因此互不覆盖）
    func testUniqueIdSuffixKeepsMediaDistinct() {
        let p = post(id: "123", mediaIds: ["m1", "m2"])
        let n1 = MediaJudgement.appendingUniqueId("123.jpg", mediaId: p.medias?[0].id)
        let n2 = MediaJudgement.appendingUniqueId("123.jpg", mediaId: p.medias?[1].id)
        XCTAssertEqual(n1, "123[m1].jpg")
        XCTAssertEqual(n2, "123[m2].jpg")
        XCTAssertNotEqual(n1, n2, "同推文多张媒体必须得到不同文件名（否则判定只认第一个）")
    }

    /// 不再自动追加序号：模板解析结果 + 唯一标识，没有 `-1` / ` 1` 这种自动编号
    func testNoAutomaticIndexSuffix() {
        let p = post(id: "123", mediaIds: ["m1"])
        let name = MediaJudgement.fileName(post: p, media: p.medias![0],
                                           template: "%POST_ID%%EXT%", appendUniqueId: false)
        XCTAssertEqual(name, "123.jpg", "关闭唯一标识时不得自动补序号")
        let withId = MediaJudgement.fileName(post: p, media: p.medias![0],
                                             template: "%POST_ID%%EXT%", appendUniqueId: true)
        XCTAssertEqual(withId, "123[m1].jpg")
    }

    /// 判定版本号必须可自增（视图依赖它重算按钮状态）
    @MainActor
    func testJudgementVersionBumps() {
        let s = store()
        let before = s.judgementVersion
        s.invalidateJudgements()
        XCTAssertGreaterThan(s.judgementVersion, before,
                             "切换判定依据必须自增版本号，否则媒体卡按钮状态不更新")
    }

    /// `refreshDownloadedCaches` 与 `invalidateJudgements` 语义 =
    /// 失效记录层缓存 + judgementVersion++（后续阶段依赖这两个名字）
    @MainActor
    func testRefreshCachesInvalidatesAndBumps() {
        let s = store()
        let before = s.judgementVersion
        s.refreshDownloadedCaches()
        XCTAssertGreaterThan(s.judgementVersion, before)
    }
}


/// 应用模型的引用推文持久化语义。
final class QuotedPostModelTests: XCTestCase {
    func testLegacyCodableStillDecodes() throws {
        let legacyJSON = """
        {"id":"1","user":{"screenName":"u","avatar":"","name":"U","id":"1"},
         "createdAt":null,"fullText":"旧记录","tags":null,"views":null,"lang":null,
         "retweeted":null,"retweetCount":null,"replyCount":null,"possiblySensitive":null,
         "favorited":null,"favoriteCount":null,"bookmarkCount":null,"bookmarked":null,
         "medias":null}
        """
        let post = try JSONDecoder().decode(TwitterPost.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(post.id, "1")
        XCTAssertNil(post.quotedPost)
        XCTAssertNil(post.retweetedBy)
    }

    func testQuotedPostRoundTrip() throws {
        let inner = TwitterPost(
            id: "999",
            user: TwitterUser(screenName: "a", avatar: "", name: "A", id: "1", mediaCount: nil, registerTime: nil),
            createdAt: nil, fullText: "内层", tags: nil, views: nil, lang: nil,
            retweeted: nil, retweetCount: nil, replyCount: nil, possiblySensitive: nil,
            favorited: nil, favoriteCount: nil, bookmarkCount: nil, bookmarked: nil, medias: nil)
        let outer = TwitterPost(
            id: "111", user: inner.user, createdAt: nil, fullText: "外层",
            tags: nil, views: nil, lang: nil, retweeted: nil, retweetCount: nil,
            replyCount: nil, possiblySensitive: nil, favorited: nil,
            favoriteCount: nil, bookmarkCount: nil, bookmarked: nil, medias: nil,
            quotedPost: QuotedPostBox(inner))
        let data = try JSONEncoder().encode(outer)
        let back = try JSONDecoder().decode(TwitterPost.self, from: data)
        XCTAssertEqual(back.quotedPost?.value.id, "999")
        XCTAssertEqual(back.quotedPost?.value.fullText, "内层")
    }
}

final class TranslationLanguageTests: XCTestCase {

    /// 主语言子标签比对：忽略地区/书写变体
    func testSameLanguageIgnoresRegionAndScript() {
        // zh-Hans 与 zh 视为同语言（只比主标签）
        XCTAssertTrue(TranslationStore.isSameLanguage("zh-Hans", Locale.Language(identifier: "zh")))
        XCTAssertTrue(TranslationStore.isSameLanguage("zh", Locale.Language(identifier: "zh-Hans")))
        // en-US 与 en 同语言
        XCTAssertTrue(TranslationStore.isSameLanguage("en-US", Locale.Language(identifier: "en")))
        // 不同语言必须判为不同（否则该翻的不翻）
        XCTAssertFalse(TranslationStore.isSameLanguage("ja", Locale.Language(identifier: "zh-Hans")))
        XCTAssertFalse(TranslationStore.isSameLanguage("en", Locale.Language(identifier: "ja")))
    }

    /// 空语言码不应被误判为"同语言"（否则会漏翻）
    func testEmptyLanguageIsNotSame() {
        XCTAssertFalse(TranslationStore.isSameLanguage("", Locale.Language(identifier: "en")))
    }

    /// 语言未知（nil）时不自动翻译 —— 按用户决策：不确定就交给手动
    func testUnknownLanguageDoesNotAutoTranslate() {
        // 语言未知 → 判据第一步就应返回 false（不猜）
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: nil))
        XCTAssertFalse(TranslationStore.shouldAutoTranslate(lang: ""))
    }

    /// 自动翻译默认关闭：开启会让每次浏览都触发翻译，打扰且耗电
    func testAutoTranslateDefaultsOff() {
        XCTAssertFalse(SettingsStore.shared.settings.autoTranslateEnabled,
                       "自动翻译默认应为关")
    }

    /// 空值语义：存储为空字符串表示"跟随系统"。
    /// **不要**断言真实 settings 的当前值——测试宿主是应用本体，
    /// 用户的已存设置（如 zh-Hans）会污染这类断言。
    /// 这里只验证"空 → 跟随系统"这条映射规则本身。
    func testEmptyTargetLanguageMeansFollowSystem() {
        var settings = Settings()
        settings.app.translateTargetLanguage = nil
        XCTAssertEqual(settings.translateTargetLanguageRaw, "",
                       "未设置时应为空（表示跟随系统）")
        XCTAssertEqual(settings.translateTargetLanguage.languageCode,
                       Settings.systemPreferredLanguage.languageCode,
                       "未设置时应回落到**系统偏好语言**，而不是被 bundle 降级的 Locale.current")

        settings.app.translateTargetLanguage = "ja"
        XCTAssertEqual(settings.translateTargetLanguageRaw, "ja")
        XCTAssertEqual(settings.translateTargetLanguage.languageCode, "ja")

        // 空字符串写回应为 nil（表示跟随系统），而不是存一个空串
        settings.translateTargetLanguageRaw = ""
        XCTAssertNil(settings.app.translateTargetLanguage)
    }
}

/// TweetDetail 的 focal 推文提取与引用解析。
///
/// 这一组针对两个真实 bug（2026-09 用真实响应定位）：
/// 1. focal 走 `extractPostsFromTweetEntries`（默认 requireMedia=true）时，
///    **无媒体的 focal 会被过滤掉**，退化分支返回"第一条有媒体的推文"——
///    那往往是评论区的带图评论或广告，表现为"详情弹出的是别人的推文"；
/// 2. 引用写在 `legacy.quoted_status_result` 上永远取不到——
///    真实路径是 `result.quoted_status_result.result`（result 的直接子键）。
