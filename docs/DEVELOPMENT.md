# XSpiderMac 开发者手册

面向在本仓库工作的开发者 / agent。**按模块与主题组织**，不按改动时间——
时间线的历史留在 `git log`，这里只留结论。

上游源码 vendor 在 `src/`（React + zustand）与 `src-tauri/`（Rust），
**只作行为参照，不参与构建**。文中引用函数名而非行号（行号会漂移）。

---

# 第 0 部分 · 速览

## 0.1 项目是什么

[MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)（Tauri + React，Windows 优先，
**已停止维护**）到 macOS / SwiftUI 的移植。原生 App，内置 aria2Next 下载引擎，
用于浏览与批量下载 X（Twitter）用户的媒体。

因为上游已停维护，`src/` 是本仓库里**唯一**一份可对照的行为参照——这也是它被保留的原因。

## 0.2 五分钟跑起来

```bash
# project.yml 变更后重新生成工程（需要 brew install xcodegen）
cd XSpiderMac && xcodegen generate

# 构建 + 启动 Debug（arm64）
script/build_and_run.sh

# 单元测试
cd XSpiderMac && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
  -destination 'platform=macOS,arch=arm64' test

# 打包 Release dmg
script/package_dmg.sh
```

最低系统 **macOS 15.0**。改动时不要降低，也**不要为版本差异写降级分支**。

## 0.3 排障第一步：先确认跑的是哪个构建

遇到"改动没生效"，**先核对可执行文件路径**：启动日志会打印
`应用启动 … executablePath=…`。

曾经的真实教训：Xcode 在跑 `~/Library/Developer/Xcode/DerivedData/` 的旧产物，
而改动产物在 `XSpiderMac/build/DerivedData`，于是"修复无效"被误判了很久。
`script/build_and_run.sh` 现在会先 `pkill` 旧实例。


## 0.4 代码地图

| 层 | 目录 | 说明 |
|---|---|---|
| UI | `Views/` | SwiftUI 视图。只放纯 UI 态（`@State`） |
| 状态 | `Stores/` | `@Observable @MainActor`，单例 `*.shared`。**业务状态一律在这** |
| 网络/服务 | `Services/` | X API、HTTP 客户端、下载引擎、RPC |
| 支撑 | `Support/` | 缓存、日志、本地化、导航、兼容层等无 UI 依赖的工具 |
| 模型 | `Models/` | `Codable` 数据结构与设置 |

关键文件（其余见目录内注释）：

| 文件 | 职责 |
|---|---|
| `Services/TwitterAPI.swift` | 全部 X GraphQL 调用与 JSON 解析（上游 `src/twitter/api.ts`） |
| `Services/NetworkClient.swift` | HTTP 重试/退避/代理/取消语义 |
| `Services/RequestGate.swift` | 令牌桶 + 同端点串行 + 429 熔断 |
| `Services/Aria2Engine.swift` / `Aria2RPCClient.swift` | 内置下载引擎与常驻 RPC |
| `Stores/HomepageStore.swift` | 搜索用户 → 媒体/推文网格（上游 `src/stores/homepage.ts`） |
| `Stores/CreationTaskStore.swift` | 爬虫：翻页创建下载任务（上游 `src/stores/download.ts`） |
| `Stores/DownloadStore.swift` | 下载队列、跳过判定、引擎调度 |
| `Support/ImageCache.swift` | 图片磁盘 + 内存双缓存（降采样解码） |


# 第 1 部分 · 架构

## 1.1 状态归属：为什么必须放 Store

**规则**：业务状态放 `@Observable` Store，视图 `@State` 只放纯 UI 态。

原因不只是风格——`ContentView` 用 `.id(selection)` 驱动切页动画，会**销毁并重建整个视图**。
凡是放在 `@State` 的业务状态都会归零。踩过的实例：

- 搜索关键词曾放 `@State` → 切页回来输入框空了；
- 瀑布流"已渲染条数"曾放 `@State` → 切页回来从 40 条重新开始，
  而滚动锚点指向第 200 条，恢复必然失败。

`@Observable` 只追踪**存储属性**。用 `UserDefaults` 计算属性当"存储"会导致
视图追踪不到变化（分段控制器切换要等下次数据到达才刷新）。持久化写在 `didSet` 里。

## 1.2 并发模型

- Store 与涉及 UI 状态的服务标 `@MainActor`；
- `TwitterAPI` 是 `actor`（串行化 cookie / token / 缓存）；
- 重活（解码、磁盘、下载）在 `Task.detached` 或 `nonisolated` 函数里，不占主线程；
- Swift 6 严格并发下的三类常见修法：
  1. **闭包是 `@Sendable` 但要写 `@State`** → 状态收进 `@MainActor @Observable` 类，
     闭包里用 `MainActor.assumeIsolated`（回调已在主队列时）；
  2. **系统框架类型未标 `Sendable`**（如 `TranslationSession`）→ `@preconcurrency import`，
     并把调用留在视图闭包内，不要把 session 传进 actor；
  3. **闭包捕获了整个 View 上下文** → 先把要用的值取成**纯局部常量**再进闭包。

## 1.3 端到端数据流

```
搜索用户
  HomeView.submitSearch
    → HomepageStore.loadUser → TwitterAPI.getUser(UserByScreenName)
    → HomepageStore.loadPostList → fetchPage
         ├─（有日期范围 + 开关开）→ TwitterAPI.searchTimeline
         └─（否则）→ getUserMedias / getUserTweets（首页省略 cursor）
    → postList + postListCursor

滚动到底
  BottomSentinel 上报坐标 → HomepageStore.triggerFill → runFillLoop
    → 视口未填满则 loadMorePostList（400ms 页间节流）

下载
  单张 / 选择下载 → CreationTaskStore.runCreationTask（爬虫逐页）
    → DownloadStore.createDownloadTask（含跳过判定）→ 引擎
```


# 第 2 部分 · X API 层（项目最脆弱的部分）

## 2.1 为什么必须逐字对齐上游

X 的 GraphQL 端点对 `queryId` / `features` / `variables` 的格式极其敏感，
`features` 里少一个键就可能 400。**改动请求前，先读上游对应函数逐字对照。**

## 2.2 端点与上游对应

| 用途 | 端点 | 上游参照 |
|---|---|---|
| 用户信息 | `UserByScreenName` | `src/twitter/api.ts getUser` |
| 媒体时间线 | `UserMedia` | `getUserMedias` |
| 推文时间线 | `UserTweets` | `getUserTweets` |
| 推文详情 + 会话 | `TweetDetail` | （上游无，mac 版新增） |
| 关注列表 | `Following` | `getFollowing` |
| 搜索（时间范围） | `SearchTimeline` | （上游无，mac 版新增） |

## 2.3 分页语义（改分页前必读）

1. **首页必须省略 `cursor` 键**，不能传 `null`。
   上游 `JSON.stringify` 会丢弃 `undefined`；写死 `null` 会导致每页都请求第一页
   ——这是"无限加载"与"爬虫重复检索同一页"的总根源。
2. **空页即到底**：`getUserMedias` 解析出 0 条 → 返回 `cursor: nil`（上游同款信号）。
   注意判据是**服务端原始条数**，不是客户端筛选后的条数。
3. **游标不推进即判到底**：X 偶发回吐与上一页相同的 cursor。上游会原地空转刷爆配额，
   本项目在两处（展示路径与爬虫）都加了检测后退出。**不设任何页数上限**。
4. **补拉节奏**：复刻上游 `InfiniteScroll.tsx`——内容底部离视口下沿不足一屏才补拉，
   **视口填满即停**，剩余靠滚动逐页触发。无停止条件的连发循环会触发 429 风暴。

## 2.4 响应解析的坑

- **focal 推文必须按 ID 精确取**，不能走"带媒体过滤"的解析：
  无媒体的推文会被过滤掉，退化分支返回"第一条有媒体的推文"——
  那往往是评论区的广告或带图评论，表现为**"详情弹出的是别人的推文"**。
- **引用推文在 `result.quoted_status_result.result`**，是 `result` 的**直接子键**，
  **不是** `result.legacy.quoted_status_result`。后者是常见误写，会让引用卡永远空白。
- **转推有两种包裹键**：`retweeted_status_result.result` 与 `.tweet`。
  只认一种会把另一种当普通推文放行，导致转推混入、媒体重复下载。
- **用户字段有新老两种结构**：老的在 `legacy.screen_name`，
  新的在 `core.core.screen_name`（`legacy` 可能为空字典）。只读一种会拿到空作者。
- **推广内容（广告）** 判据是 `itemContent.promotedMetadata` 非空。
  三个解析入口（UserMedia / UserTweets / TweetDetail）都要过滤，漏一个就在对应界面露出广告。

## 2.5 搜索端点（SearchTimeline）

用 X 的搜索接口按时间范围浏览，**时间由服务端过滤**，因此没有空窗期问题，
且一页返回的条数远多于时间线（实测媒体 40+ 条/页 vs 时间线 10 条/页）。

三个必须记住的点：

1. **必须 POST + JSON body**。GET 一律 404，POST 表单编码 400。
   ⚠️ **这个 404 与 queryId 无关**——实测新旧两个 queryId 用 POST **都返回 200**，
   只有乱写的才 404。曾用 GET 测试并误判成"queryId 失效"，白做了自愈。
2. **queryId 可自愈**：404 时抓搜索页 HTML → `main.<hash>.js` → 正则提取 →
   重试一次。抓 bundle 走 CDN，匿名且不消耗 X 配额。
3. **提取正则必须锚定 `operationName:"SearchTimeline"`**，因为 bundle 里还有
   `BookmarkSearchTimeline` / `ListSearchTimeline` 等含同名字串的操作，且**排在前面**。

**日期边界**：`DatePicker` 给的 `end` 是**当天零点**，比较必须用 `inclusiveEnd`
（否则「至」那天被整天排除）；拼给 X 的日期串用**本地时区**格式化；
`until:` 取**次日**（X 语义排他），不能再叠加 `inclusiveEnd` 的 +1 天。

## 2.6 限流治理

分三层，**X API 与媒体 CDN 分开治理**（不同域、不同配额）：

| 层 | 做法 |
|---|---|
| 请求闸门 | 令牌桶 + 同端点串行（`RequestGate`） |
| 429 熔断 | 记截止时间，期间挂起新工作；到期自动恢复 |
| 状态采集 | **被动**：由真实请求遇阻推导；只有点「重试」或开启主动检测才主动探测 |

**取消语义**是这里的关键：被取消的请求必须抛 `CancellationError` 且**不重试**。
曾把 `URLError.cancelled` 当可重试错误，加上 `try? await Task.sleep` 在任务已取消时
立即返回不睡眠，导致**同一毫秒内 5400 行取消重试日志**——既是卡上限，也是被限流的主因。


# 第 3 部分 · 下载与同步

## 3.1 两条下载路径

| | 单张 / 选择下载 | 爬虫（创建任务） |
|---|---|---|
| 媒体列表来源 | 前端已加载的 `flatMediaList` | **重新爬服务端**逐页翻到底 |
| 网络开销 | 零请求（已在内存） | 每页一次 GraphQL |
| 覆盖范围 | 仅已加载部分 | 该账号全部 |

**两条路径最终都走 `DownloadStore.createDownloadTask`**，因此
"跳过已下载"的判定完全一致——这是有意设计，避免两套语义。

## 3.2 「全选」为什么用排除法

**全选必须表示"全部"**，而"全部"里的未加载部分在前端列举不出来。
因此选择集有两种模式（`Models/MediaSelection.swift`）：

- `.include`：集合 = 要下载的；
- `.exclude`：集合 = **不要**下载的，其余全要（"全选"态）。

反选恰好是"换模式而集合不变"（补集），所以它是对合的（连按两次回到原状）。

爬虫据此跳过 `excludedKeys`；`.include` 态下收齐勾选项就**提前收工**——
这是"选择下载"相对旧「下载全部」的实质好处：只为自己要的东西付费翻页。

## 3.3 下载判定依据（改这块前必读）

设置里可选的两种依据，**语义有意不同**：

- **按文件名**：解析模板后在扩展名前**强制追加资源索引**，再查文件是否存在。
  索引让文件名本身成为可靠判据（即使模板不含唯一变量，同推文多张媒体也不互相覆盖）。
  代价：改名或移动文件后会被视为未下载。
- **按下载记录文件**：在保存路径维护 `.downloaded.json`，**只查记录、不回查文件**。
  这正是它存在的意义：改文件名模板、重命名、移动文件、整目录搬家，记录都依然有效。

⚠️ **不要给记录模式加"记录 ↔ 文件"双向校验**——那会把"用户改过文件名"误判成
"没下载过"而重复下载，恰好抵消它唯一优于文件名模式的地方。

## 3.4 aria2Next 与标准 aria2 的差异

| 项 | 说明 |
|---|---|
| `--split` / `--max-connection-per-server` | **已废弃**，改用 `stream-max-connections` |
| `--min-split-size` | 完全不支持，不要传 |
| `.aria2` 控制文件 | **不再生成**；续传状态在 `--state-dir/stream/state.db`（SQLite） |
| 进程模型 | 常驻 RPC 进程（`--conf-path=/dev/null` + 随机 `--rpc-secret`） |

⚠️ **不要写"检查 `.aria2` 文件"的续传判断**——它永远不存在，会导致每次续传都从头下载。

## 3.5 同步

`SyncStore` 按关注清单批量补齐缺失媒体。记录文件（`.synced.json`）只检索上次之后的
时间线，因此二次同步快得多。同步判定与下载判定**独立**，不要混用。


# 第 4 部分 · UI 实现要点

## 4.1 详情浮层与返回导航

详情是**全窗浮层**（挂在 `NavigationSplitView` 之上），不是 sheet：
这样点击边栏或任何非卡区都会命中浮层进而关闭。

**返回**（`Support/NavigationHistory.swift`）不是关闭：
详情里点引用推文 / 点头像会**记入历史**，返回逐层回退（先回上一条推文，再回主页）。
- 主页搜索态用**快照**还原（零请求）；重新 `loadUser` 会再打两个请求且丢已翻的页；
- 关闭浮层要**截断**本次会话的历史；而「点头像去搜用户」不能截断，否则丢掉刚压入的记录。

**两个必须注意的机制**：
1. 浮层内换推文时 `MediaDetailView` 必须按推文 ID 重建（`.id(post.id)`），
   否则 SwiftUI 复用视图实例 → `@State`（评论/点赞/媒体索引）串味、`.task` 不重跑；
2. **一个窗口只能有一个 `.escape` 快捷键**。注册两个时只有一个生效，
   语义会随注册顺序漂移（表现为"ESC 有时返回、有时直接关"）。

## 4.2 媒体查看窗口

用**独立 `NSWindow`** 而非 sheet：看大图时通常想同时看到背后的列表；
且详情卡本身已是全窗浮层，再叠 sheet 会成"层中层"。

**切换范围必须区分**（`Origin`）：详情页切本推文的媒体，瀑布流切整个瀑布流，
搜索网格切该网格，评论切**该条评论自己的媒体**。

进度不可拖动（**只读展示**）：拖动需要水平手势与点击，
与「双指左右滑切换」「←/→ 切换」冲突。

## 4.3 三处媒体卡的统一

`Views/MediaCardActions.swift`（下载/已查看按钮）与 `Views/MediaTypeBadge.swift`
（视频/GIF 角标）被搜索网格、瀑布流、评论缩略图**共用**。

理由：需求是"三处都要按已下载状态切换按钮"，各写一份必然漂移——
**瀑布流曾经因此完全没有下载按钮**。同理，评论缩略图的按钮挂在**每一张**上，
而不是整行共用一组（否则多图时不知道在下载哪一张）。

## 4.4 缩略图管线

`?name=small` 实际是 **680px 宽**（不是注释里曾写的 120px）。
必须离主线程、按目标尺寸降采样解码（`CGImageSourceCreateThumbnailAtIndex` +
`kCGImageSourceShouldCacheImmediately`），并做磁盘 + 内存双缓存。
否则网格滑动卡顿、滚回重下重解。

## 4.5 瀑布流

`WaterfallLayout` 是 `Layout`（**非 lazy**，会测量全部子视图），所以：
- 必须**分批渲染**（只渲染前 N 条，滚到底再追加），否则切换形态要等很久；
- 不能给每个格子挂 `GeometryReader` 做锚点（上百个 reader 持续重算代价过高），
  改为**稀疏锚点**（每 20 条一个）。

**热门排序要按页冻结**：热门 = 按赞数降序，而赞数是翻页时才补进来的；
每次访问都重排全量会让新页的高赞推文插到前面 → 已加载的媒体跳位闪烁。
策略是"首屏排序 + 翻页只排页内并整页追加"，用户主动切排序才整体重排。

## 4.6 液态玻璃

`Support/GlassCompat.swift` 封装：支持的系统上走系统 glass，否则退化为
常规材质卡片。**低版本不是"降级分支"而是同一个 API 的正常回退**——
`AGENTS.md` 说的"不写降级分支"针对的是"为版本差异隐藏功能"，不是这种材质回退。

## 4.7 AppKit 交互的三个陷阱

1. **`.help` 是 AppKit 工具提示**，由窗口级 tracking area 驱动，
   **不受 SwiftUI 的 zIndex / 浮层遮挡影响**。所以：
   - 挂在窄文本上几乎无法触发（鼠标要精确停在字上）→ 命中区要覆盖整行；
   - 浮层打开时底层卡片仍会弹提示 → 只能在源头不挂这个 modifier，遮罩层无效。
2. **别在 AppKit 控件上盖透明手势层**：`Color.clear { onTapGesture }` 会吃掉下层
   `AVPlayerView` 控制条的全部点击（"播放按钮点不动"的根因）。手势直接挂在控件上。
3. **视频控件全放底栏**（`controlsStyle` 视需要选择）：`.floating` 会浮在画面上遮挡内容；
   另有 `allowsVideoFrameAnalysis` 控制 Live Text（那个"提取文字"按钮）——它在原生
   播放器里没有可用结果，应关闭。


# 第 5 部分 · 踩过的坑（按主题）

> 每条格式：**现象 → 根因 → 解法**。写"如何避免再犯"而不是故事。

## 5.1 分页与限流

| 现象 | 根因 | 解法 |
|---|---|---|
| 列表停在约 20 帖 / 27 媒体，且随用户变化 | 视图侧 `.task(id:)` 的 id 随翻页变化 → 自我取消，while 只推进一页 | 填充循环由 store 持有（`fillTask`），视图只调 `triggerFill()` |
| 同一毫秒 5400 行取消重试 | 取消被当可重试错误 + `try? await Task.sleep` 在取消时立即返回 | 抛出 `CancellationError` 不重试；取消感知睡眠 |
| 每页都请求第一页 | `variables.cursor` 硬编码 `null`（应为省略键） | 首页省略 cursor 键 |
| 爬虫反复检索同一页 | `continue` 前没推进 cursor | cursor 推进紧跟 fetch，早于一切过滤 |
| 429 风暴 | 无停止条件的连发循环 | 复刻上游"视口填满即停" + 页间节流 + 令牌桶 |
| 翻页偶发卡死 | X 回吐相同 cursor，原地空转 | 游标未推进即判到底 |

## 5.2 时间范围

| 现象 | 根因 | 解法 |
|---|---|---|
| 点「确定」没反应 | `dateRange` 只有爬虫读，浏览路径没读 | 展示路径加客户端筛选（与爬虫同语义） |
| 账号有空窗期就加载不出内容 | 用"连续空页计数"判到底，而空窗期只是时间轴的空隙 | 改判据为**时间轴推进**（`oldestSeenAt < since`） |
| 某页全被筛掉后列表提前结束 | 同上 | 判定"到底"只看**服务端原始条数** |
| 「至」那天没有内容 | `DatePicker` 的 `end` 是当天零点 | 比较用 `inclusiveEnd`（当天 23:59:59） |
| 范围整体偏移一天 | 拼给 X 的日期串用了 UTC 格式化 | 用**本地时区** |

## 5.3 评论与引用

| 现象 | 根因 | 解法 |
|---|---|---|
| 详情弹出的是别人的推文 | focal 走了带媒体过滤的解析，无媒体 focal 被丢弃后退化到评论区 | focal 按 ID 精确取 |
| 引用卡永远空白 | 引用路径写成了 `legacy.quoted_status_result` | 真实路径是 `result.quoted_status_result.result` |
| 评论区混进广告 | 未过滤 `promotedMetadata` | 三个解析入口都过滤 |
| 评论的评论只显示贴主的 | **X 服务端行为**（实测：以评论为 focal 也只返回贴主那条，且无"更多回复"游标） | 不改——按服务端给的展示即正确 |

## 5.4 UI 层级与手势

| 现象 | 根因 | 解法 |
|---|---|---|
| 搜索框焦点环浮在详情浮层上 | 原生焦点环由 AppKit 单独绘制，SwiftUI 管不到 | `.textFieldStyle(.plain)` + `.focusEffectDisabled()`，浮层出现时让出焦点 |
| 输入框点击时闪色 | `roundedBorder` 在聚焦/失焦时切换背景色 | 同上 |
| 详情浮层下仍触发悬停提示 | `.help` 是 AppKit tracking area，不认 SwiftUI 层级 | 浮层打开时不挂该 modifier |
| ESC 语义不稳定 | 注册了两个 `.escape` 快捷键 | 一个窗口只留一个 |
| 浮层内换推文后内容串味 | 未按推文 ID 重建视图 | `.id(post.id)` |
| 选择模式条突然消失 | 无动画赋值 | 进出都走 `withAnimation` |

## 5.5 缓存与容量

**"设了 200MB 却显示 209MB，上限没生效"** ——其实一直在清理（日志有 70 次记录），
根因是**单位不一致**：限制用 MiB（×1_048_576），显示用 `ByteCountFormatter.file`
（十进制）。同一个数被写成两种单位。**解法**：统一为十进制（×1_000_000）。

> 教训：涉及"数值 + 单位"的展示，先确认两端口径是否一致，再怀疑逻辑。

## 5.6 构建与分发

- **"修复无效"先确认跑的是哪个构建**（见 §0.3）；
- **未签名分发**：不做签名与公证（无开发者账号），README 里说明三种放行方式
  （右键打开 / `xattr -dr com.apple.quarantine` / 系统设置放行）；
- `.github/workflows/gh-pages.yml` 已随上游官网一起删除——它会把**上游**官网
  （含上游赞助入口）部署到本仓库的 Pages。


# 第 6 部分 · 约定与清单

## 6.1 改代码前自检

1. **要动 X API 请求或分页逻辑** → 先读 `src/twitter/api.ts` 对应函数逐字对齐；
2. **要改解析** → 同时检查两个解析函数（UserMedia 用 `extractPostsFromModuleInstructions`，
   UserTweets/TweetDetail 用 `extractPostsFromTweetEntries`），两者影响面不同、要分别验证；
3. **要加客户端筛选** → 必须同时想好**停止条件**，否则会翻到服务端尽头吃限流；
4. **要动 UI 层级或悬停** → 记住 §4.7 的三个 AppKit 陷阱；
5. **要删/改下载判定** → 先读 §3.3 的取舍说明；
6. **不要写版本降级分支**（支持 15.0+，直接用满足该版本的 API）。

## 6.2 验证清单

| 改动 | 必须实测 |
|---|---|
| 分页 / 爬虫 | ① 媒体量大的用户滑到底，总数持续增长超过 40 条且不重复；② 同用户同条件「下载全部」执行两遍，第二遍应全部 skip |
| 图片管线 | 快速来回滚动不掉帧；滚回顶部不重新闪载 |
| 时间范围 | 取一个已知有长空窗期的账号，设跨越空窗期的范围，确认能持续翻页并显示内容 |
| UI 层级 | 详情浮层打开时，底层卡片的悬停提示不出现 |
| 任何改动 | `xcodebuild test` 全绿（当前 242 项） |

日志观察：`log stream --predicate 'process == "XSpiderMac"'`，
或读 `~/Library/Logs/XSpiderMac/xspider.log`（按天滚动）。

## 6.3 已知限制（不是 bug）

1. **评论的评论只有贴主的** —— X 服务端行为，与网页端一致；
2. **X 的视频一般没有内嵌字幕**，因此不提供字幕选择；
3. **搜索结果可能有极个别遗漏** —— 浏览走搜索接口求快，而**下载**始终由爬虫逐页抓取，
   会把遗漏补上；
4. **未签名** —— 首次打开需手动放行。

## 6.4 已移除的死代码（勿再当作"已实现"）

| 已删 | 原因 |
|---|---|
| 评论发布输入框 | 从未实现（常量绑定打不进字 + 空实现），且全仓库无 `CreateTweet` 端点 |
| `SelectiveDownloadSheet.swift` | 从未被引用（选择模式一直是内联的），留着会让人以为"选择页面"是那个弹窗 |
| 字幕选择 | 那是"视频内嵌字幕轨"，与需求（实时翻译字幕）不是一回事 |
| `homepage/`、`assets/`、`design/`、Tauri/Vite 脚手架 | 上游残留，与移植无关 |
