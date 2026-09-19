# XSpiderMac 开发手册（架构 · 已知问题 · 修复方案）

面向在本仓库工作的 agent / 开发者。上游行为以 vendor 进来的 `src/`（React + zustand）为准。
文中行号以 2026-09 HEAD（b4348ba）为准， drift 时以函数名为准。

## 1. 架构地图

### Swift 应用（`XSpiderMac/Sources/XSpiderMac/`）

| 文件 | 职责 |
|---|---|
| `Services/TwitterAPI.swift` | 全部 X GraphQL 调用与 JSON 解析（对应上游 `src/twitter/api.ts`） |
| `Services/NetworkClient.swift` | HTTP 重试/退避/代理（对应上游 `src/ipc/network.ts`；16 次重试、429 特殊退避 10–16s） |
| `Services/XClientTransaction.swift` | x-client-transaction-id 生成（2025 X 校验必需） |
| `Services/Aria2Engine.swift` | 内置 aria2Next 下载引擎 |
| `Stores/HomepageStore.swift` | 搜索用户 → 媒体网格的数据源（上游 `src/stores/homepage.ts`） |
| `Stores/HomeTimelineStore.swift` | 主页推荐/关注时间线（mac 版新增，上游无） |
| `Stores/CreationTaskStore.swift` | 「下载全部」创建任务爬虫（上游 `src/stores/download.ts` `runCreationTask`） |
| `Stores/DownloadStore.swift` / `SyncStore.swift` / `AppStore.swift` / `SettingsStore.swift` | 下载队列 / 同步 / 账户与搜索历史 / 设置 |
| `Views/HomeView.swift` | 搜索栏 + 用户卡 + 下载配置 + **媒体网格（`MediaGridItem`）** |
| `Views/HomeTimelineView.swift` | 主页时间线卡片（`TimelinePostCard`） |
| `Support/ImageCache.swift` | 头像/缩略图 磁盘+内存缓存（全 MainActor，见问题 B3） |
| `Support/GlassCompat.swift` | 液态玻璃材质封装 |

### 关键数据流（搜索用户 → 媒体网格）

```
HomeView.submitSearch
  → HomepageStore.loadUser → TwitterAPI.getUser(UserByScreenName)
  → HomepageStore.loadPostList → TwitterAPI.getUserMedias(UserMedia, 首页省略 cursor)
  → postList + postListCursor
网格滚动到底 → HomeView.bottomLoader(.task) → HomepageStore.fillViewport
  → while cursor != nil: loadMorePostList → getUserMedias(cursor)（400ms 节流）
「下载全部」→ CreationTaskStore.runCreationTask
  → 按 filter.source 选 getUserMedias / getUserTweets 循环翻页
```

### 上游对应语义（改分页前必读）

- **`src/stores/homepage.ts`**：`loadPostList`/`loadMorePostList` 三连 guard（未初始化/加载中/无
  cursor），成功即 `concat + cursor 原样更新`，**不做去重**。
- **`src/twitter/api.ts getUserMedias`**：解析只取第一个 `TimelineTimelineModule` 的 items，否则
  `TimelineAddToModule.moduleItems`；**解析出 0 条时返回 `cursor: null`（到底信号）**。
- **`src/components/InfiniteScroll.tsx`**：`while (hasMore && 内容高度 ≤ 视口+阈值)` —— **补拉到
  视口填满（约两屏）即停**，后续靠滚动事件逐页触发。这是防 429 的核心节奏。
- **`src/stores/download.ts runCreationTask`**：`fetch → nextCursor = cursor → now = last.createdAt →
  日期/类型过滤 → continue/创建`。cursor 推进发生在任何过滤与 continue 之前。

## 2. 根因与上游复刻（2026-09-16 第二轮，实证）

> 第一轮的结论部分有误，已被日志与二进制时间戳推翻。**排查此类"改动没生效"问题的第一步，
> 是先确认跑的是哪个构建**：启动日志会打印 `应用启动 … executablePath=…`，对照它即可。
> （曾出现 Xcode 运行 `~/Library/Developer/Xcode/DerivedData/...` 的旧产物，而改动产物在
> `XSpiderMac/build/DerivedData`，导致"修复无效"的误判。）

### P0-A 列表停在约 20 帖 / ~27 媒体 —— 根因：填充循环被 SwiftUI 自杀式取消

`HomeView` 用 `.task(id: store.postList.count)`（后改 `fillGeneration`）驱动填充，而**这个 id 在每次
成功翻页后必然变化** → SwiftUI 取消并重启任务 → 整个 while 只推进一页就被取消。叠加两个放大器：

- 被取消的请求抛 `URLError.cancelled`，`NetworkClient` 把它当作可重试错误；
- `try? await Task.sleep` 在任务已取消时**立即返回不睡眠**，退避形同虚设。

实测后果：日志里 **5400 行 `error=cancelled … remains=16→1` 全部挤在同一毫秒**，每次切用户/滚动
都在空转重试并真实发出请求 —— 这既是"卡上限"，也是"创建任务时大量请求、账号被限流"的主因。

**修复（已落地）**：
- 填充循环改由 store 持有（`fillTask`），视图只调用 `triggerFill()` 表达"到达底部"，循环不再受
  重渲染影响；
- `NetworkClient`：取消 → 立即抛 `CancellationError`（不重试、不计次），`URLError.cancelled` 视为取消；
  新增取消感知睡眠；429 最多重试 3 次并优先遵循 `Retry-After`；
- 停止条件复刻上游 `InfiniteScroll.tsx`：`bottomSentinelY <= viewportHeight * 2`，即
  `scrollHeight - scrollTop <= clientHeight + clientHeight`（上游 `threshold < 0` 时取 clientHeight）。
  哨兵由 `BottomSentinel` 上报自身在命名坐标空间的 `maxY`，macOS 14 兼容（不用 macOS 15 的
  `onScrollGeometryChange`）。

### P0-B 数据源不路由 + 空页不终结

- `loadPostList`/`loadMorePostList` 此前**永远**调 `getUserMedias`，「推文时间线」名存实亡；
  现按 `filter.source` 路由（对照上游 `download.ts` 的 `getListFn`），推文源传 `requireMedia: false`
  以展示无媒体推文。
- `getUserMedias` 解析出 0 条时返回 `cursor: nil`（上游 `api.ts:331-336` 的到底信号）；解析扩为
  超集（module ∪ 散装 `tweet-*` 条目，按 `rest_id` 去重），避免 X 偶发无 module 的页导致提前到底。

### P0-C 创建任务：忠实复刻上游 `runCreationTask`

上游循环铁律（`src/stores/download.ts:413-502`）：

```
while (nextCursor !== null && now.isAfter(since)) {
  fetch(nextCursor)
  nextCursor = cursor           // ← 必须紧跟 fetch，早于任何过滤与 continue
  now = last?.createdAt || now
  日期过滤 → 媒体类型过滤 → sameFileSkip → batchCreateDownloadTask
}
```

Swift 版此前把 cursor 推进放在循环尾（`continue` 之后），被日期/类型过滤清空的页会用旧 cursor
重抓同一页 —— 这就是"上次修复引入重复检索"的成因。现已按上游顺序重排。

另加两条**有意的加固**（上游没有，但 Swift 循环节奏不同于浏览器渲染）：

1. **游标未推进即判到底**：X 偶发回吐与上一页相同的 cursor，上游会原地空转刷爆配额，此处退出。
   正常翻页不受影响；不设任何页数上限。
2. **批量跳过静默**：`batchCreateDownloadTasks` 传 `silent: true`，跳过时不发系统通知
   （否则「下载全部」扫到上千条已下载媒体会弹满通知并卡住 UI）。

### P1 滑动卡顿 —— 图片管线（已修复）

`MediaGridItem` 原用裸 `URLSession` + `@State` 缩略图（随 LazyVGrid 视图销毁而丢，滚回重下重解），
且 `?name=small` 实为 **680px 宽**（旧注释写 120px 有误），`NSImage(data:)` 惰性解码落在主线程首绘。

现统一走 `ImageCache`：下载/读盘/解码全在后台，`CGImageSourceCreateThumbnailAtIndex` 按
`maxPixelSize` 降采样并 `kCGImageSourceShouldCacheImmediately` 立即解码；内存层 `NSCache`
（自动响应内存压力），磁盘清理后台节流（60s 至多一次全目录扫描）；key 含尺寸档位
（缩略图 600、详情大图 1600）。

### P2 其他观察（不紧急）

- `HomeTimelineStore.loadMore` 把"重复页"当到底处理，方向安全，可与 P0-B 的终结语义统一。
- `FollowingListSheet` / `SyncStore` 也依赖 UserMedia 解析，P0-B 的解析超集同样受益。
- `MediaDetailView` 已改用 1600px 档位，勿退回 orig 直读。

## 3. 验证清单（改动分页/爬虫/图片管线后）

1. `script/build_and_run.sh` 构建通过；单元测试全绿。
2. 搜索一位媒体量大的用户（>100 条）：
   - 媒体时间线滑到底，总数持续增长超过 40 条，无重复卡片（按 media.id 查重），无 429 转圈。
   - 切到推文时间线，列表内容确实变为推文卡（含纯文字推文行为差异符合预期）。
3. 对同一用户连点两次「下载全部」：第二次应提示重复或全部 skip，绝不出现同 URL 两条任务。
4. 快速来回滚动媒体网格：无明显掉帧；滚回顶部图片不重新闪载。
5. `log stream --predicate 'process == "XSpiderMac"'` 观察 NET 分类：翻页请求间隔 ≥1s 量级，
   无连续 429。

---

## 4. 本轮新增（2026-09-16 第三批）

### 详情浮层

- **呈现路径统一**：`HomeView` 里独立的 `.sheet(item:)` 已删除，三处入口（主页时间线、
  搜索媒体网格、搜索推文时间线）全部走 `DetailOverlayCenter` 全窗浮层，外观与关闭行为一致。
- **无媒体推文**：`MediaDetailView` 媒体卡补空态（此前 `current == nil` 只剩黑底，
  看起来像界面崩了）；无媒体时不渲染下载胶囊（不再出现"下载全部(0)"）。
- **右上角圆形关闭按钮**：全屏浮层下此前只能盲点空白或按 ESC，用户找不到出口。
- **媒体索引重定位**：`detail` 返回的媒体集合与列表不一致时（数量/顺序变化），按媒体 id
  重新定位 `mediaIndex`，避免页码错乱。

### 日期显示

统一为 `Date.postDisplayText`（`TwitterAPI.swift` 扩展）：**含年份**，并显式绑定
`L10n.language` 而非系统 Locale——项目 UI 语言由设置驱动，两者可能不一致（避免中英混排）。

### 双指左右滑切换媒体

**旧实现不触发的原因已定位**：`ScrollWheelCatcher` 是 `NSViewRepresentable`，被放在
`.background` 且带 `allowsHitTesting(false)` —— 该视图不参与命中测试，`scrollWheel(with:)`
收不到事件。改为 `NSEvent.addLocalMonitorForEvents`（窗口级事件监视器，不依赖命中测试、
不吞点击、与 AVPlayerView 互不干扰）。同时新增**惯性判定**：`momentumPhase` 非空期间不触发，
一次手势（`.began` → `.ended`）内最多触发一次，避免触控板惯性滚动连跳多张。

### 限流缓解（可配置）与被动状态提示

- `Services/RequestGate.swift`：全局闸门 = 令牌桶 + **同类别互斥** + 429 熔断。
  同类别互斥是必须的：单靠"上次完成时间"挡不住并发同时发起（实测首页并发 3 个
  `friendships/show.json`）。异常安全：先取令牌再占互斥，中途取消不留残留锁。
- `Stores/AccountStatusStore.swift`：**被动**状态采集，唯一入口是 `NetworkClient`
  （所有 X 请求的汇聚点）。不主动探测、不发预检请求、零额外配额。状态 `Equatable`
  比较后才写，正常态快路径只做一次枚举比较；仅状态迁移写日志。
- 侧边栏账户卡下方状态标签：429 → 红色「429 限流」，401/403 → 橙色「登录失效」（点击直达
  Cookie 导入），5xx/网络错误各有表述；正常态整个标签不渲染。
- 设置页「限流缓解」区：闸门开关、每时间窗请求数、时间窗秒数、同类串行、熔断开关、
  暂停时长、立即恢复——全部用户可配，`nil` 安全且有范围钳制。

### 主页推文/媒体分段 + 媒体瀑布流

- `HomeTimelineView` 新增形态分段（推文 / 媒体），持久化到 `home.timelineContent`。
- `Views/WaterfallLayout.swift`：最短列优先的瀑布流 `Layout`。媒体单元高度由**元数据宽高比**
  算出（不依赖图片解码），因此测量廉价；图片按自身比例占据高度，不再被裁切或 letterbox 到
  统一格子里。列数随窗口宽度自适应（2–6 列）。
- 数据源同一条主页时间线：`getHomeTimeline` 改为 `requireMedia: false` 返回全部推文，
  由展示层分流（推文段显示全部含纯文字，媒体段取有媒体的部分），**切换形态不产生新请求**。

### 另一个限流放大器（顺手修掉）

每张推文卡的 `FollowButton` 都会在出现时查一次 `isFollowing`；时间线上同名作者重复出现时
会产生大量重复请求。已加 300 秒过期缓存，关注/取关后失效该用户缓存。

---

## 5. 判定依据的设计取舍（改这块前必读）

代码里有两套**互相独立**的"相同文件"判定，各自有两个依据。它们不是重复实现，
而是面向不同使用习惯，语义差异是**有意**的。

### 5.1 下载判定（`DownloadStore.isDuplicate` / `hasDownloaded`）

| 依据 | 判据 | 适用与代价 |
|---|---|---|
| **按文件名** `fileName` | 解析模板 → **在扩展名前追加资源索引** → 查该文件是否存在 | 不额外维护文件；但改名/移动文件后视为未下载 |
| **按下载记录文件** `recordFile` | 查每用户目录 `.downloaded.json` 里是否含该媒体 ID | 改名、移动、整目录搬家都不影响判定；代价是多一个记录文件 |

**为什么"按文件名"要强制追加资源索引**：用户模板可能不含任何唯一变量
（如 `%USER_SCREEN_NAME%%EXT%`），同一用户的多张媒体会解析成同一个名字，
判定就永远只认第一个文件、其余被误判为已下载。索引让文件名本身成为可靠判据。
默认模板因此定为 `%POST_TIME% %USER_SCREEN_NAME% %POST_ID% %EXT%`——
`%POST_ID%` 与 `%EXT%` 之间那个空格就是索引的位置（解析后形如 `… 123 2.jpg`）。
模板里若已显式写了 `%MEDIA_INDEX%` 则不再追加，尊重用户选择。

**为什么"按下载记录文件"不做"记录 ↔ 文件"双向校验**（曾经加过，后又移除）：
该依据存在的**唯一意义**就是"改文件名模板、重命名、移动文件后记录依然有效"。
若命中记录后再回头校验文件是否存在，用户一旦改了文件名就会被判成"没下载过"
而重复下载整库 —— 恰好抵消掉它唯一的优势。因此这里**只信记录**。
（历史坏记录的清理由"按文件名"依据或手动清理承担，不在此处兜底。）

**一个易踩的坑：判定结果不会被自动观察。** `hasDownloaded` 即时算出，读的是两个
`static` 缓存与文件系统，这些都**不参与 `@Observable` 依赖追踪**。所以切换判定依据、
改保存路径、清缓存后，判定结果变了但 SwiftUI 不重绘 —— 表现为"媒体卡上的下载/已下载
按钮状态停在旧结果"。解法是 `DownloadStore.judgementVersion`：视图读取它建立观察依赖，
影响判定的操作自增它即可（`invalidateJudgements()` / `refreshDownloadedCaches()`）。
**以后凡在视图 body 里调用这类"读 static 状态/文件系统"的函数，都要一并读版本号。**

### 5.2 同步判定（`SyncStore`，与下载判定独立）

| 依据 | 判据 |
|---|---|
| **按文件名** | 等同下载判定的"按文件名" |
| **按同步记录文件** | 每用户一份 `.synced.json`：`anchorDay`（最新媒体日期）+ 该日媒体 ID 集。翻页时**遇到比锚点更早的日期即停止**，用于加速重复同步 |

两个已修的实现陷阱（改这块务必保持）：

1. **提前终止不能用 `allSatisfy`**：要求"整页全部早于锚点"才停，而 X 的分页同页跨天
   很常见，只要有一条当天/更新的就永远不停 → 加速形同虚设，每次仍翻满 `maxPages`。
   正确判据是"该页**出现了**比锚点更早的日期"（时间线按时间降序，出现即后续只会更早）。
   同时不应要求 `page > 0` —— 第一页就可能整页更早。
2. **写记录必须以上次记录为起点累加**，不能本轮用空集合覆盖。本轮最多翻
   `maxPages` 页；若锚点日有 300 条而只翻到 100 条，覆盖写入会让其余 200 条
   丢掉"已同步"标记，下次同步被当成新内容重复处理。

---

## 6. aria2Next 与标准 aria2 的关键差异（踩过的坑）

**本项目内置的是 aria2Next**（`AnInsomniacy/aria2-next`，Rayburst 的嵌入式引擎），
它虽然兼容 aria2 的 CLI/RPC 表面，但**内部引擎已被替换**。把标准 aria2 的用法
照搬过来会出现"设置了没效果"甚至"功能静默失效"。已确认的差异：

| 项 | 标准 aria2 | aria2Next |
|---|---|---|
| 续传状态 | 下载目录旁的 `<文件>.aria2` 控制文件 | **设计上移除**；改存 `--state-dir` 下的 SQLite（`stream/state.db`） |
| 分块连接数 | `--split` + `--max-connection-per-server` | **已退役**，现为 `--stream-max-connections`（默认 6，范围 1–256） |
| 最小分块大小 | `--min-split-size` | **已退役且被引擎完全接管**（传了会被跳过并警告） |
| `--continue` | 基本续传 | 更强：先校验远端长度，等长直接完成、更短才续传、更长或不可续报错保留 |

由此产生的两处**已修**问题：

1. **依赖 `.aria2` 的续传判定必须删除**（`Aria2Engine.startViaSubprocess` 旧逻辑）。
   旧代码"控制文件不存在就删掉数据文件"，而新引擎永不生成控制文件 → 条件恒真 →
   **每次恢复都先删已下载数据，等于从头下载**。新引擎的 `--continue` 自身已做长度校验，
   预删纯属破坏。
2. **设置项要与引擎能力对齐**：已移除"最小分块大小"（死设置），
   "单文件连接数"改名为 `stream-max-connections` 的语义并把范围放到 1–256、默认 6。

另外 aria2Next 默认会尝试监听 6881（BT 端口），端口被占时每次下载刷十几行 error 日志。
本项目只做 HTTP 下载，已在启动参数里关掉 DHT/LPD/PEX。

**排查手段**：aria2Next 对退役选项会打印
`Legacy aria2 input ... accepted and skipped` / `approximately mapped to ...`，
看到这类警告即说明该选项已失效，应查官方手册
（`docs/manual/en/aria2-next.rst`）确认现名。

---

## 7. 已移除的死代码（勿再当作"已实现"）

### 7.1 评论发布输入框（已删除）

`MediaDetailView.repliesCard` 底部曾有一个「发布你的评论…」输入框 + 「发送」按钮，
但它是**纯占位、从未实现**：

```swift
TextField(L("发布你的评论…"), text: .constant(""))  // 常量绑定：打不进字
Button(L("发送")) {}                              // 空实现
    .disabled(true)                               // 永远禁用
```

全仓库没有 `CreateTweet` 端点实现（上游 `src/` 也没有）。**已删除该 UI**，
以免被误认为"评论功能已存在只是不好用"。

若将来要做"发布评论"，那是**从零新增**，主要难点是自行获取并维护
`CreateTweet` 的 queryId 与 features（属新增端点，会随 X 改版失效）；
评论区现在的定位是**只读浏览**。

### 7.2 版本基线与"不要写降级分支"

最低系统版本 **macOS 14.4**（原为 14.0，为使用系统 `Translation` 框架而提升）。

**明确约定：不为版本差异写降级/隐藏分支。** 支持范围就是 14.4+，
直接用满足该版本的 API 即可。不要加"旧系统隐藏按钮"或"回退旧实现"这类代码——
那会增加维护面、且无法在本机测试（本机系统远高于 14.4）。

---

## 8. 翻译（系统框架，不消耗 X 配额）

**最低系统版本因此为 macOS 15.0**（`Translation.framework` 的要求）。

### 8.1 为什么用系统翻译

| 方案 | 结论 |
|---|---|
| **系统 `Translation.framework`** | ✅ 采用。**零 X 配额**、语言包下载后可离线、无需维护 queryId |
| 抓 X 的翻译 GraphQL 端点 | ❌ 需自行获取 queryId（随改版失效），每次翻译消耗配额、可能诱发 429 |

项目一直在对抗 429 限流，**"不消耗 X 配额"是决定性理由**。
翻译全程不经 `RequestGate`，也不产生任何 X 请求。

### 8.2 Swift 6 严格并发的坑（重写这块务必看）

`TranslationSession` **未标 `Sendable`**，而它的 `translate` 是 `nonisolated` 方法。
在 Swift 6 下，只要「session 与非隔离域状态出现在同一段代码」就会被判定为
跨隔离域发送，报：

```
sending 'session' risks causing data races [#RegionIsolation::SendingRisksDataRace]
```

踩过的三种写法**都不行**：把 session 传进 `@MainActor` 的 store、
在 `translationTask` 闭包内 `await MainActor.run`、把翻译抽成 `nonisolated` 静态函数
（反而把主 actor 隔离的 session 送出去）。

**正确做法**：
1. `@preconcurrency import Translation` —— 这是官方为"尚未适配严格并发的系统框架"
   提供的退路，也是这个问题的**根因解法**；
2. `translationTask` 挂在一个**只持有 config/text/key 三个值**的极简子视图上
   （本项目的 `TranslationRunner`），闭包不捕获外层视图状态；
3. 会话之外的状态读写走 `MainActor.run`，且**不与 session 同处一个 await 链**。

### 8.3 交互与状态

- `TranslationStore`（`@MainActor @Observable`）：译文缓存、翻译中、显示状态、错误。
  key 用推文 ID（同一条正文只翻一次，来回切换不重算）。
- 每处正文（时间线卡 / 详情卡 / 每条评论）都带「翻译 / 显示原文」按钮。
- **必须新建 `TranslationSession.Configuration` 实例**才能触发会话；复用同一实例不会重新执行。
- 目标语言变更时要 `TranslationStore.clearAll()` —— 旧译文对应旧目标语言。

### 8.4 自动翻译的判据

**只翻译"语言已知且 ≠ 目标语言"的推文**：

- `TwitterPost.lang` 来自 GraphQL `legacy.lang`，**无需额外请求**；
- `lang` 为 nil/空时**不自动翻译**（不猜语言，交给用户手点）；
- 语言比对只比主语言子标签（`zh-Hans` 与 `zh` 视为同语言），见 `isSameLanguage`。

自动翻译**默认关闭**：默认开启会让每次浏览都触发翻译，打扰且耗电。

---

## 9. 评论区层级、推广内容过滤与返回导航（2026-09-18）

本轮四项改动，全部用**真实 TweetDetail 响应**核对过结构
（`2100649211276529930` 无媒体且引用他人、`2099484254740631767` 带媒体且引用他人）。

### 9.1 推广内容（广告）过滤

**判据**：`itemContent.promotedMetadata` 非空即为广告
（schema 见 `.fetch/openapi.yaml` 的 `TimelineTweet.promotedMetadata`）。

实测确认：真实响应里广告挂在 **`conversationthread-*` entry 的 item 上**
（路径 `entry.content.items[0].item.itemContent.promotedMetadata`），
`adMetadataContainer` / `advertiser_results` / `impressionId` 等键齐全，
正文与主推文毫无关系（`2100649211276529930` 里是 3 条投资/背包广告）。

三处解析入口都已过滤：

| 入口 | 用途 |
|---|---|
| `extractPostsFromModuleInstructions` | UserMedia → 媒体网格 |
| `extractPostsFromTweetEntries` | UserTweets / 主页时间线 / 推文时间线 |
| `extractReplyNodes` | TweetDetail → 评论区 |

**为什么必须过滤**：评论区里混进广告是用户直接反馈的问题；
媒体网格里混广告会让"下载全部"把无关媒体的链接也算进去。

### 9.2 评论层级树（保留父指针）

**旧问题**：`extractPostsFromTweetEntries` 把 `conversationthread-*` 的 items
压平成 `[TwitterPost]`，`legacy.in_reply_to_status_id_str` 这个**现成的父指针**就此丢失，
评论区只能平铺，看不出评论的评论从属于谁。

**新结构**：`ReplyNode { post, parentId, parentScreenName, depth, isPartialParent }`，
由 `TwitterAPI.extractReplyNodes(_:focalId:)` 构建。**不需要额外请求**——
父指针与 `in_reply_to_screen_name` 都在响应里
（实测每条回复两者都有）。

必须遵守的四条：

1. **排除 focal 本身**：它是根不是回复。留着会被算成 depth 1，
   与"直接回复"无法区分，且渲染时重复显示主推文。
2. **孤儿不能丢**：X 只返回部分会话，父可能不在本页。这类回复 depth 记 1、
   标 `isPartialParent = true`，展示时加「回复 @xxx」前缀（有专门单测）。
3. **环保护**：异常数据里 A 回 B、B 回 A 会死循环，`resolve` 用 visiting 集合挡住。
4. **「回复 @xxx」用被回复者**（`parentScreenName`），不是本条作者——
   用错了会显示成"张三 回复 张三"。优先取响应里的 `in_reply_to_screen_name`，
   缺失时回落到父节点的 `post.user.screenName`。

### 9.3 评论排序（相关 / 喜欢 / 最近）

`ReplySort`：`relevance` **保持服务端顺序**（X 默认排序自带相关性信号，
本地重排只会更差）；`likes` / `recent` 是服务端没提供排序变量时的本地兜底。
排序**稳定**（同键值保持原序），避免每次刷新顺序乱跳。

### 9.4 返回导航（`NavigationHistory`）

**需求**：详情里点引用推文跳到 B，返回要回到 A；点头像去搜用户，返回也要回到 A。

**设计**：一个显式历史栈，只记**跨越界面**的跳转（对称的"打开详情→关闭"不入栈）：

- 详情里点**引用推文** → 入栈当前推文（`DetailOverlayCenter.openFromDetail`）；
- 详情里点**头像** → 依次入栈"主页状态 + 当前推文"，于是返回两下依次回到详情、主页；
- 主页搜索某用户 → 入栈"当前主页状态"。

主页状态用**快照还原**（`HomepageStore.SearchState`），**零请求**且列表原样：
重新 `loadUser` 会再打两个 GraphQL 请求，为"回退一步"消耗配额不可接受。

三处容易踩的坑：

1. **`.id(post.id)` 必须加**（`ContentView`）：浮层内换推文时若不加，
   SwiftUI 复用同一视图实例 → `@State`（detail/replies/liked/mediaIndex）
   全保留上一条的值，`.task` 也不重跑，表现为"跳到引用推文后内容还是上一条的"。
2. **ESC 只能注册一个**：返回按钮与背景快捷键都注册 `.escape` 时只有一个生效，
   语义会随注册顺序漂移（"有时返回、有时直接关"）。
   现在 ESC = 返回，点卡外空白 = 直接关闭。
3. **返回按钮用强调色 + 返回图案**（`arrow.uturn.backward`），
   与「关闭」语义区分开。

#### 两个「关闭」必须区分清楚

| 方法 | 语义 | 是否动历史 |
|---|---|---|
| `DetailOverlayCenter.close()` | 用户**离开详情**（点卡外、ESC 到栈空） | **截断**回进入时的深度 |
| `DetailOverlayCenter.dismissOverlay()` | 只是收起浮层，之后还会回来 | 不动 |

不截断的话会残留：关闭详情 A → 从主页打开详情 C → 按返回会跳到无关的 A。
反过来，`searchUser`（点头像去搜用户）与 ContentView 重放 `.home` 时**不能**用
`close()`——前者会丢掉刚压入的"返回回详情"记录，后者会把更早的记录一起丢。

### 9.5 详情短期缓存（`TweetDetailCache`）

为解决 9.4 第 1 条的"重建视图"代价：重建会重跑 `.task` → 再请求一次 TweetDetail。
于是"点引用推文 → 返回"会把看过的推文重新请求一遍。

`TweetDetailCache` 按推文 ID 缓存 `(focal, replies)`，**TTL 5 分钟**、容量 12 条、进程内。
回看刚看过的推文**零请求**。用户点赞/书签/转推后 `invalidate` 该条（计数已过时）。

TTL 取 5 分钟的原因：评论会变（新回复、点赞数），缓存太久显得数据陈旧。

### 9.6 搜索框焦点：原生焦点环的层级问题

两个用户反馈合并成一个根因：

- 「篮框会浮现推文详情上」——原生焦点环由 **AppKit 单独绘制**，
  层级在 SwiftUI 之上，`zIndex` 管不到它；
- 「点输入框会变色一闪一闪」——带 `roundedBorder` 时聚焦/失焦会切换背景色。

**解法**：输入框改 `.textFieldStyle(.plain)` + `.focusEffectDisabled()`
（视觉容器交给外层已有的玻璃条），并在详情浮层出现时广播
`.homeResignSearchFocus` 主动交出焦点（双保险）。

---

## 10. 评论媒体、评论计数与强调色的用法（2026-09-19）

### 10.1 评论自带的媒体（此前根本没渲染）

**问题**：`replyRow` 只画头像 + 文字，评论附带的图片**完全没渲染**。
带图评论（实测 `@leoakok` 在 `2100550768965423303` 下那张 947×2048 的照片，
赞 326 / 回复 3）只显示一行文字，看起来像图片丢了。

**解析层本来就有数据**：`legacy.entities.media` 已被 `mapTwitterPost` 映射进
`post.medias`，`extractReplyNodes` 也原样带出——**是渲染层没画**。
排查这类"功能好像不存在"的问题时，先确认是解析缺失还是渲染缺失。

**实现要点**（`replyMediaRow` / `ReplyMediaThumb`）：

1. **单张保持宽高比**（`maxWidth/maxHeight: 168`）——竖长图（947×2048）
   按 1:1 裁切只剩中间一条，看不出是什么。
2. **多张用小方格 64pt**，尺寸必须收着算：卡片宽 410，减去内边距、缩进
   （最深 48）、头像（30+10）后约 294pt；`4×64 + 3×4 = 268` 才放得下，
   用 84 会溢出被裁。
3. **一律走 `ImageCache` + 目标尺寸降采样**（单张 320、多张 180）：
   评论区一次可显示几十条，按原图（可能 2048px）解码会拖慢滚动。
   URL 加 `?name=small`（约 680px，见 AGENTS.md 大坑 5）。
4. `TwitterMedia.aspectRatioValue` 保证返回**必定可用**的比例
   （width/height → videoInfo.aspect_ratio → 16:9 兜底），调用方不用处理 nil。

### 10.2 评论计数

每条评论显示点赞数与回复数（`favoriteCount` / `replyCount`，数据已在
`TwitterPost` 里，无需额外请求）。用 `Label` + `.titleAndIcon`，与推文卡计数行一致。

### 10.3 强调色的正确用法：**背景**而非图标/文字

**用户要求**：需要强调的按钮，强调色用在**按钮背景**上，不是把图标染成强调色。

理由：纯色淡底 + 强调色图案对比度不足，视觉权重也不像主操作。

已按此调整：

| 位置 | 改法 |
|---|---|
| 详情卡返回按钮 | 圆底填 `Color.accentColor` + **白色** `arrow.uturn.backward` |
| 关注按钮（未关注态） | 实心强调色胶囊底 + 白字；「已关注」保持淡底灰字（中性状态，点它=取关，不该抢视线） |
| 主操作按钮 | 一律用 `compatGlassProminentButton()`（`.borderedProminent` / `.glassProminent`，本身就是强调色底） |

**注意**：文字型次要操作（「翻译」「显示更多」「收起」）仍用强调色**文字**——
它们是行内小链接，不是按钮块，染成实心底会喧宾夺主。

---

## 11. 媒体查看窗口与筛选栏改版（2026-09-19）

### 11.1 媒体查看窗口（独立 NSWindow，不是 sheet）

`MediaViewerCenter` + `MediaViewerView`，用 `NSWindow` 而非 SwiftUI `.sheet`：

1. 看大图时用户往往想同时看到背后的列表（对照、继续挑），sheet 会锁住父窗口；
2. 缩放/旋转需要窗口级手势与工具栏；
3. 详情卡本身就是全窗浮层，再叠 sheet 会成"层中层"，ESC 与层级都难处理。

**切换范围必须区分**（`Session.Origin`）——需求明确要求：
详情页切的是**本推文内**的媒体；瀑布流切的是**整个瀑布流**的媒体；
搜索用户网格切的是该网格已加载的媒体。
所以 `open(medias:index:post:origin:)` 由调用方决定装入哪个列表。

**边界收敛**：`step(_:)` 越界时收敛到首/尾，而不是忽略。
忽略会让 `step(-10)` 停在原处（单测抓到的真实 bug）；
键盘长按 / 手势给更大步长时都要求它夹紧。

工具条在**底部独立一条**，不浮在媒体上（用户明确要求"按钮不要遮挡媒体"），
且**只用图标**（配 `.help`）。图片：缩放/复位/左右旋转 + 捏合手势 + 双击切换；
视频：播放暂停/回到开头/倍速循环 + 系统悬浮控制条。

### 11.2 三处媒体卡的按钮统一（`MediaCardActions`）

抽成共享组件的原因：需求要求"三处都要按已下载状态切换按钮"，
各写一份必然漂移——**瀑布流此前根本没有下载按钮**，正是这种漂移的结果。

- 三处都有：下载（已下载则显示绿勾）/ 放大镜（详细查看）；
- 搜索用户网格**删掉了「打开推文」链接按钮**（用户要求）；
- 判定读 `judgementVersion` 建立观察依赖，否则判定依据变化后按钮停在旧状态。

### 11.3 详情页下载按钮的文案（n−m 语义）

需求：不能只显示「下载全部(n)」，要按已下载数显示。

| 状态 | 文案 |
|---|---|
| 当前媒体已下载 | **当前已下载**（禁用） |
| 还有未下载 | 下载全部(**n−m**)，n=推文媒体数，m=已下载数 |
| 全部已下载 | **全部已下载**（禁用） |

`pending = max(0, n − m)`：夹到 0 防止出现「下载全部(-3)」
（记录文件里可能有本推文之外的媒体 ID 命中）。
「下载全部」只提交**未下载**的媒体，避免重复请求配额。
胶囊加了 `padding(.bottom, 14)`：此前紧贴卡片下缘，玻璃圆角会切到它。

### 11.4 搜索用户界面的筛选栏（取代「下载配置」卡片）

布局按需求：**左**=数据源分段 + 时间范围 + 「确定」（紧接账号卡片下方）；
**右**=媒体类型 + 「选择下载」，后两者**只在数据源 = 媒体时**出现
（推文时间线渲染推文卡，没有逐媒体勾选语义）。

**时间范围不即时生效**：改动只写 pending 值，点「确定」才 `setFilter` 并
`reloadWithCurrentFilter()` 刷新。拖日期就连发请求会打爆 RequestGate 与 429。

**数据源按用户记忆**（`HomepageStore.rememberedSource(for:)`）：

- key = `homepage.source.<screen_name 小写>`，**不跨用户**；
- 默认值 **`.tweets`（推文）**——用户明确要求，与旧默认（媒体）相反；
- **必须在 `loadPostList` 之前应用**：否则会先用默认源拉一页、再切源重拉，
  白白多一次请求（项目一直在对抗 429）。

### 11.5 选择模式的底部按钮

`撤销 / 全选 / 反选 / 全不选 / 下载所选`（`全选` + `下载所选` 等价于原来的「下载全部」）。
全选与反选基于 `flatMediaList`（即已按媒体类型筛选后的结果）。

**已删除 `SelectiveDownloadSheet.swift`**：它从未被引用（选择模式一直是内联的
`selectiveMode`），留着会让人误以为"选择页面"是那个弹窗。

---

## 12. 查看窗口的视频控制与闲置提示（2026-09-19 修正）

用户实测反馈两个问题，都已修复。

### 12.1 视频播放栏"点不动 + 遮挡画面"

**两个独立原因**：

1. **点不动**：`videoStage` 上盖了一层 `Color.clear { onTapGesture }` 做"点击播放"，
   它把底下 `AVPlayerView` 控制条的点击**全吃掉了**。
   → 改用 `.onTapGesture` 直接挂在播放器上，不再盖透明层。
2. **遮挡画面**：`AVPlayerView.controlsStyle = .floating` 的控制条浮在视频上。
   → 改为 `.none`，**播放/进度/倍速全部做进底栏**（用户要求"全做进底栏"）。

底栏现在有：回到开头、播放/暂停、**可拖动进度条**、`当前时间 / 总时长`、倍速（0.5↔1↔1.5↔2）、
下载当前、关闭。进度条拖动期间进入 `isScrubbing`，时间观察者据此跳过更新
（否则滑块与播放进度互相打架）。

### 12.2 视频状态收进 `VideoPlaybackModel`

`addPeriodicTimeObserver` 的闭包是 `@Sendable`，Swift 6 下无法直接写视图 `@State`。
状态收进 `@MainActor @Observable` 类后，闭包里用 `MainActor.assumeIsolated`
（回调已在主队列），避免每 0.25s 起一个 `Task`。

### 12.3 手势提示：从 `.help` 换成"闲置才出现"

**问题**：提示挂在整片媒体区上时几乎一碰就弹，且**在同一视图内移动不会消失**
（AppKit 工具提示的语义），用户反馈"太容易触发、消失时间与动画都太长"。

**解法**（`IdleHoverHintModifier`）：用 `onContinuousHover` 实现闲置判定——
**有回调 = 鼠标在动 → 立即隐藏并重排计时**；静默满 `delay`（默认 1s）才显示。
消失动画 0.1s、出现 0.15s（用户要求缩短）。提示 `allowsHitTesting(false)`，
绝不挡媒体或按钮。

`onContinuousHover` 是关键：它**只在鼠标移动时**回调，
所以"一动就取消"是天然的，不需要额外的鼠标位置比较。

### 12.4 评论媒体缩略图接上同一套按钮

评论缩略图与媒体卡用**同一套 hover 按钮**（`MediaCardActions`，直径 26pt，见 §11.2），
不单独做查看窗口。

**按钮挂在每一张缩略图上**（不是整行共用一组）：下载必须作用于确定的那张媒体，
整行共用会导致"多图时不知道在下载哪一张"。

**查看范围 = 该条评论自己的媒体**（`Origin.reply`）：需求原文是
「切换媒体就只能切换评论区的（先切换评论内的，没有在切换评论区的）」，
所以评论只有 1 张时前后切换无效，不会跳到主推文或别的评论（有专门单测）。

---

## 13. 选择下载语义 + 展示筛选（2026-09-19）

### 13.1 「全选」必须是"全部"，因此用**排除法**表示

**问题**：旧实现 `selectAll()` 只是把 `flatMediaList`（**已加载**的部分）灌进集合。
用户因此无法确定自己选了什么——"全选"到底是全部还是眼前这些？

**解法**：`Models/MediaSelection.swift` 引入两种模式：

| 模式 | 含义 | 用途 |
|---|---|---|
| `.include` | `keys` = 要下载的 | 用户逐个点选 |
| `.exclude` | `keys` = **不要**下载，其余全部要 | 「全选」态 |

全选态**不能**用"要下载的集合"表示：未加载部分不在前端，列举不出来。
只有排除法能表达"除这几个之外全部要"。`invert()` 就是换模式而集合不变
（补集恰好如此），所以反选是**对合**的（连按两次回到原状，有单测）。

**排除项如何真正生效**：`CreationTask` 增加 `excludedKeys` / `includedKeys`，
爬虫在逐媒体取舍时：

```swift
if task.excludedKeys.contains(key) { skipCount += 1; continue }   // 取消的：跳过并计数
if !task.includedKeys.isEmpty {                                    // 只勾了几个
    guard task.includedKeys.contains(key) else { continue }
    remainingIncluded.remove(key)
}
```

**`.include` 态会提前收工**：勾选的项都收齐就不再翻页（`remainingIncluded.isEmpty`），
这是"选择下载"相对旧「下载全部」的实质好处——只为自己要的东西付费翻页。

### 13.2 「下载全部」按钮已移除

功能由「选择下载 → 全选 → 下载所选」承担（用户决策）。
**爬虫保留**：全选含未加载部分，只能靠它翻页补齐；
若只用已加载列表建任务，全选就又退化成"全选已加载的"。

两条路径最终都走 `DownloadStore.createDownloadTask`，
因此**跳过已下载的判定（`sameFileSkip` / `isDuplicate`）完全一致**。

### 13.3 展示筛选：日期与媒体类型

**这是"调了时间范围点确定没反应"的修复**。

根因：`dateRange` 此前**只被爬虫使用**（`CreationTaskStore`），
展示路径 `HomepageStore.fetchPage` 完全没读它 → 重新加载拿到的还是全部。

`HomepageStore.applyDisplayFilter` 与爬虫**同一语义**：

- 日期：`since <= createdAt <= until`；**无 `createdAt` 放行**
  （缺字段不等于不在范围内，吞掉会让列表莫名缺条目）；
- 媒体类型：**至少有一张所选类型**的推文留下；**无媒体的纯文字推文不受影响**
  （否则勾掉"视频"会让纯文字推文一起消失）；
- 媒体网格（`rebuildFlatMediaList`）**也按类型过滤**，
  否则"推文因还有图片而留下、网格里却仍出现视频卡"。

**触发时机**（`setFilter`）：

- 数据源变化 → 清空重载；
- 媒体类型变化 → **只在本地重算**（已加载内容的呈现，不需要重新请求，省配额）；
- 日期变化 → **重新拉取**（服务端分页 + 客户端过滤的组合，
  光在本地过滤无法补出范围外的页）。

### 13.4 两个必须守住的顺序问题

1. **跨页去重必须先于筛选**：
   ```swift
   let deduped = r.posts.filter { seenPostIds.insert($0.id).inserted }
   let fresh = Self.applyDisplayFilter(deduped, filter: filter)
   ```
   先记 id 再过滤。反过来会让被筛掉的推文没进 `seenPostIds`，
   它在相邻页重复出现时又当新条目走一遍筛选。

2. **连续空页要有停止条件**：窄日期范围下会连续翻很多空页。
   `maxConsecutiveFilteredEmptyPages = 5`（爬虫侧同名常量同理），
   超出就停并显示「当前范围内暂未找到内容 + 继续查找」。
   不设上限会一直翻到服务端尽头——正是 AGENTS.md 大坑 3 的 429 风暴。
   判定基于**服务端原始条数**：服务端返回 0 条才是真到底，与筛掉多少无关。

### 13.5 批量建任务的节流

全选可能一次灌入上千任务，每个都要解析模板、查判定、起 aria2 请求，
瞬时灌入会让界面连续卡顿。`batchCreateDownloadTasks` 现在超过 50 条时
分批（每 25 条 `Task.yield()` + 50ms 停顿）；小批量不做节流（停顿反而变慢）。

### 13.6 「已选 n/m」的分母

需求：**不知道总数时不要显示分母**。
`postListCursor == nil`（服务端到底）时分母才是真实总数，显示 `n/m`；
否则只显示「已选 n」。全选态显示「已全选」/「已全选（共 N）」。

---

## 14. 搜索页加载：搜索端点 + 空窗期（2026-09-19）

### 14.1 背景：空窗期会把"加载"误判成"没有内容"

用户实测反馈：账号有**一两个月没发媒体**时，设了时间范围就加载不出内容；
中间有内容时才能正常往前加载。**根因是 §13.4 那条"连续 5 页被筛掉就停"**——
它把"时间轴上的空窗期"误判成"到达范围起点"。

实测数据（App 日志 `~/Library/Logs/XSpiderMac/xspider.log`）：

| 数据源 | 每页条数（实测众数） | 翻 5 页覆盖 |
|---|---|---|
| **媒体**（UserMedia） | **10** | **50 条** |
| 推文（UserTweets） | 20 | 100 条 |

媒体只有 10 条/页，5 页 = 50 条原始条目——一个不常发媒体的账号，
这就是**一两个月**。用户"感觉推文源容忍更大"也被证实：纯粹因为推文页条数是 2 倍。

**另一个证据**：日志里"连续多页"停止**一次都没记录**（`grep -c` = 0），
因为停止发生在 `runFillLoop` 入口的**静默 return**——所以 UI 上表现为
"加载中/无内容反复跳"，而非明确报错。

### 14.2 主方案：「加快搜索页加载」走 X 搜索端点（默认开）

设置项在**设置 → 主页**（`AppSettings.fastSearchLoading`，nil = **开**），带信息说明按钮。

开启且**设了时间范围**时，浏览改走 `SearchTimeline`：
时间范围由**服务端**过滤 ⇒ **不存在空窗期**，且一页返回的条数多得多。

**网页 URL 与端点的对应**（用户给的线索）：

```
https://x.com/search?q=from:USER since:A until:B&f=media  →  SearchTimeline, product="Media"
https://x.com/search?q=from:USER since:A until:B&f=live   →  SearchTimeline, product="Latest"
```

实测（`Da_aa_dad_`，2025-01-01~2026-09-01）：`product=Media` **40~42 条/页**，
`product=Latest` 20 条，均带 bottom cursor，且返回内容**全部落在范围内**。

#### 三个必须记住的实现要点

1. **必须 POST + JSON body**。实测：
   GET（query string）→ **404**；POST 表单编码 → **400**；
   **POST + `application/json` → 200**。
   ⚠️ **404 与 queryId 无关**——实测 openapi 记录的旧 queryId 与当前 bundle 的新值，
   用 POST **都返回 200 与 42 条真实数据**，只有随机乱写的才 404。
   我最初用 GET 试，误判成"queryId 失效"并去写自愈，纯属徒劳
   （自愈保留，但它的价值是"X 真改版时能跟上"，不是日常必需品）。
2. **queryId 可自愈**（防御性）：`SearchQueryIdProvider` 内置默认值
   （`fetch/openapi.yaml` 记录的 `Yw6L66Pw54NHKuq4Dp7b4Q`，实测有效），
   仅当确实拿到 404 才抓搜索页 HTML → `main.<hash>.js` → 正则提取 → 重试一次。
   抓 bundle 走 `abs.twimg.com` CDN，**匿名、不耗 X 配额**（实测 ≈2s）。
3. **提取正则必须锚定 `operationName:"SearchTimeline"`**：bundle 里还有
   `BookmarkSearchTimeline` / `ListSearchTimeline` /
   `GlobalCommunitiesPostSearchTimeline`，且**它们排在前面**，
   只按名字搜会取到别的 queryId。

解析**复用**现有 `extractPostsFromModuleInstructions`：搜索结果的条目结构
（`TimelineAddEntries` + `TimelineTimelineModule`）与 UserMedia 一致，
不需要第二套解析。

### 14.3 兜底：开关关闭时走时间线，终止判据改为**时间轴推进**

开关关闭（或未设时间范围）时走原时间线路径。**该路径的终止判据已修正**：

```
跟踪 oldestSeenAt = 服务端原始页里最旧一条的 createdAt
终止 = cursor 为 nil（真到底） ∨ oldestSeenAt < since（已翻过范围起点）
```

与爬虫的 `now > since` **同义**。关键点：

- **`oldestSeenAt` 必须取服务端原始页**，不能用筛选后的——
  否则空窗期里它不推进，又退化成"空页即停止"；
- **删除了 `maxConsecutiveFilteredEmptyPages`**（我上轮引入的错误抽象）：
  空窗期只是时间轴上的一段空隙，不等于到达起点；
- 顺带补上展示路径缺失的**游标不推进检测**（与爬虫同款）——
  X 偶发回吐相同 cursor，不检测会原地空转刷配额。

### 14.4 两个日期边界 bug（顺手修掉，两处都存在）

1. **「至」当天被整天排除**：`DatePicker` 给的 `end` 是**当天零点**，
   直接用 `createdAt <= end` 会把「至」那天全部滤掉，而用户视角应包含全天。
   `DateRange.inclusiveEnd`（当天 23:59:59）统一供展示过滤与爬虫使用。
2. **搜索日期必须用本地时区**：`DatePicker` 给的是**本地**零点，
   若用 UTC 格式化，在东八区会写成"前一天"，导致范围整体偏移一天。

另外 `until:` 取**次日**（X 语义排他）——注意**不能**用 `inclusiveEnd` 再 +1 天，
那会变成后天、多算一天（实测踩过）。

---

## 15. 缓存单位、状态标签、查看器与若干 UI 改进（2026-09-20）

### 15.1 缓存上限"不生效"：其实是**单位不一致**

**用户反馈**：「设了 200m，却显示有 209m 缓存，没见它清理」。

**根因不是没清理**（`grep 缓存超限自动清理` 有 **70 次**记录，一直在跑），
而是**限制与显示用了不同口径**：

| | 口径 | 200 的换算 |
|---|---|---|
| 限制（旧） | `× 1_048_576`（**MiB**） | 209,715,200 字节 |
| 显示 | `ByteCountFormatter.file`（**十进制 MB**） | 209.7 MB |

同一个数被写成两种单位，用户看到"设置 200、实际 209"自然以为上限失效。
**修复**：限制改为 `× 1_000_000`，与显示口径统一。
运行时验证：日志变成 `limit=200000000`，实际占用降到 197MB（真低于上限）。

### 15.2 评论的评论：只显示贴主的 —— **这是 X 服务端行为**

**用户反馈**：评论区只显示贴主对评论的回复，不显示其他人对评论的回复。

**实测结论：确实如此，且不是我们的解析问题。** 证据：

1. 以该推文为 focal：`conversationthread-*` 下每条二级回复的作者**都是贴主**
   （`EliottYRT`），别人的回复根本不在响应里；
2. 以**那条评论本身**为 focal 再查一次：只返回 1 条（仍是贴主），
   且 entries 里**没有"显示更多回复"的游标**——说明服务端不提供；
3. 参数变体（`withBirdwatchNotes`、去掉空键等）返回结果**完全一致**。

与 X 网页端行为一致（网页上"查看回复"也只展开贴主的那条）。
**因此不改解析**——按服务端给的展示就是正确行为。

### 15.3 查看窗口（视频侧）

- **视频也支持捏合缩放手势**（此前只有图片）；双指左右滑切换两种媒体都有；
- **手势提示移到窗口标题后常驻**（`NSTitlebarAccessoryViewController`）：
  原先做成悬停提示，会遮挡画面；现在属于窗口 chrome，不占媒体区域；
- **打开查看窗口时暂停详情页的预览**，且**继承其播放进度**：
  进度以**视频 URL** 为键（详情页只有 AVPlayer，两边都能拿到 URL），
  见 `MediaViewerCenter.rememberProgress/resumeTime`；
- **倍速图标换成 `speedometer`**：原 `goforward` 与「复位」的
  `arrow.counterclockwise` 都是圆弧箭头，肉眼难分（用户反馈）；
- **全屏按钮**（`toggleFullScreen`，并登记 `.fullScreenPrimary`）；
- **字幕**：接入系统媒体选择 API，可选字幕语言或关闭。

### 15.4 字幕功能的版本要求（用户特别询问）

用的是 AVFoundation 的媒体选择 API：

| API | 最低版本 |
|---|---|
| `AVPlayerItem.select(_:in:)` | **macOS 10.8** |
| `AVAsset.mediaSelectionGroup(forMediaCharacteristic:)` | **macOS 10.8** |
| `AVMediaSelectionGroup` / `AVMediaSelectionOption` | **macOS 10.8** |

**远低于项目基线 15.0，因此不需要任何版本判断或降级分支**。
实现见 `Support/SubtitleSupport.swift`。

注意：选的是**视频自带的内嵌字幕轨**。X 的视频通常没有内嵌字幕，
此时**按钮不显示**（不是 bug）。这不涉及模型翻译，不要与翻译功能混淆。

### 15.5 详情页视频卡：去掉系统播放条

`VideoPlayerContainer` 改 `controlsStyle = .none`。原因：
① 详情卡是紧凑预览位，系统播放条占一行高度；
② 它带一个「提取视频页面文字」按钮，该按钮依赖 X 页面上下文，**在这里不可用**；
③ 播放控制已在查看窗口里（工具条 + 字幕 + 全屏）。
播放/暂停改为**点画面**（暂停时显示播放角标提示可点）。

### 15.6 媒体卡类型标签

三处媒体卡（搜索网格 / 主页瀑布流 / 推文卡媒体行）在**右上角**加视频/GIF 标签——
缩略图是静态封面帧，与图片长得一样，只有时长角标不足以区分（GIF 甚至没有时长）。
**图片不加标签**（是默认预期，加了只是噪声）。
共用 `Views/MediaTypeBadge.swift`，避免三处样式漂移。

### 15.7 推文卡：引用推文移到媒体下方

引用卡本身是一条完整推文（含自己的媒体），夹在正文与媒体之间会把主推文的媒体
挤到下面、视觉割裂。现在顺序为：正文 → 标签 → **媒体** → **引用** → 计数行。

### 15.8 关注清单：选择模式

批量操作（全选/反选/下载全部媒体/加入同步清单）**藏在「选择」按钮之后**：
普通浏览时误点这类按钮会触发整账号下载，风险高，因此默认不显示。
- 非选择模式：点击 = 跳转该用户的搜索页；
- 选择模式：点击 = 勾选，另有「取消」退出；
- 名字改**两行居中**（昵称 / @用户名）：原来挤成 `名字-@用户名` 一行，长昵称被截断。

### 15.9 边栏状态：标签化

边栏位置窄，显示完整文案（如"429 限流，熔断倒计时 37 秒"）会被截断。
现在只显示**三档简称**，详细原因 + 实时倒计时进**悬停提示**：

| 灯色 | 简称 | 含义 |
|---|---|---|
| 绿 | 正常 | 最近请求正常 |
| 黄 | 异常 | 超时 / 离线 / 登录失效 / 服务端 5xx |
| 红 | 限流 | X 明确返回 429（最需要留意——它会暂停后续工作） |

简称本身不变，因此**不再需要每秒重绘文本**；但**状态到期复位仍保留**
（`expiryWatcher` 按截止时间等一次，否则灯会一直红着）。

### 15.10 主动检测（新增设置项）

**设置 → 状态检测**：开关（**默认开**）+ 间隔（**默认 30 秒，最低 5 秒**）。

- **开启**：按间隔主动探一次连通性，状态更快反映现实（断网后不必等下次操作）；
- **关闭**：只在真实操作遇阻时被动更新（**不发额外请求**，更省配额，但更新滞后）；
- 代价说明写进了信息按钮：主动检测**会消耗 X 请求配额**；
- 间隔下限 5 秒的原因：更短会被 X 视为异常流量，反而加剧限流；
- 主动探测**不复位限流态**（那是用户点「重试」的语义），
  只清 `offline`/`timedOut`。

### 15.11 设置区排序

按**使用频率**而非代码模块顺序重排：主页/下载/引擎/外观在前，
状态检测/缓存/同步居中，隐私/电源/数据清理/日志沉底。

### 15.12 选择模式的进出动画

进入与退出都走 `withAnimation(.spring)`：
操作条 `transition(.move(edge: .bottom).combined(with: .opacity))`。
此前"下载所选"与"撤销"是**无动画赋值**，条子会突然消失（用户反馈）。

### 15.13 下载提示框显示开关

**设置 → 下载 → 显示下载提示框**（默认开）。
关闭后仍在「下载管理」看进度，只是不在主界面浮出、避免遮挡内容。

