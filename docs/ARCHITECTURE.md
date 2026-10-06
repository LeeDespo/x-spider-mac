# 架构与外壳纪律

> 本文承载外壳的架构地图、状态与并发模型、映射层职责、外壳↔组件协调契约、
> 下载/同步外壳职责与全部现役 UI 纪律。**改代码前先按 `AGENTS.md` 的路由进对应文档**；
> 组件接入与部署见 `COMPONENTS.md`，测试验收见 `TESTING.md`，发布见 `RELEASING.md`，
> 记录体系规范见根目录 `../MEDIA_RECORDS.md`。

## 0. 定位与基线

XSpiderMac 是 X（Twitter）媒体下载器的 **macOS SwiftUI 外壳**。取数、写操作、下载、
爬取全部在组件 `x-spider-core`（Rust sidecar `xspiderd` + 本地 JSON-RPC）里；
外壳只拥有**契约映射、产品语义、本地存储与 UI**。接口唯一：
`XSpiderComponent.call(_:_:)`（详见 `COMPONENTS.md`）。

- **最低系统 macOS 15.0**：依据是系统 `Translation` 框架（翻译能力，见 §7.7），
  其 API 全部 macOS 15.0+。不要降低基线；新用系统 API 前确认可用版本不低于 15.0。
- **不为版本差异写降级分支**：支持范围就是 15.0+，直接用满足该版本的 API，
  不加"旧系统隐藏按钮/回退旧实现"分支。注意：`Support/GlassCompat.swift` 的材质回退
  **不属于**此类——那是同一个 API 的正常回退（见 §7.6），与"为版本差异隐藏功能"不同。

## 1. 目录地图

| 层 | 目录 | 说明 |
|---|---|---|
| UI | `Views/` | SwiftUI 视图。只放纯 UI 态（`@State`） |
| 状态 | `Stores/` | `@Observable @MainActor`，单例 `*.shared`。**业务状态一律在这** |
| 网络/服务 | `Services/` | 组件客户端（JSON-RPC）、契约映射、记录层、命名与校验。**不含任何 X 请求或下载实现** |
| 支撑 | `Support/` | 缓存、日志、本地化、导航、兼容层等无 UI 依赖的工具 |
| 模型 | `Models/` | `Codable` 数据结构与设置 |

关键文件（其余见目录内注释）：

| 文件 | 职责 |
|---|---|
| `Services/XSpiderComponent.swift` | 组件进程与 JSON-RPC 客户端：查找、启动、握手、调用、崩溃自愈、优雅关停（见 `COMPONENTS.md`） |
| `Services/TwitterAPI.swift` | 契约 method ↔ 应用模型的映射与错误码翻译（actor；不发 X 请求） |
| `Services/XSpiderMapping.swift` / `XSpiderJSON.swift` | 契约 JSON → `TwitterPost` / `TwitterUser` / `TwitterMedia` / `ReplyNode`；受限值类型 `JSONValue` |
| `Services/MediaRecords.swift` | 下载 / 同步记录层（两种形态、缓存、原子写） |
| `Services/MediaJudgement.swift` | 文件名（模板 + 唯一标识）、按文件名判定、断点后缀清单 |
| `Services/RecordsIO.swift` / `FileIntegrity.swift` | 记录导入导出 / 按文件名重建；下载收尾的内容校验 |
| `Services/SystemProxy.swift` | 系统代理探测（组件是独立进程，不继承系统代理，要先解析成 URL 再告诉它） |
| `Support/AccountFolder.swift` | 账号文件夹命名 `昵称-用户名[数字id]`（记录落点，同一 id 永远同一文件夹） |
| `Stores/HomepageStore.swift` | 搜索用户 → 媒体/推文网格 |
| `Stores/CreationTaskStore.swift` | 爬取调度：分块调组件 `crawl.run`；产品语义（勾选/排除/精确日期）留在外壳 |
| `Stores/DownloadStore.swift` | 下载队列、跳过判定、与组件 `dl.*` 对接（进度轮询、收尾、记录、通知） |
| `Stores/SyncStore.swift` | 关注清单批量补齐（窗口语义在记录模式） |
| `Support/ImageCache.swift` | 图片磁盘 + 内存双缓存（降采样解码） |

## 2. 状态归属与并发

### 2.1 状态必须放 Store

**规则**：业务状态放 `@Observable` Store（`Stores/`，单例 `*.shared`），视图 `@State`
只放纯 UI 态。会随视图重建丢失的业务数据放 `@State` 属 bug。

原因不只是风格——`ContentView` 用 `.id(selection)` 驱动切页动画，会**销毁并重建整个视图**，
凡是放在 `@State` 的业务状态都会归零。踩过的实例：

- 搜索关键词曾放 `@State` → 切页回来输入框空了；
- 瀑布流"已渲染条数"曾放 `@State` → 切页回来从 40 条重新开始，
  而滚动锚点指向第 200 条，恢复必然失败。

`@Observable` 只追踪**存储属性**。用 `UserDefaults` 计算属性当"存储"会导致视图追踪不到变化
（分段控制器切换要等下次数据到达才刷新）。持久化写在 `didSet` 里。

### 2.2 并发模型

- Store 与涉及 UI 状态的服务标 `@MainActor`；
- `TwitterAPI` 是 `actor`（串行化 cookie / token / 缓存）；
- 重活（解码、磁盘、下载）在 `Task.detached` 或 `nonisolated` 函数里，不占主线程；
- Swift 6 严格并发下的三类常见修法：
  1. **闭包是 `@Sendable` 但要写 `@State`** → 状态收进 `@MainActor @Observable` 类，
     闭包里用 `MainActor.assumeIsolated`（回调已在主队列时）；
  2. **系统框架类型未标 `Sendable`**（如 `TranslationSession`）→ `@preconcurrency import`，
     并把调用留在视图闭包内，不要把 session 传进 actor；
  3. **闭包捕获了整个 View 上下文** → 先把要用的值取成**纯局部常量**再进闭包。

## 3. 端到端数据流

**所有取数都经组件**（`call(method, json)` → 映射层 → 应用模型）：

```
搜索用户
  HomeView.submitSearch
    → HomepageStore.loadUser → TwitterAPI.getUser
        → XSpiderComponent.call("fetch.get_user") → XSpiderMapping.user
    → HomepageStore.loadPostList → fetchPage
         ├─（有日期范围 + 开关开）→ TwitterAPI.searchTimeline → "fetch.search_timeline"
         └─（否则）→ getUserMedias / getUserTweets
                      → "fetch.user_medias" / "fetch.user_tweets"（首页省略 cursor 键）
    → XSpiderMapping.postPage → postList + postListCursor

滚动到底
  BottomSentinel 上报坐标 → HomepageStore.triggerFill → runFillLoop
    → 视口未填满则 loadMorePostList（页间节流在 store）

下载
  单张 / 选择下载 / 爬取 → CreationTaskStore.runCreationTask
    → TwitterAPI.crawlPage("crawl.run")（分块驱动；组件给 done_reason / next_cursor）
    → DownloadStore.createDownloadTask（外壳算目录/文件名 + 跳过判定）
    → XSpiderComponent.call("dl.enqueue") → 组件（内置引擎 / aria2Next）
    → DownloadStore 轮询 "dl.events" / "dl.list" → FileIntegrity 收尾校验 → 写记录

组件配置
  cookie / 代理 / 限流参数变更 → AppStore.cookieString.didSet 或 SettingsStore.save
    → TwitterAPI.configure → auth.set_cookie / net.set_proxy / net.set_limits
```

### 3.1 视口填充节奏（补拉到填满即停）

无限滚动**只补拉到视口填满（约两屏）**，剩余靠用户滚动逐页触发——这是产品节奏，
照此复刻。无停止条件的连发循环历史上触发过 429 限流风暴（限流治理本体在组件，
叙事见 `history/x-endpoint-pitfalls.md`）。填充循环**由 store 持有**（`fillTask`），
视图只调 `triggerFill()`——视图侧 `.task(id:)` 的 id 随翻页变化会自我取消，
曾表现为"列表停在约 20 帖 / 27 媒体，且随用户变化"。

### 3.2 搜索页数据源时序

搜索页数据源**按用户记忆、默认推文**（`HomepageStore.rememberedSource(for:)`）。
应用时机**必须在 `loadPostList` 之前**——先用默认源拉一页再切源重拉会白白多一次请求
（项目一直在对抗 429）。

## 4. 映射层职责

- 映射层（`XSpiderMapping.swift` / `XSpiderJSON.swift` / `TwitterAPI.swift`）**只理解契约形状**：
  契约 JSON 进、应用模型出，不掺取数逻辑（端点行为归组件，见 `COMPONENTS.md`）。
- **评论树不压平、父指针不丢**：契约给了 `parent_id` / `in_reply_to_screen_name`，
  层级构建在 `XSpiderMapping.swift` 的 `replyNodes`（按父链算深度）；
  孤儿（父不在本页）**不能丢**，要标 `isPartialParent`。
  「回复 @xxx」必须用**被回复者**，不是本条作者。
- **外壳拿到的是已经清过广告的数据，勿重复过滤**（广告过滤在组件）。
- **遇到"某功能好像不存在"，先分清解析缺失还是渲染缺失**（方法论）：
  历史上评论媒体"不存在"其实是渲染层没画（数据早已映射进 `post.medias`）。

## 5. 外壳↔组件协调契约

### 5.1 日期边界（两段式，是有意的分工）

- `DatePicker` 的 `end` 是**当天零点**，本地比较要用 `DateRange.inclusiveEnd`
  （`Models/DownloadFilter.swift`），否则「至」当天被整天排除。
- 契约 `fetch.search_timeline` 的 `since` / `until` 按**本地日历**理解且**含当天**，
  组件内部按排他语义 **+1 天**——**外壳不要再自己加一天**。
- 爬取侧（`crawl.run`）按 **UTC 天**粗筛（省请求），所以
  `CreationTaskStore.crawlStrategy` **故意**把 `since` / `until` 各放宽一天（±1 天；
  时区偏移最大 ±14h < 24h，±1 天足够覆盖），精确边界由 `CreationTaskStore.decide`
  用本地日历再判。这不是 bug。

### 5.2 展示筛选、去重与停止条件

- **展示筛选（日期/类型）与爬虫必须同语义**：无 `createdAt` 放行、
  纯文字推文不受类型筛选影响。
- **去重必须先于筛选**（先 `seenPostIds` 再过滤）。判定"到底"只看**服务端原始条数**，
  取筛选后的条数不推进。
- **同页去重**：转推展平后每条的 `post.id` 都等于被转发的原推文 id，
  同一页会出现多个相同 id，而 `ForEach` 要求 id 唯一——重复时只渲染第一个，
  其余留空白卡片（搜索页连转同一条推文时尤其常见）。`HomepageStore.loadPostList`
  已改为**先过滤再记录**（页内去重）；`loadMorePostList` 的
  `seenPostIds.insert().inserted` 天然覆盖同页与跨页。任何进 `ForEach` 的列表都要确认
  id 唯一，"展平转推"这类操作是重复 id 的高危来源。
- **加客户端筛选就要加停止条件**，且终止判据必须是**时间轴推进**
  （`oldestSeenAt < since`，与爬虫 `now > since` 同义），**不要用"连续空页计数"**——
  账号停更一两个月的空窗期会被误判成"没有内容"（用户实测反馈）。

### 5.3 传参与错误判断

- `fetch.search_timeline` 外壳只传 `screen_name` / `since` / `until` / `media_only` /
  `count` / `cursor`（cursor 可选；**首页必须省略 cursor 键**，映射层保证）。
- 判断一律用结构化 `code` / `reason` / `status`，**不要匹配 `message` 文案**；
  错误码映射与重试语义见 `COMPONENTS.md`。

## 6. 下载与同步（外壳职责）

引擎、断点续传、并发调度与传输层完整性校验都在组件（`dl.*`，见 `COMPONENTS.md`）。
外壳负责：**算目录与文件名**（`DownloadStore.targetDir` + `MediaJudgement` +
`AccountFolder`）、**跳过判定**、把任务交给组件、轮询进度、**收尾再验一遍内容**
（`FileIntegrity`）、写记录与通知。

- **重复入队是幂等的**：`dl.enqueue` 的 `job_id` 用任务 `gid`（跨重启稳定）。
  但"继续 / 重试"**不是**"再入队一次"——对已在组件里的任务要调 `dl.resume`
  （对 `paused` 与 `error` 都有效，只拒绝 `complete`）。只 re-enqueue 的话组件回
  `already_known`、任务原地不动，症状是"界面显示下载中、进度停在断点处"。
- **完整性要验两遍**：组件回答"落盘字节数与服务端声明一致"，而 CDN 出错时可能返回
  HTML 错误页、字节数还可能是对的——所以"这是不是一张真图 / 真 mp4"留在外壳侧再判
  （`FileIntegrity`）。`expect_size` 已知就传给组件，未知由组件自己探。
- **断点 / 临时文件只用于跳过**：外壳保留一份后缀清单
  （`MediaJudgement.enginePartialSuffixes`），下载判定与按文件名重建要跳过它们
  （名字里也带媒体 id，解析进去会把没下完的媒体记成"已下载"）。
- 判定三选一（文件名 / 记录·分布式 / 记录·集中式）的取舍与完整规范见
  `../MEDIA_RECORDS.md`；一条底线：**记录模式只信记录、不回查文件**，
  **不要给记录模式加"记录 ↔ 文件"双向校验**——那会把"用户改过文件名"误判成
  "没下载过"而重复下载，恰好抵消记录模式的价值。
- 同步：`SyncStore` 按关注清单批量补齐，记录模式下走**窗口语义**
  （`../MEDIA_RECORDS.md` §6.3）；单用户总闸 150s（`AsyncTimeout.withTimeout`）。

### 6.1 选择模型：「全选」用排除法

**全选必须表示"全部"**，而"全部"里的未加载部分在前端列举不出来。
因此选择集有两种模式（`Models/MediaSelection.swift`）：

- `.include`：集合 = 要下载的；
- `.exclude`：集合 = **不要**下载的，其余全要（"全选"态）。

反选恰好是"换模式而集合不变"（补集），所以它是对合的（连按两次回到原状）。
爬虫据此跳过 `excludedKeys`；`.include` 态下收齐勾选项就**提前收工**——
这是"选择下载"相对「下载全部」的实质好处：只为自己要的东西付费翻页。
**不要**退化成"把已加载的灌进一个 Set"——那样用户不知道自己选了什么。

## 7. UI 纪律

### 7.1 详情浮层与返回导航

详情是**全窗浮层**（挂在 `NavigationSplitView` 之上），不是 sheet：
点击边栏或任何非卡区都会命中浮层进而关闭。

返回（`Support/NavigationHistory.swift`）不是关闭：详情里点引用推文 / 点头像会
**记入历史**，返回逐层回退（先回上一条推文，再回主页）。多入口（引用推文 / 头像 /
搜索）各自记账必然互相打架，**返回导航统一走 `NavigationHistory`**，
不要在视图里各自维护"上一步"。

- 主页搜索态用**快照**还原（零请求）；重新 `loadUser` 会再打两个请求且丢已翻的页；
- 关闭浮层要**截断**本次会话的历史；而「点头像去搜用户」不能截断，
  否则丢掉刚压入的记录。

三个必须注意的机制：

1. **浮层内换推文必须 `.id(post.id)`**：不加的话 SwiftUI 复用视图实例 →
   `@State`（评论/点赞/媒体索引）串味、`.task` 不重跑，
   表现为"跳到引用推文后内容还是上一条的"。
2. **别为回退重复请求**：`.id` 重建会重跑 `.task` → 再请求一次详情。
   回看已看过的推文走 `TweetDetailCache`（TTL 5 分钟，容量 12 条）；
   详情页只调 `getTweetDetailTree` 一个入口（分别取 focal 与回复会把同一请求打两遍）。
3. **一个窗口只能有一个 `.escape` 快捷键**：注册两个时只有一个生效，
   语义随注册顺序漂移（"ESC 有时返回、有时直接关"）。

### 7.2 强调色

强调色用在**按钮背景**上，不是把图标/文字染成强调色。行内文字型小操作仍可用强调色文字。

### 7.3 媒体查看窗口

用**独立 `NSWindow`**（`Support/MediaViewerCenter.swift`）而非 `.sheet`：
看大图时通常想同时看到背后的列表；且详情卡本身已是全窗浮层，再叠 sheet 会成"层中层"。

**切换范围必须区分**（`Session.Origin`）：详情页切本推文的媒体，瀑布流切整个瀑布流，
搜索网格切该网格，评论切**该条评论自己的媒体**。别混用。

进度不可拖动（**只读展示**）：拖动需要水平手势与点击，
与「双指左右滑切换」「←/→ 切换」冲突。

### 7.4 媒体卡三处统一

`Views/MediaCardActions.swift`（下载/已查看按钮）与 `Views/MediaTypeBadge.swift`
（视频/GIF 角标）各自被多处共用，范围不同：**按钮**用于搜索网格、瀑布流、评论缩略图；
**角标**用于搜索网格、瀑布流、时间线推文卡的媒体行——评论缩略图不用角标。

理由：需求是"各处都按已下载状态切换按钮"，各写一份必然漂移——
**瀑布流曾因此完全没有下载按钮**。评论缩略图的按钮挂在**每一张**上，
而不是整行共用一组（否则多图时不知道在下载哪一张）。

### 7.5 缩略图管线

- `?name=small` 实际是 **680px 宽**（不是 120px）。缩略图必须**离主线程、
  按目标尺寸降采样解码**（`CGImageSourceCreateThumbnailAtIndex` +
  `kCGImageSourceShouldCacheImmediately`），并做磁盘 + 内存双缓存（`ImageCache`）。
  否则网格滑动卡顿、滚回重下重解。
- 评论缩略图规格：单张保宽高比、多张 64pt 方格（4 张才放得进 410pt 卡片），
  一律走 `ImageCache` 降采样。
- 解码尺寸参考：网格 600 / 详情 1600 / 查看器 4096 px（见 `../SETTINGS_DEFAULTS.md`
  「不随设置保存的内在默认值」）。

### 7.6 瀑布流与液态玻璃

- `Views/WaterfallLayout.swift` 是 `Layout`（**非 lazy**，会测量全部子视图），所以：
  - 必须**分批渲染**（只渲染前 N 条，滚到底再追加），否则切换形态要等很久；
  - 不能给每个格子挂 `GeometryReader` 做锚点（上百个 reader 持续重算代价过高），
    改为**稀疏锚点**（每 20 条一个）。
- **热门排序要按页冻结**：热门 = 按赞数降序，而赞数是翻页时才补进来的；
  每次访问都重排全量会让新页的高赞推文插到前面 → 已加载的媒体跳位闪烁。
  策略是"首屏排序 + 翻页只排页内并整页追加"，用户主动切排序才整体重排。
- 液态玻璃：`Support/GlassCompat.swift` 封装，支持的系统上走系统 glass，
  否则退化为常规材质卡片。**低版本不是"降级分支"而是同一个 API 的正常回退**——
  "不写降级分支"针对的是"为版本差异隐藏功能"，不是这种材质回退。
- 选择模式条的显隐**进出都走 `withAnimation`**（无动画赋值会表现为"突然消失"）。

### 7.7 翻译与语言包（macOS 15 基线的由来）

**用系统 `Translation` 框架**（本地翻译），不抓 X 的翻译端点——
后者要维护会失效的私有标识，且**消耗 X 配额**。相关 API 全部 macOS 15.0+，
与基线一致，无需版本判断。

- **自动翻译判据 = 白名单**：只翻译设置里明确列出的语言
  （`autoTranslateLanguages`，判据在 `TranslationStore.shouldAutoTranslate`），
  不是"凡非目标语言就翻"。清单为空 = 不自动翻译任何条目（比"全部翻"安全）。
- **语言包会按需自动下载**：会话首次 `translate()` 缺包时系统弹窗下载，
  浏览场景体验差，所以提供语言清单窗口（`Views/TranslationLanguageSheets.swift`）
  可**预先下载**。
- **macOS 15 上 `TranslationSession` 没有公开 init**：只能由 SwiftUI 的
  `translationTask(configuration:)` 交出（公开 init 是 macOS 26+，不能用）。
  所以"主动下载语言包"必须由**视图**做：`Views/TranslationPackDownloader.swift`
  是零尺寸视图，为每种语言新建 configuration 交给 `translationTask`，在闭包里调
  `prepareTranslation()`。注意 `LanguageAvailability.supportedLanguages` 是
  **async** 属性。
- **语言包状态三个要点**：
  1. 与目标语言相同 → `.notNeeded`（"无需语言包"），不要问系统
     （系统对同语言对返回 `unsupported`，用户视角是"不需要"）；
  2. `prepareTranslation()` 返回 ≠ 下载完成——它只表示系统已接受请求。
     请求发出即标记"下载中"，**轮询状态**直到变 `.installed` 才移除
     （曾把它当完成信号，UI 一直显示"可下载"）；
  3. 系统不暴露下载进度（`Translation` 框架无 progress 成员，实测确认）——
     只有"下载中 / 已完成"两态，**不要为此加进度条**。
- **不能用 `Locale.current`（会毁掉目标语言）**：本 app 三语由 `L10n` 自实现
  （不走 bundle，bundle 只声明 `en`），系统把 `Locale.current` 降级成开发语言
  （实测 `en_US`，而 `Locale.preferredLanguages` 才是用户真实语言）。
  用它当翻译目标会导致"设了跟随系统，却把日语翻成英语"。**正确做法**：
  目标语言用 `Settings.systemPreferredLanguage`（读 `Locale.preferredLanguages`）；
  语言**显示名**用 `Settings.displayLocale`，否则"日本語"会显示成 "Japanese"。

### 7.8 AppKit 交互陷阱

1. **`.help` 是 AppKit 工具提示**，由窗口级 tracking area 驱动，
   **不受 SwiftUI 的 zIndex / 浮层遮挡影响**：
   - 挂在窄文本上几乎无法触发（鼠标要精确停在字上）→ 命中区要覆盖整行；
   - 浮层打开时底层卡片仍会弹提示 → 只能在源头不挂这个 modifier，遮罩层无效；
   - **媒体区这类大面积手势区不要挂 `.help`**（几乎一碰就弹、同视图内移动不消失），
     改用按需的悬停态（`onHover`）自绘提示。
2. **别在 AppKit 控件上盖透明手势层**：`Color.clear { onTapGesture }` 会吃掉下层
   `AVPlayerView` 控制条的全部点击（"播放按钮点不动"的根因）。手势直接挂在控件上。
3. **视频控件全放底栏**（`AVPlayerView.controlsStyle = .none`）：`.floating` 会浮在
   画面上遮挡内容。另有 `allowsVideoFrameAnalysis` 控制 Live Text——
   它在原生播放器里没有可用结果，应关闭。
4. **原生焦点环画在 SwiftUI 之上**：搜索框的蓝色焦点环会盖住详情浮层，
   `zIndex` 无效。用 `.textFieldStyle(.plain)` + `.focusEffectDisabled()`，
   并在浮层出现时广播 `.homeResignSearchFocus` 交出焦点
   （`roundedBorder` 在聚焦/失焦时切换背景色导致的"闪色"同理解决）。

## 8. 缓存与容量

- 图片缓存为磁盘 + 内存双缓存（`Support/ImageCache.swift`），解码纪律见 §7.5；
  磁盘上限扫描节流 60 秒至多一次。
- **容量单位统一为十进制 MB**（`× 1_000_000`），与 `ByteCountFormatter.file`
  的显示口径一致。曾用 MiB（`× 1_048_576`）导致"设 200MB 显示 209MB"，
  用户以为上限失效。**适用范围**：用户设置 ↔ UI 显示这条链；
  `ImageCache` 内部 NSCache 预算与下载引擎的阈值换算不属此列。
- **回收语义**：设置项是「超限回收目标（占上限 %）」，默认 60、区间 0–90。
  占用**超过上限**后从最旧开始删，直到降到 `上限 × 这个百分比` 为止
  （上限 1 GB、目标 60%：占用 2 GB → 删到剩 600 MB）。目标只由**上限**决定，
  与当前占用无关。区间上限是 **90 不是 100**：目标必须**严格低于上限**，
  否则清完立刻再超限；`0%` = 超限后全部清空。「缓存上限」可选**无上限**
  （哨兵值 `Settings.unlimitedCacheLimitMB = 0`）：不做容量控制、连全目录扫描都不做；
  用 `0` 而非 `Int.max`，越界判断与乘法都不会溢出。
  设置项改语义时**连存储键一起换**（现为 `cacheReclaimTargetPercent`），
  旧值直接落新默认——语义变了两不相容时，宁可回默认，也不要让旧数值被按新含义解读。
- **教训**：涉及"数值 + 单位"的展示，先确认两端口径是否一致，再怀疑逻辑；
  「比例」类设置项必须把**基数是哪个量**写进名字与提示文案（这里 = 上限，不是已用容量）。

## 9. 开发环境与排障

- `XSpiderMac/project.yml` 是工程唯一真源，改它必须重跑 `xcodegen generate`
  （详见 `AGENTS.md` 质量门；发布流程见 `RELEASING.md`）。
- **"改动没生效"，先核对可执行文件路径**：启动日志会打印
  `应用启动 … executablePath=…`。曾有教训：Xcode 在跑
  `~/Library/Developer/Xcode/DerivedData/` 的旧产物，而改动产物在
  `XSpiderMac/build/DerivedData`，于是"修复无效"被误判了很久。
  `script/build_and_run.sh` 现在会先 `pkill` 旧实例。
