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
