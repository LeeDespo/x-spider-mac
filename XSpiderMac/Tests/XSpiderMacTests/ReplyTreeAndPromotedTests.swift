import XCTest
@testable import XSpiderMac

/// 推广内容过滤、评论层级树、评论排序。
///
/// 这三项都直接对应用户反馈：
/// 1. 评论区会混进**推广内容（广告）**——`itemContent.promotedMetadata` 非空即广告；
/// 2. 评论**全部平铺**，评论的评论看不出从属关系（层级信息在扁平化时丢了）；
/// 3. 评论缺**排序**（相关/喜欢/最近）。
final class ReplyTreeAndPromotedTests: XCTestCase {

    // MARK: - 构造工具

    private func user(_ sn: String, name: String = "作者") -> [String: Any] {
        [
            "rest_id": "u-\(sn)",
            "legacy": ["screen_name": sn, "name": name,
                       "profile_image_url_https": "https://pbs.twimg.com/a.jpg"] as [String: Any],
        ]
    }

    /// 一条推文 result。`replyTo` = 父推文 ID（X 的真实字段 `in_reply_to_status_id_str`）
    private func tweet(_ id: String,
                       text: String = "正文",
                       replyTo: String? = nil,
                       likes: Int = 0,
                       createdAt: String = "Sat Jan 20 15:15:36 +0000 2024",
                       screenName: String = "author") -> [String: Any] {
        var legacy: [String: Any] = [
            "full_text": text,
            "created_at": createdAt,
            "favorite_count": likes,
            "lang": "ja",
        ]
        if let replyTo { legacy["in_reply_to_status_id_str"] = replyTo }
        return [
            "__typename": "Tweet",
            "rest_id": id,
            "legacy": legacy,
            "core": ["user_results": ["result": user(screenName)] as [String: Any]],
        ]
    }

    /// 广告条目：`itemContent.promotedMetadata` 非空
    private func promotedItemContent(_ id: String) -> [String: Any] {
        [
            "promotedMetadata": ["advertiser_results": ["rest_id": "adv1"]] as [String: Any],
            "tweet_results": ["result": tweet(id, text: "这是一条广告")],
        ]
    }

    private func entry(_ entryId: String, _ itemContent: [String: Any]) -> [String: Any] {
        ["entryId": entryId, "content": itemContent]
    }

    private func instructions(_ entries: [[String: Any]]) -> [[String: Any]] {
        [["type": "TimelineAddEntries", "entries": entries]]
    }

    /// 单条推文 entry（content 为 itemContent 层）
    private func tweetEntry(_ id: String, _ result: [String: Any]) -> [String: Any] {
        entry("tweet-\(id)", ["itemContent": ["tweet_results": ["result": result]] as [String: Any]])
    }

    /// 广告 entry：entryId 仍以 tweet 开头，但 itemContent 带 promotedMetadata
    private func promotedEntry(_ id: String) -> [String: Any] {
        entry("tweet-\(id)", ["itemContent": promotedItemContent(id)] as [String: Any])
    }

    /// 会话线程 entry（评论挂在这里）
    private func threadEntry(_ id: String, _ items: [[String: Any]]) -> [String: Any] {
        entry("conversationthread-\(id)", ["items": items.map {
            ["item": ["itemContent": ["tweet_results": ["result": $0]]] as [String: Any]]
        }] as [String: Any])
    }

    /// 线程里的广告：item 的 itemContent 直接带 promotedMetadata
    private func promotedThreadItem(_ id: String) -> [String: Any] {
        ["item": ["itemContent": promotedItemContent(id)] as [String: Any]]
    }

    // MARK: - 推广内容（广告）过滤

    /// entryId 以 tweet 开头但带 promotedMetadata → 必须过滤
    func testPromotedTweetEntryIsFiltered() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000", text: "正常推文")),
            promotedEntry("adv"),
        ])
        let posts = TwitterAPI.extractPostsFromTweetEntries(ins, requireMedia: false)
        XCTAssertEqual(posts.map(\.id), ["1000"], "带 promotedMetadata 的条目必须被过滤掉")
    }

    /// entryId 明示为 promoted-* → 必须过滤
    func testPromotedEntryIdIsFiltered() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000", text: "正常推文")),
            entry("promoted-1", ["itemContent": ["tweet_results": ["result": tweet("adv")]] as [String: Any]]),
        ])
        let posts = TwitterAPI.extractPostsFromTweetEntries(ins, requireMedia: false)
        XCTAssertEqual(posts.map(\.id), ["1000"], "promoted-* entryId 必须被过滤")
    }

    /// 会话线程内的广告同样要过滤（评论区是用户实际看到广告的地方）
    func testPromotedInsideConversationThreadIsFiltered() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [tweet("2000", text: "正常评论", replyTo: "1000")]),
            entry("conversationthread-ad", ["items": [promotedThreadItem("3000")]] as [String: Any]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        XCTAssertEqual(nodes.map(\.post.id), ["2000"], "线程内的广告必须被过滤，正常评论要保留")
    }

    /// 判据本身：promotedMetadata 空字典不算广告（避免误伤）
    func testEmptyPromotedMetadataIsNotPromoted() {
        XCTAssertFalse(TwitterAPI.isPromotedItemContent(["promotedMetadata": [String: Any]()]))
        XCTAssertFalse(TwitterAPI.isPromotedItemContent([:]))
        XCTAssertFalse(TwitterAPI.isPromotedItemContent(nil))
        XCTAssertTrue(TwitterAPI.isPromotedItemContent(["promotedMetadata": ["advertiser_results": [:]]]))
    }

    /// UserMedia 路径（媒体网格）也要过滤广告
    func testModuleInstructionsFilterPromoted() {
        let ins: [[String: Any]] = [["type": "TimelineAddEntries", "entries": [[
            "entryId": "tweet-1000",
            "content": [
                "entryType": "TimelineTimelineModule",
                "items": [
                    ["item": ["itemContent": ["tweet_results": ["result": tweet("2000")]] as [String: Any]]],
                    ["item": ["itemContent": promotedItemContent("adv")]],
                ] as [[String: Any]],
            ] as [String: Any],
        ]]]]
        let posts = TwitterAPI.extractPostsFromModuleInstructions(ins)
        XCTAssertEqual(posts.map(\.id), ["2000"], "媒体网格路径也必须过滤广告")
    }

    // MARK: - 评论层级

    /// 直接回复 → depth 1；评论的评论 → depth 2
    func testReplyDepthFromParentChain() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [
                tweet("2000", text: "一级评论", replyTo: "1000"),
                tweet("3000", text: "二级评论", replyTo: "2000"),
                tweet("4000", text: "三级评论", replyTo: "3000"),
            ]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.post.id, $0) })
        XCTAssertEqual(byId["2000"]?.depth, 1, "focal 的直接回复 depth = 1")
        XCTAssertEqual(byId["3000"]?.depth, 2, "评论的评论 depth = 2")
        XCTAssertEqual(byId["4000"]?.depth, 3)
        XCTAssertEqual(byId["2000"]?.parentId, "1000")
        XCTAssertEqual(byId["3000"]?.parentId, "2000")
        XCTAssertFalse(byId["3000"]?.isPartialParent ?? true, "父在结果里 → 不是孤儿")
    }

    /// **关键**：父推文不在本页（X 只返回部分会话）时，孤儿回复**不能丢**
    func testOrphanReplyIsKeptNotDropped() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [
                // 父 8888 不在返回结果里
                tweet("2000", text: "孤儿评论", replyTo: "8888"),
            ]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        XCTAssertEqual(nodes.map(\.post.id), ["2000"], "父不在本页时也必须保留该回复")
        XCTAssertEqual(nodes.first?.depth, 1, "孤儿挂在根下")
        XCTAssertTrue(nodes.first?.isPartialParent ?? false, "必须标记为孤儿（UI 加「回复 @xxx」前缀）")
    }

    /// 环（异常数据：A 回 B、B 回 A）不能死循环
    func testCyclicParentChainTerminates() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [
                tweet("2000", replyTo: "3000"),
                tweet("3000", replyTo: "2000"),
            ]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        XCTAssertEqual(Set(nodes.map(\.post.id)), ["2000", "3000"], "环状数据也要全部返回且不死循环")
    }

    /// 同一推文在多个 entry 重复出现 → 只保留一条
    func testDuplicateRepliesDeduped() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [tweet("2000", replyTo: "1000")]),
            threadEntry("1000", [tweet("2000", replyTo: "1000")]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        XCTAssertEqual(nodes.map(\.post.id), ["2000"], "重复条目要去重")
    }

    /// 父先于子输出（保证缩进渲染顺序自然）
    func testParentsComeBeforeChildren() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [
                tweet("4000", replyTo: "3000"),
                tweet("2000", replyTo: "1000"),
                tweet("3000", replyTo: "2000"),
            ]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        let depths = nodes.map(\.depth)
        XCTAssertEqual(depths, depths.sorted(), "输出必须按 depth 升序（父先于子）")
    }

    /// 顶层评论（无 in_reply_to）也算 depth 1，不被丢弃
    func testTopLevelCommentWithoutParentIsDepth1() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [tweet("2000", text: "顶层评论")]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        XCTAssertEqual(nodes.first?.depth, 1)
        XCTAssertFalse(nodes.first?.isPartialParent ?? true, "无父指针不等于孤儿")
    }

    /// 「回复 @xxx」前缀必须是**被回复者**，不是本条作者
    /// （否则二级评论会显示成"张三 回复 张三"）
    func testParentScreenNameIsTheRepliedToAuthor() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [
                tweet("2000", text: "一级", replyTo: "1000", screenName: "alice"),
                tweet("3000", text: "二级", replyTo: "2000", screenName: "bob"),
            ]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.post.id, $0) })
        XCTAssertEqual(byId["3000"]?.post.user.screenName, "bob", "本条作者是 bob")
        XCTAssertEqual(byId["3000"]?.parentScreenName, "alice",
                       "被回复者是 alice —— 前缀必须用它，不能用本条作者 bob")
    }

    /// 响应自带 `in_reply_to_screen_name` 时优先使用它（父不在本页也能显示对的人）
    func testParentScreenNameFromResponseFieldWhenParentMissing() {
        var child = tweet("2000", text: "孤儿但有作者名", replyTo: "8888")
        var legacy = child["legacy"] as! [String: Any]
        legacy["in_reply_to_screen_name"] = "carol"
        child["legacy"] = legacy
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [child]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        XCTAssertTrue(nodes.first?.isPartialParent ?? false)
        XCTAssertEqual(nodes.first?.parentScreenName, "carol",
                       "父不在本页时用响应里的 in_reply_to_screen_name")
    }

    // MARK: - TweetDetail 单请求同时取 focal + 回复树

    /// `extractReplyNodes` 必须排除 focal 本身（它是根，不是回复）
    func testReplyNodesExcludeFocalItself() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000", text: "主推文")),
            threadEntry("1000", [tweet("2000", replyTo: "1000")]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        XCTAssertFalse(nodes.contains { $0.post.id == "1000" },
                       "focal 是根不是回复，留在结果里会重复渲染主推文")
    }

    // MARK: - 真实响应形状（2026-09 实测，tweet 2100649211276529930 / 2099484254740631767）

    /// 真实响应里：无媒体的 focal 引用了另一条带媒体的推文，且被引用作者
    /// **只有新结构的 `core.core`**（`legacy` 缺失）——若只读 legacy，引用卡作者会空白。
    func testQuotedAuthorFromNewCoreStructureOnly() {
        let quoted: [String: Any] = [
            "__typename": "Tweet",
            "rest_id": "2100550768965423303",
            "legacy": [
                "full_text": "What happened to quality control at Apple",
                "created_at": "Sat Jan 20 15:15:36 +0000 2024",
                "entities": ["media": [["id_str": "qm1", "type": "photo",
                                        "media_url_https": "https://pbs.twimg.com/media/q.jpg"]]],
            ] as [String: Any],
            "core": ["user_results": ["result": [
                "__typename": "User",
                "rest_id": "1254456213527543808",
                // 只有新结构 core.core；legacy 缺失（实测如此）
                "core": ["screen_name": "TheAppleDesign", "name": "Apple Design",
                         "created_at": "Sun Apr 26 17:04:19 +0000 2020"] as [String: Any],
                "avatar": ["image_url": "https://pbs.twimg.com/profile_images/x_normal.jpg"] as [String: Any],
            ] as [String: Any]]] as [String: Any],
        ]
        let result: [String: Any] = [
            "__typename": "Tweet",
            "rest_id": "2100649211276529930",
            "legacy": ["full_text": "主推文", "created_at": "Sat Jan 20 15:15:36 +0000 2024",
                       "is_quote_status": true] as [String: Any],
            "quoted_status_result": ["result": quoted] as [String: Any],
        ]
        let post = TwitterAPI.mapTwitterPost(result)
        let q = post?.quotedPost?.value
        XCTAssertNotNil(q, "引用必须解析出来")
        XCTAssertEqual(q?.user.screenName, "TheAppleDesign",
                       "作者在新结构 core.core 里，只读 legacy 会拿不到")
        XCTAssertEqual(q?.user.name, "Apple Design")
        XCTAssertEqual(q?.user.id, "1254456213527543808")
        XCTAssertEqual(q?.medias?.count, 1, "被引用推文的媒体也要解析出来")
    }

    /// 真实响应里广告挂在 `conversationthread-*` 的 item 上：
    /// `item.itemContent.promotedMetadata` 非空。实测 tweet 2100649211276529930
    /// 有 3 条这种广告（投资/背包广告），text 与主推文毫无关系。
    func testRealShapedPromotedInThreadIsDropped() {
        let ad: [String: Any] = [
            "itemContent": [
                "__typename": "TimelineTweet",
                "itemType": "TimelineTweet",
                "promotedMetadata": [
                    "adMetadataContainer": [:] as [String: Any],
                    "advertiser_results": ["rest_id": "adv"] as [String: Any],
                    "impressionId": "abc",
                ] as [String: Any],
                "tweetDisplayType": "Tweet",
                "tweet_results": ["result": tweet("2100528503813009883", text: "14周年限時加碼｜全年最勁獎賞只此一次🎁！")],
            ] as [String: Any],
        ]
        let ins = instructions([
            tweetEntry("2100649211276529930", tweet("2100649211276529930", text: "主推文")),
            entry("conversationthread-2100528503813009883", ["items": [ad]] as [String: Any]),
            threadEntry("2100649211276529930", [tweet("2100705904333029797", text: "真实评论",
                                                     replyTo: "2100649211276529930",
                                                     screenName: "someone")]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "2100649211276529930")
        XCTAssertEqual(nodes.map(\.post.id), ["2100705904333029797"],
                       "真实形状的广告必须被丢弃，正常评论保留")
        // 广告的正文绝不应出现在结果里
        XCTAssertFalse(nodes.contains { ($0.post.fullText ?? "").contains("限時加碼") })
    }

    // MARK: - 评论自带媒体与计数（真实：@leoakok 在 2100550768965423303 下的评论）

    /// 真实形状：`@leoakok`（Leo）的评论带一张照片，且有赞数与回复数。
    /// 实测 `legacy.favorite_count = 326`、`legacy.reply_count = 3`、
    /// `legacy.entities.media[0]` 为 947×2048 的 photo。
    ///
    /// 回归的是"评论区不显示媒体"：解析层本就该带出 `medias`，
    /// 之前渲染层完全没画，导致带图评论只剩文字。
    func testReplyMediaAndCountsAreParsed() {
        var legacy: [String: Any] = [
            "full_text": "@TheAppleDesign this ☠️ https://t.co/T2I4ES67Qj",
            "created_at": "Sat Jan 20 15:15:36 +0000 2024",
            "favorite_count": 326,
            "reply_count": 3,
            "in_reply_to_status_id_str": "2100550768965423303",
            "in_reply_to_screen_name": "TheAppleDesign",
            "entities": [
                "media": [[
                    "id_str": "2100584214701727780",
                    "type": "photo",
                    "media_url_https": "https://pbs.twimg.com/media/HSbGNYhXQAAKuL1.jpg",
                    "original_info": ["width": 947, "height": 2048] as [String: Any],
                ] as [String: Any]],
            ] as [String: Any],
        ]
        legacy["lang"] = "en"
        let result: [String: Any] = [
            "__typename": "Tweet",
            "rest_id": "2100584214701727780",
            "legacy": legacy,
            "core": ["user_results": ["result": user("leoakok", name: "Leo")] as [String: Any]],
        ]
        let ins = instructions([
            tweetEntry("2100550768965423303", tweet("2100550768965423303", text: "主推文")),
            threadEntry("2100550768965423303", [result]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "2100550768965423303")
        let node = nodes.first { $0.post.user.screenName == "leoakok" }
        XCTAssertNotNil(node, "Leo 的评论必须在结果里")
        XCTAssertEqual(node?.post.medias?.count, 1, "评论自带的媒体必须解析出来（渲染层才有得画）")
        XCTAssertEqual(node?.post.medias?.first?.type, .photo)
        XCTAssertEqual(node?.post.medias?.first?.width, 947)
        XCTAssertEqual(node?.post.medias?.first?.height, 2048)
        XCTAssertEqual(node?.post.favoriteCount, 326, "评论点赞数要解析出来")
        XCTAssertEqual(node?.post.replyCount, 3, "评论的回复数要解析出来")
        XCTAssertEqual(node?.parentScreenName, "TheAppleDesign")
    }

    /// 评论缩略图 URL：`/media/` 图片加 `name=small`；非 media 路径（视频封面）原样返回
    func testReplyThumbnailURLUsesSmallVariant() {
        let photo = TwitterMedia(
            id: "m1",
            url: "https://pbs.twimg.com/media/HSbGNYhXQAAKuL1.jpg",
            width: 947, height: 2048, type: .photo, videoInfo: nil, createdTime: nil)
        let url = ReplyMediaThumb.thumbnailURL(for: photo)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.contains("name=small"),
                      "缩略图必须走 name=small（680px），不能按原图解码，实际: \(url!)")

        // 已有 name 参数时替换而不是追加，避免出现两个 name
        let already = TwitterMedia(
            id: "m2",
            url: "https://pbs.twimg.com/media/x.jpg?name=orig",
            width: 100, height: 100, type: .photo, videoInfo: nil, createdTime: nil)
        let replaced = ReplyMediaThumb.thumbnailURL(for: already)!
        XCTAssertEqual(replaced.components(separatedBy: "name=").count - 1, 1,
                       "不能出现两个 name 参数：\(replaced)")
        XCTAssertTrue(replaced.contains("name=small"))

        // 视频封面路径不带 /media/：原样返回，不加 query
        let video = TwitterMedia(
            id: "m3",
            url: "https://pbs.twimg.com/amplify_video_thumb/123/img/x.jpg",
            width: 100, height: 100, type: .video, videoInfo: nil, createdTime: nil)
        XCTAssertEqual(ReplyMediaThumb.thumbnailURL(for: video),
                       "https://pbs.twimg.com/amplify_video_thumb/123/img/x.jpg")

        let noURL = TwitterMedia(id: "m4", url: nil, width: nil, height: nil,
                                 type: .photo, videoInfo: nil, createdTime: nil)
        XCTAssertNil(ReplyMediaThumb.thumbnailURL(for: noURL))
    }

    /// 评论没有媒体时 `medias` 应为 nil（渲染层据此不画缩略图行）
    func testReplyWithoutMediaHasNilMedias() {
        let ins = instructions([
            tweetEntry("1000", tweet("1000")),
            threadEntry("1000", [tweet("2000", text: "纯文字评论", replyTo: "1000")]),
        ])
        let nodes = TwitterAPI.extractReplyNodes(ins, focalId: "1000")
        XCTAssertNil(nodes.first?.post.medias, "无媒体评论不应造出空数组")
    }

    // MARK: - 评论排序

    private func node(_ id: String, likes: Int, minutesAgo: Int, depth: Int = 1) -> ReplyNode {
        let created = Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo * 60))
        let post = TwitterPost(
            id: id,
            user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                              mediaCount: nil, registerTime: nil),
            createdAt: created, fullText: "t", tags: [], views: nil, lang: "en",
            retweeted: nil, retweetCount: nil, replyCount: nil, possiblySensitive: nil,
            favorited: nil, favoriteCount: likes, bookmarkCount: nil, bookmarked: nil,
            medias: nil)
        return ReplyNode(post: post, parentId: nil, depth: depth, isPartialParent: false)
    }

    /// 相关 = 保持服务端顺序（不做本地重排）
    func testRelevanceKeepsServerOrder() {
        let nodes = [node("a", likes: 1, minutesAgo: 5),
                     node("b", likes: 99, minutesAgo: 1),
                     node("c", likes: 50, minutesAgo: 30)]
        XCTAssertEqual(ReplySort.relevance.sorted(nodes).map(\.post.id), ["a", "b", "c"],
                       "「相关」必须保持服务端顺序（服务端自带相关性信号）")
    }

    /// 喜欢 = 按点赞数降序
    func testLikesSortDescending() {
        let nodes = [node("a", likes: 1, minutesAgo: 5),
                     node("b", likes: 99, minutesAgo: 1),
                     node("c", likes: 50, minutesAgo: 30)]
        XCTAssertEqual(ReplySort.likes.sorted(nodes).map(\.post.id), ["b", "c", "a"])
    }

    /// 最近 = 按时间降序
    func testRecentSortDescending() {
        let nodes = [node("a", likes: 1, minutesAgo: 5),
                     node("b", likes: 99, minutesAgo: 1),
                     node("c", likes: 50, minutesAgo: 30)]
        XCTAssertEqual(ReplySort.recent.sorted(nodes).map(\.post.id), ["b", "a", "c"])
    }

    /// 同键值保持原有相对顺序（稳定排序）——避免每次刷新评论顺序乱跳
    func testSortIsStableForEqualKeys() {
        let nodes = [node("a", likes: 10, minutesAgo: 5),
                     node("b", likes: 10, minutesAgo: 5),
                     node("c", likes: 10, minutesAgo: 5)]
        XCTAssertEqual(ReplySort.likes.sorted(nodes).map(\.post.id), ["a", "b", "c"])
        XCTAssertEqual(ReplySort.recent.sorted(nodes).map(\.post.id), ["a", "b", "c"])
    }

    /// 排序不改变集合内容（只换顺序）
    func testSortPreservesAllNodes() {
        let nodes = [node("a", likes: 1, minutesAgo: 5), node("b", likes: 2, minutesAgo: 1)]
        for sort in ReplySort.allCases {
            XCTAssertEqual(Set(sort.sorted(nodes).map(\.post.id)), ["a", "b"],
                           "\(sort) 不能丢评论")
        }
    }
}

/// 详情缓存：回看刚看过的推文不该再打一次 TweetDetail。
///
/// 存在意义：浮层按推文 ID 重建视图（`.id(post.id)`，否则 @State 串味），
/// 重建会重跑 `.task`。没有缓存时，「点引用推文 → 返回」会把 A 的详情重新请求一遍。
final class TweetDetailCacheTests: XCTestCase {

    private func makePost(_ id: String) -> TwitterPost {
        TwitterPost(id: id,
                    user: TwitterUser(screenName: "u", avatar: "", name: "U", id: "1",
                                      mediaCount: nil, registerTime: nil),
                    createdAt: nil, fullText: "t", tags: [], views: nil, lang: "en",
                    retweeted: nil, retweetCount: nil, replyCount: nil,
                    possiblySensitive: nil, favorited: nil, favoriteCount: nil,
                    bookmarkCount: nil, bookmarked: nil, medias: nil)
    }

    override func setUp() async throws {
        await MainActor.run { TweetDetailCache.shared.clear() }
    }

    override func tearDown() async throws {
        await MainActor.run { TweetDetailCache.shared.clear() }
    }

    @MainActor
    func testPutThenGetReturnsSameContent() {
        let cache = TweetDetailCache.shared
        let post = makePost("1000")
        let reply = ReplyNode(post: makePost("2000"), parentId: "1000", depth: 1)
        cache.put("1000", focal: post, replies: [reply])

        let hit = cache.get("1000")
        XCTAssertEqual(hit?.focal.id, "1000")
        XCTAssertEqual(hit?.replies.map(\.post.id), ["2000"])
        XCTAssertNil(cache.get("nope"), "未缓存的 ID 返回 nil（调用方回落网络）")
    }

    /// 用户操作后失效：否则回看会看到旧的点赞态
    @MainActor
    func testInvalidateRemovesEntry() {
        let cache = TweetDetailCache.shared
        cache.put("1000", focal: makePost("1000"), replies: [])
        XCTAssertNotNil(cache.get("1000"))
        cache.invalidate("1000")
        XCTAssertNil(cache.get("1000"), "失效后必须回落网络请求")
    }

    /// 容量上限：长期浏览不会无限增长
    @MainActor
    func testCacheIsBounded() {
        let cache = TweetDetailCache.shared
        for i in 0..<40 { cache.put("p\(i)", focal: makePost("p\(i)"), replies: []) }
        XCTAssertNil(cache.get("p0"), "最旧的应被淘汰")
        XCTAssertNotNil(cache.get("p39"), "最近的应保留")
    }

    /// 重复 put 同一 ID 不重复占用名额
    @MainActor
    func testRePutSameIdDoesNotDuplicate() {
        let cache = TweetDetailCache.shared
        for _ in 0..<30 {
            cache.put("1000", focal: makePost("1000"), replies: [])
        }
        XCTAssertNotNil(cache.get("1000"))
        // 若每次 put 都追加 order，30 次后 1000 会被自己挤掉
        XCTAssertNotNil(cache.get("1000"), "同一 ID 反复写入不应该把自己淘汰掉")
    }
}

/// 导航历史栈：返回语义。
final class NavigationHistoryTests: XCTestCase {

    override func setUp() async throws {
        await MainActor.run { NavigationHistory.shared.reset() }
    }

    override func tearDown() async throws {
        await MainActor.run { NavigationHistory.shared.reset() }
    }

    @MainActor
    func testBackPopsInReversePushOrder() {
        let history = NavigationHistory.shared
        history.push(.detail(postId: "a"))
        history.push(.detail(postId: "b"))
        history.push(.home(nil))

        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.stack.last?.key, "home:")
        history.back()
        XCTAssertEqual(history.stack.last?.key, "detail:b", "先回到最近压入的界面")
        history.back()
        XCTAssertEqual(history.stack.last?.key, "detail:a")
        history.back()
        XCTAssertFalse(history.canGoBack)
    }

    /// 连续压入同一目标只保留一条（重复搜索同一用户不该产生两层返回）
    @MainActor
    func testDuplicateConsecutivePushIsIgnored() {
        let history = NavigationHistory.shared
        history.push(.detail(postId: "a"))
        history.push(.detail(postId: "a"))
        XCTAssertEqual(history.stack.count, 1)
    }

    /// 栈空时 back() 返回 false（调用方据此兜底关闭浮层）
    @MainActor
    func testBackOnEmptyStackReturnsFalse() {
        XCTAssertFalse(NavigationHistory.shared.back())
    }

    /// 容量上限：长时间浏览不会无限增长
    @MainActor
    func testStackIsBounded() {
        let history = NavigationHistory.shared
        for i in 0..<100 { history.push(.detail(postId: "p\(i)")) }
        XCTAssertLessThanOrEqual(history.stack.count, 32, "历史栈必须有上限")
        // 保留的是最近的那批
        XCTAssertEqual(history.stack.last?.key, "detail:p99")
    }

    /// 重放动作被调用（ContentView 注入的还原路径）
    @MainActor
    func testBackInvokesReplay() {
        let history = NavigationHistory.shared
        var replayed: [String] = []
        history.replay = { entry in replayed.append(entry.key) }
        history.push(.detail(postId: "a"))
        history.back()
        XCTAssertEqual(replayed, ["detail:a"])
        history.replay = nil
    }

    /// 截断：关闭详情浮层时，本次会话攒的返回记录必须作废。
    ///
    /// 回归场景：关闭详情 A → 从主页打开详情 C → 按返回。
    /// 若 A 的记录残留，返回会跳到无关的 A。
    @MainActor
    func testTruncateDropsSessionEntries() {
        let history = NavigationHistory.shared
        history.push(.home(nil))            // 进入浮层前就有的历史（应保留）
        let entryDepth = history.depth

        // 浮层内跳转攒下记录
        history.push(.detail(postId: "A"))
        history.push(.detail(postId: "B"))
        XCTAssertEqual(history.depth, entryDepth + 2)

        // 用户关闭浮层
        history.truncate(to: entryDepth)
        XCTAssertEqual(history.depth, entryDepth, "会话内的记录必须被丢弃")
        XCTAssertEqual(history.stack.last?.key, "home:", "进入浮层前的历史要保留")

        // 再次打开详情时不会指向上一次的推文
        XCTAssertFalse(history.stack.contains { $0.key == "detail:A" })
    }

    /// 截断到更深/相同深度是空操作
    @MainActor
    func testTruncateToDeeperOrEqualIsNoOp() {
        let history = NavigationHistory.shared
        history.push(.detail(postId: "a"))
        history.truncate(to: 5)
        history.truncate(to: 1)
        XCTAssertEqual(history.depth, 1)
    }
}
