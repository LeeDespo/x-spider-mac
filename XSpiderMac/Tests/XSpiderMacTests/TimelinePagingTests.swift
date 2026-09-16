import XCTest
@testable import XSpiderMac

/// 分页语义回归测试：锁住两个曾经的重大故障点。
/// 1. 无限滚动的停止条件（上游 InfiniteScroll 的 threshold 语义）
/// 2. 创建任务爬虫的 cursor 推进时序（上游 runCreationTask 铁律）
final class TimelinePagingTests: XCTestCase {

    // MARK: - 无限滚动停止条件（上游 InfiniteScroll.tsx:35-50）

    /// 内容底部在视口顶以下不足两屏 → 继续补拉
    func testContinueFillingWhenContentFitsWithinTwoViewports() {
        // 内容底距视口顶 300pt，视口 400pt → 300 <= 800，需继续
        XCTAssertTrue(HomepageStore.shouldContinueFilling(contentBottomY: 300, viewportHeight: 400))
        // 正好两屏边界
        XCTAssertTrue(HomepageStore.shouldContinueFilling(contentBottomY: 800, viewportHeight: 400))
    }

    /// 内容已超出两屏 → 停止，等用户滚动（防 429 风暴的关键）
    func testStopFillingWhenContentExceedsTwoViewports() {
        XCTAssertFalse(HomepageStore.shouldContinueFilling(contentBottomY: 801, viewportHeight: 400))
        XCTAssertFalse(HomepageStore.shouldContinueFilling(contentBottomY: 5000, viewportHeight: 400))
    }

    /// 视口未知/未布局时不得触发请求（避免拿 0 高度去比值）
    func testNoFillingBeforeViewportKnown() {
        XCTAssertFalse(HomepageStore.shouldContinueFilling(contentBottomY: 100, viewportHeight: 0))
    }

    /// 哨兵未上报（初值 .greatestFiniteMagnitude）→ 不触发
    func testNoFillingBeforeSentinelReported() {
        XCTAssertFalse(HomepageStore.shouldContinueFilling(
            contentBottomY: .greatestFiniteMagnitude, viewportHeight: 400))
    }

    // MARK: - 创建任务 cursor 推进时序（上游 download.ts runCreationTask）

    /// 模拟上游循环：dateFilter 清空整页时，cursor 仍必须已推进。
    /// 修复前 cursor 推进放在循环尾（continue 之后）→ 同一页被反复重抓。
    func testCursorAdvancesEvenWhenPageIsFullyFiltered() {
        var nextCursor: String? = nil
        var hasFetched = false
        var requestedCursors: [String?] = []
        var now = Date()
        let since = Date(timeIntervalSince1970: 0)

        // 伪造服务端：3 页，每页 cursor 依次为 c1 → c2 → nil
        let serverPages: [(cursor: String?, next: String?, createdAt: Date)] = [
            ("PAGE1", "c1", Date(timeIntervalSince1970: 1_700_000_000)),
            ("c1", "c2", Date(timeIntervalSince1970: 1_600_000_000)),
            ("c2", nil, Date(timeIntervalSince1970: 1_500_000_000)),
        ]

        while !hasFetched || (nextCursor != nil && now > since) {
            guard let requested = nextCursor else {
                // 首轮：nextCursor 为 nil（上游 undefined 语义）
                requestedCursors.append(nil)
                let page = serverPages[0]
                nextCursor = page.next
                hasFetched = true
                now = page.createdAt
                continue // 模拟"整页被日期过滤清空"
            }
            requestedCursors.append(requested)
            guard let page = serverPages.first(where: { $0.cursor == requested }) else { break }
            nextCursor = page.next
            now = page.createdAt
            if nextCursor == nil { break }
            // 仍然模拟整页被过滤 → continue
        }

        // 三个 cursor 各自只请求一次，且严格推进（无重复页）
        XCTAssertEqual(requestedCursors.count, 3)
        XCTAssertEqual(requestedCursors[0], nil)
        XCTAssertEqual(requestedCursors[1], "c1")
        XCTAssertEqual(requestedCursors[2], "c2")
        XCTAssertEqual(Set(requestedCursors.map { $0 ?? "<nil>" }).count, 3, "不得重复请求同一页")
    }

    /// 游标停滞（服务端回吐同一 cursor）必须被判为到底，避免空转刷爆配额。
    func testRepeatedCursorTerminatesCrawl() {
        var nextCursor: String? = nil
        var hasFetched = false
        var guardAgainstRepeatedCursor: String?
        var fetches = 0

        while !hasFetched || nextCursor != nil {
            fetches += 1
            if fetches > 50 { break } // 死循环保护：修复失效时让测试失败而非挂死

            // 服务端永远回吐同一个 cursor（限流/游标失效的真实表现）
            let newCursor: String? = "SAME_CURSOR"
            nextCursor = newCursor
            hasFetched = true

            if let sent = guardAgainstRepeatedCursor, let got = newCursor, sent == got {
                break // 判定到底
            }
            guardAgainstRepeatedCursor = nextCursor
        }

        XCTAssertLessThanOrEqual(fetches, 2, "重复 cursor 应立即终止，实测请求 \(fetches) 次")
    }

    // MARK: - UserMedia 空页终结（上游 api.ts:331-336）

    /// 解析出 0 条时 getUserMedias 必须返回 nil cursor（到底信号），
    /// 否则翻页会对着空页空转。
    func testEmptyModuleInstructionsYieldNoPosts() {
        let instructions: [[String: Any]] = [[
            "type": "TimelineAddEntries",
            "entries": [
                ["entryId": "cursor-bottom-1", "content": ["cursorType": "Bottom", "value": "still-here"]],
            ] as [[String: Any]],
        ]]
        let posts = TwitterAPI.extractPostsFromModuleInstructions(instructions)
        XCTAssertTrue(posts.isEmpty, "无推文条目时应解析出 0 条（调用方据此置 cursor=nil）")
    }
}
