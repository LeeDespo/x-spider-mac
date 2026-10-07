# XSpiderMac 开发者手册

> 本手册只记录 **macOS 应用侧** 的架构、产品逻辑和本地状态。
> X 请求、GraphQL、端点、queryId/features、原始响应解析、限流、爬取与下载引擎均属于
> [x-spider-core](https://github.com/LeeDespo/x-spider-core)，本仓库不重复维护其领域知识。
>
> 组件版本不要写死：运行时以 `system.version` 握手结果和实际使用的 Release 为准。

# 第 0 部分 · 速览

## 0.1 项目是什么

XSpiderMac 是面向 macOS 的原生 SwiftUI X（Twitter）媒体客户端。应用负责 UI、产品语义、本地设置、
缓存以及下载 / 同步记录；X 数据访问与下载能力由 `x-spider-core` 通过稳定契约提供。

项目早期参考过 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)，但当前实现和构建链独立；
该项目仅作为历史来源 / 致谢，不参与当前开发，也不作为 X 行为参考。

## 0.2 五分钟跑起来

**前提**：装了 Xcode 与 [xcodegen](https://github.com/yonaskolb/XcodeGen)
（`brew install xcodegen`）。`XSpiderMac/project.yml` 是工程的**唯一真源**，
`XSpiderMac.xcodeproj`（入库）由它生成——**改了 `project.yml`（加文件、改设置、改 target）
必须重跑 `xcodegen generate`**，否则新文件不进工程。

```bash
# 1) 生成工程（改了 project.yml 后必做）
(cd XSpiderMac && xcodegen generate)

# 2) 构建 + 启动 Debug（arm64）
script/build_and_run.sh

# 3) 单元测试
(cd XSpiderMac && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
  -destination 'platform=macOS,arch=arm64' test)

# 4) 打包 Release dmg
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
| 网络/服务 | `Services/` | 组件客户端（JSON-RPC）、契约映射、记录层、命名与校验。**不含任何 X 请求或下载实现** |
| 支撑 | `Support/` | 缓存、日志、本地化、导航、兼容层等无 UI 依赖的工具 |
| 模型 | `Models/` | `Codable` 数据结构与设置 |

关键文件（其余见目录内注释）：

| 文件 | 职责 |
|---|---|
| `Services/XSpiderComponent.swift` | 组件进程与 JSON-RPC 客户端：查找、启动、握手、调用、崩溃自愈、优雅关停（第 2 部分的核心） |
| `Services/XSpiderAPI.swift` | 应用侧 core 契约客户端：method 调用、错误映射与产品侧缓存；不实现 X 端点 |
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
- `XSpiderAPI` 是 `actor`（串行化 cookie / token / 缓存）；
- 重活（解码、磁盘、下载）在 `Task.detached` 或 `nonisolated` 函数里，不占主线程；
- Swift 6 严格并发下的三类常见修法：
  1. **闭包是 `@Sendable` 但要写 `@State`** → 状态收进 `@MainActor @Observable` 类，
     闭包里用 `MainActor.assumeIsolated`（回调已在主队列时）；
  2. **系统框架类型未标 `Sendable`**（如 `TranslationSession`）→ `@preconcurrency import`，
     并把调用留在视图闭包内，不要把 session 传进 actor；
  3. **闭包捕获了整个 View 上下文** → 先把要用的值取成**纯局部常量**再进闭包。

## 1.3 端到端数据流

**所有取数都经组件**（`call(method, json)` → 映射层 → 应用模型）：

```
搜索用户
  HomeView.submitSearch
    → HomepageStore.loadUser → XSpiderAPI.getUser
        → XSpiderComponent.call("fetch.get_user") → XSpiderMapping.user
    → HomepageStore.loadPostList → fetchPage
         ├─（有日期范围 + 开关开）→ XSpiderAPI.searchTimeline → "fetch.search_timeline"
         └─（否则）→ getUserMedias / getUserTweets
                      → "fetch.user_medias" / "fetch.user_tweets"（首页省略 cursor 键）
    → XSpiderMapping.postPage → postList + postListCursor

滚动到底
  BottomSentinel 上报坐标 → HomepageStore.triggerFill → runFillLoop
    → 视口未填满则 loadMorePostList（页间节流在 store）

下载
  单张 / 选择下载 / 爬取 → CreationTaskStore.runCreationTask
    → XSpiderAPI.crawlPage("crawl.run")（分块驱动；组件给 done_reason / next_cursor）
    → DownloadStore.createDownloadTask（外壳算目录/文件名 + 跳过判定）
    → XSpiderComponent.call("dl.enqueue") → 组件（内置引擎 / aria2Next）
    → DownloadStore 轮询 "dl.events" / "dl.list" → FileIntegrity 收尾校验 → 写记录

组件配置
  cookie / 代理 / 限流参数变更 → AppStore.cookieString.didSet 或 SettingsStore.save
    → XSpiderAPI.configure → auth.set_cookie / net.set_proxy / net.set_limits
```


# 第 2 部分 · 组件边界（`x-spider-core`）

## 2.1 一句话：外壳不再直接打 X

本应用**没有任何一条自己发出的 X 请求**，也没有自己的下载实现。取数、写操作、下载、爬取
全部在组件 `x-spider-core`（Rust sidecar `xspiderd`，本地 JSON-RPC，契约版本以运行时 `system.version` 为准）里。
契约映射与进程对接集中在四个文件：`XSpiderComponent`（进程与 RPC）、`XSpiderAPI`
（契约方法 ↔ 应用模型的映射）、`XSpiderMapping` / `XSpiderJSON`（JSON → 应用模型）；
此外 `DownloadStore` 直调 `dl.enqueue` / `dl.resume` 等下载 method，
`AccountStatusStore` 直调 `net.status` 读限流状态——它们不经过映射层。

**为什么抽出去**：X 数据访问和下载需要统一实现、统一测试，
下载引擎与断点/完整性校验，这些若在两个外壳里各实现一遍必然漂移，而限流治理是这条链上
最容易出事的地方。组件同时被 CLI（第一个真实消费方）与其它平台复用。

> 权威来源：组件仓库 `github.com/LeeDespo/x-spider-core`。**接口细节看它的
> `docs/07-API-REFERENCE.md`**（26 个 method 的入参/出参、数据形状、错误、可直接抄的时序），
> 契约本身看它的 `docs/CONTRACT.md`。

## 2.2 契约：一个入口、版本握手，内务不外泄

- **唯一入口** `xspider_call(method, json) -> json`（sidecar 里是 `POST /` 加
  `X-XSpider-Token` 头）；另有 `system.version` 做握手。**契约主版本不匹配就拒绝启动**，
  不降级成"部分可用"（`XSpiderComponent.supportedContractMajor = "1"`）。
- core 的请求内部细节不属于应用契约；本仓库不实现、不复制，也不为这些细节建立第二套测试。
- 外壳持有的只有受限 JSON 值类型：`XSpiderJSON.JSONValue`（`Any` 不是 `Sendable`，
  跨 actor 会被 Swift 6 拒）。参数与结果就是契约里的 JSON，没有中间类型。

## 2.3 哪些在组件里，外壳只做什么

| 能力 | 组件（契约 method） | 外壳 |
|---|---|---|
| 用户 / 时间线 / 详情 / 搜索 / 关注 | `fetch.*` | `XSpiderAPI` + `XSpiderMapping` 映射成 `TwitterPost` 等 |
| 写操作（赞 / 转推 / 书签 / 关注） | `fetch.mutate` | 映射 + 关注态缓存失效 |
| 登录校验 / 当前账号 | `auth.whoami` / `auth.set_cookie` | 登录流程调用；凭据**只进不出** |
| 限流 / 代理 / 探测 | `net.set_limits` / `net.set_proxy` / `net.status` / `net.probe_size` | 把设置推下去、读状态展示 |
| 下载 | `dl.enqueue` / `pause` / `resume` / `cancel` / `list` / `events` | 算目录与文件名、跳过判定、进度展示、收尾校验、写记录 |
| 爬取 | `crawl.run` | 分块驱动；产品语义（勾选/排除/精确日期/去重） |

**外壳保留的只有三类**：① 契约 JSON ↔ 应用模型的映射；② 产品语义（怎么命名、放哪、
勾了哪些、判断依据）；③ UI。**凡是"数据怎么取、请求长什么样"的问题，去看组件仓库**，
不要在本仓库里发明默认值。

## 2.4 外壳会拿到哪些错误码（排障先看这个）

组件报的是**结构化错误码**，契约禁止按文案判断；`XSpiderAPI.translate` 把 `code` 翻成
`XSpiderAPIError`，上层（`SyncStore.classify`、`DownloadStore.isRetryable`）再决定给用户
什么提示。常见映射：

| 组件的 `code` | 什么情况 | 外壳翻成 |
|---|---|---|
| `not_found` | 用户 / 推文不存在 | `userNotFound` 或按上下文 |
| `unauthorized` | 凭据失效或当前账号无权执行操作 | `notAuthorized(原因)` → 给出可操作提示 |
| `rate_limited` | X 返回 429（带 `retry_after_s`） | 状态行显示限流；下载侧降并发 |
| `parse` | 响应结构与预期对不上——**"X 改版了"的信号** | `parseFailure` |
| `upstream` | 其它上游错误（带 HTTP `status`） | `responseError(status:)` |
| 传输 / 形状（无 `code`） | 组件没起来 / 超时 / 响应不是契约包络 | `transport` / `shape`；只有 `isTransport` 值得重试 |

**判断一律用 `code`，不要匹配 `message`**——组件与外壳都遵守这条。

## 2.5 组件领域问题只做路由，不在本仓库维护

mac 应用只判断“这是应用侧问题还是组件侧问题”，不维护 X 端点行为盘点。

以下情况直接转到 `x-spider-core` 排查并在那里补测试 / fixture：
- 原始 X 数据缺字段、解析错误或分页结果异常；
- 请求失败、限流、认证或其它 core 内部请求问题；
- crawl 候选不完整、服务端停止条件异常；
- 下载引擎、断点、代理或 CDN 请求行为异常。

本仓库只处理 core 已经通过契约返回的数据如何映射、展示、缓存和记录。不要为了临时修 UI 症状在 mac 增加第二套请求或原始响应解析。

## 2.6 排障：组件出问题时该看什么

- **组件日志走 stderr**，被 `XSpiderComponent` 逐行转发到 `AppLogger`（分类 `CORE`）。
  想看更细：设环境变量 `XSPIDER_LOG=debug` 再启动（默认 `warn`）。
- **改动没生效**先确认加载的是哪一份组件：启动日志会打
  `组件已就绪 … path=…`（外部目录优先，bundle 里的是兜底，见 `docs/COMPONENTS.md` §2）。
- **代理**：组件是独立进程，**不继承 macOS 系统代理**。"跟随系统"那一档由
  `SystemProxy.current()` 解析成具体 URL，经 `net.set_proxy` 告诉它；**改代理无需重启**
  （`null` = 明确关闭，与"字段缺失"语义不同）。
- **组件连不上 / 起不来**：`ComponentError.transport`；`notInstalled` = 没找到二进制；
  `shape` = 响应对不上契约（版本不匹配或找错了文件）；`contract` = 组件返回了结构化错误。
- **契约版本核对**：命令行跑 `xspiderd --version` 会打印
  `xspiderd <build> (契约版本 <contract>)`。应用要求主版本 `1.x`。

## 2.7 组件从哪来、怎么部署 / 更新

查找顺序（**外部目录优先**）、`xattr -cr` + ad-hoc 签名两步、退出码 137 症状、
随包组件的版本账本（`components.lock.json`）与升级 / 校验脚本，**统一维护在
[`docs/COMPONENTS.md`](COMPONENTS.md)**；设置页「组件状态」绿灯的判据也写在那一册 §2。


# 第 3 部分 · 下载与同步

## 3.1 外壳只剩文案与接线

下载引擎、断点续传、并发调度与完整性校验都在组件里（`dl.*`，见 §2.3）。外壳负责的是：
**算目录与文件名**（`DownloadStore.targetDir` + `MediaJudgement` + `AccountFolder`）、
**跳过判定**、把任务交给组件（`dl.enqueue`）、轮询进度（`dl.events` / `dl.list`）、
**收尾再验一遍内容**（`FileIntegrity`）、写记录与通知。

- `dl.enqueue` 的 `job_id` 用任务的 `gid`（跨重启稳定），因此**重复入队是幂等的**——
  但"继续 / 重试"**不是**"再入队一次"：对已在组件里的任务要调 `dl.resume`
  （对 `paused` 与 `error` 都有效，只拒绝 `complete`）。只 re-enqueue 的话组件回
  `already_known`、任务原地不动，症状是"界面显示下载中、进度停在断点处"。
- **完整性要验两遍**：组件回答"落盘字节数与服务端声明一致"，而 CDN 出错时可能返回
  HTML 错误页、字节数还可能是对的——所以"这是不是一张真图 / 真 mp4"留在外壳侧再判
  （`FileIntegrity`）。`expect_size` 已知就传给组件，未知由组件自己探。

> 两条下载路径（单张/选择 vs 爬虫）、引擎差异（内置 / aria2Next）、断点文件命名
> （`.part.http` / `.part.aria2next`）等实现细节**已迁到组件**，见组件仓库
> `docs/02-X-DOMAIN-NOTES.md` 与 `docs/07-API-REFERENCE.md` §4.4。外壳只保留一份后缀清单
> （`MediaJudgement.enginePartialSuffixes`），用于**跳过**这些临时文件（它们名字里也带媒体 id，
> 被解析出来会把没下完的媒体记成"已下载"，而记录模式只信记录、不回查文件）。

## 3.2 「全选」为什么用排除法

**全选必须表示"全部"**，而"全部"里的未加载部分在前端列举不出来。
因此选择集有两种模式（`Models/MediaSelection.swift`）：

- `.include`：集合 = 要下载的；
- `.exclude`：集合 = **不要**下载的，其余全要（"全选"态）。

反选恰好是"换模式而集合不变"（补集），所以它是对合的（连按两次回到原状）。

爬虫据此跳过 `excludedKeys`；`.include` 态下收齐勾选项就**提前收工**——
这是"选择下载"相对旧「下载全部」的实质好处：只为自己要的东西付费翻页。

## 3.3 下载判定依据（改这块前必读）

三选一（设置项，规范 `MEDIA_RECORDS.md` §6.1），**默认集中式**：

- **按文件名**：解析模板（可在扩展名前追加媒体 id 作唯一标识）后查文件是否存在。
  索引让文件名本身成为可靠判据（即使模板不含唯一变量，同推文多张媒体也不互相覆盖）。
  代价：改名或移动文件后会被视为**未下载**。
- **记录文件·分布式**：记录文件（`.downloadedrecord.json`）落在**账号文件夹**里，跟随保存路径。
- **记录文件·集中式**（默认）：记录文件在应用数据目录
  （`~/Library/Application Support/XSpiderMac/records/downloads/<user id>.json`），
  与媒体文件分离——判定与「保存路径」解耦。

两种记录模式都是**只查记录、不回查文件**。这正是它存在的意义：改文件名模板、重命名、
移动文件、整目录搬家，记录都依然有效。历史默认文件名 `.downloaded.json` 视为"未设置"，
改用 `.downloadedrecord.json`。

⚠️ **不要给记录模式加"记录 ↔ 文件"双向校验**——那会把"用户改过文件名"误判成
"没下载过"而重复下载，恰好抵消它唯一优于"按文件名"的地方。

记录文件带版本号（`version` + `kind`，不合法整份丢弃、不迁移）且**原子写**
（同目录临时文件写入后 rename 覆盖）。**记录体系的完整规范——数据形状、命名、同步窗口、
导入导出、按文件名重建——见仓库根 `MEDIA_RECORDS.md`**；本节只讲取舍，不再抄一份。

## 3.4 同步

`SyncStore` 按关注清单批量补齐缺失媒体。同步判定与下载判定**独立**（各自三选一）。
记录模式下同步走**窗口语义**（规范 `MEDIA_RECORDS.md` §6.3）：只看锚点 `anchor_day`
前后一天窗口内的内容，二次同步因此快得多；`anchor_day` 与窗口内已确认存在的 id 写回记录。
单用户总闸 150s（`AsyncTimeout.withTimeout`）。

## 3.5 记录层与收尾校验的实现落点

| 文件 | 职责 |
|---|---|
| `Services/MediaRecords.swift` | 下载 / 同步记录的读写、缓存、原子写、两种形态（分布式 / 集中式） |
| `Services/MediaJudgement.swift` | 文件名（模板 + 唯一标识后缀）、按文件名判定、断点后缀清单 |
| `Services/RecordsIO.swift` | 导入 / 导出 / 按文件名重建（规范 §7 / §8） |
| `Services/FileIntegrity.swift` | 下载收尾的内容校验（大小 + 魔数 + 错误页特征） |
| `Support/AccountFolder.swift` | 账号文件夹命名 `昵称-用户名[数字id]`（记录落点，同一 id 永远同一文件夹） |


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
（视频/GIF 角标）各自被三处共用，范围不同：**按钮**用于搜索网格、瀑布流、评论缩略图；
**角标**用于搜索网格、瀑布流、时间线推文卡的媒体行——评论缩略图不用角标。

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

## 4.6.1 翻译与语言包

**用系统 `Translation` 框架**（本地翻译），不抓 X 的翻译端点——
应用不直接调用 X 翻译接口；翻译功能只使用系统 `Translation` 框架。
相关 API 全部是 **macOS 15.0+**，与基线一致，无需版本判断。

### 自动翻译的判据：白名单

**只翻译设置里明确列出的语言**（`autoTranslateLanguages`），不是"凡非目标语言就翻"。

理由：时间线里语言极杂，逐个遇到就翻既耗电刷屏，也会频繁向系统请求语言包。
**清单为空 = 不自动翻译任何条目**（比"全部翻"安全）。
判据实现见 `TranslationStore.shouldAutoTranslate`。

### 语言包：会不会自动下载

**会，但是"按需触发"**：`translationTask` 的会话首次 `translate()` 时若缺语言包，
系统会弹窗提示并下载。浏览场景下体验不好——第一次遇到某语言要等下载。

因此设置了**语言清单窗口**（`Views/TranslationLanguageSheets.swift`），
可查看每种语言的包状态（已下载 / 可下载 / 不支持）并**预先下载**。

### ⚠️ macOS 15 上 `TranslationSession` 没有公开 init

它**只能由 SwiftUI 的 `translationTask(configuration:)` 交出**
（`TranslationSession(installedSource:target:)` 是 **macOS 26+**，不能用）。
所以"主动下载语言包"必须由**视图**做：`Views/TranslationPackDownloader.swift`
是一个零尺寸视图，消费 `TranslationPackStore.pendingDownloads`，
为每种语言新建一个 configuration 交给 `translationTask`，在闭包里调
`prepareTranslation()`。

**注意**：`LanguageAvailability.supportedLanguages` 是 **async** 属性（macOS 15 起）。

**能否后台静默下载**：准备语言包这件事本身不需要用户操作（从我们这侧看就是后台下载），
但系统**首次为某语言对下载时仍会弹一次确认**——这是系统行为，应用无法绕过；
下载进度也由系统管理，我们只知道"开始了 / 结束了"。

### ⚠️ 不能用 `Locale.current`（会毁掉目标语言）

**实测**（App 内）：

```
Locale.current.identifier  == "en_US"        ← 被降级成英语
Locale.preferredLanguages  == ["zh-Hans"]    ← 用户真实语言
Bundle.main.localizations  == ["en"]         ← 原因
```

本 app 的三语是 `L10n` **自实现**的（不走 bundle），bundle 里只声明了 `en`，
于是系统把 `Locale.current` 降级成开发语言。用它当翻译目标会导致
**"设了跟随系统，却把日语翻成英语"**（用户实测反馈，且连带让英语包显示"无法下载"
——因为源=目标=en，系统对同语言对返回 `unsupported`）。

**正确做法**：用 `Settings.systemPreferredLanguage`（读 `Locale.preferredLanguages`）。
取语言**显示名**同理，用 `Settings.displayLocale`，
否则"日本語"会显示成 "Japanese"。

### 语言包状态的三个实现要点

1. **与目标语言相同 → `.notNeeded`（"无需语言包"），不要问系统**：
   系统对 "zh → zh" 返回 `unsupported`，但用户视角是"不需要"。
2. **`prepareTranslation()` 返回 ≠ 下载完成**：它只表示系统已接受请求。
   之前把它当完成信号，于是下载刚发起就清掉"下载中"、UI 退回"可下载"，
   而系统其实还在后台下载（用户实测："一直显示可下载"）。
   现在请求发出即标记"下载中"，**轮询状态**直到变 `.installed` 才移除。
3. **系统不暴露下载进度**（`Translation.framework` 无 progress 相关成员，实测确认）。
   所以只有"下载中 / 已完成"两态，**无法显示百分比**——不要为此加进度条。

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

## 5.1 列表加载与应用侧分页状态

应用只负责消费 core 返回的 `items + cursor` 并维护 UI 加载状态。若 cursor、页内容或停止条件本身错误，
属于 core；mac 不解析原始 X timeline，也不维护 X 分页规则。

| 现象 | 应用侧根因 | 解法 |
|---|---|---|
| 列表停在约 20 帖 / 27 媒体，且随用户变化 | 视图侧 `.task(id:)` 的 id 随翻页变化 → 自我取消 | 填充循环由 Store 持有，View 只触发 |
| 同页内容重复进入 `ForEach` | 展示层未按稳定 id 去重 | 入 Store 前完成应用侧去重；不要去解析 raw timeline 修 |

## 5.2 时间范围

| 现象 | 根因 | 解法 |
|---|---|---|
| 点「确定」没反应 | `dateRange` 只有爬虫读，浏览路径没读 | 展示路径加客户端筛选（与爬虫同语义） |
| 账号有空窗期就加载不出内容 | 用"连续空页计数"判到底，而空窗期只是时间轴的空隙 | 改判据为**时间轴推进**（`oldestSeenAt < since`） |
| 某页全被筛掉后列表提前结束 | 同上 | 判定"到底"只看**服务端原始条数** |
| 「至」那天没有内容 | `DatePicker` 的 `end` 是当天零点 | 展示路径把范围交给组件（`fetch.search_timeline` 的 `since`/`until` 含当天），**外壳不再自己 +1 天** |
| 范围整体偏移一天 | 拼给 X 的日期串用了 UTC 格式化 | 契约按**本地日历**理解日期；爬取的精确边界在 `CreationTaskStore.decide` |

> 时间范围现在是**两段式**：组件按 UTC 天做**粗筛**（省请求），外壳的 `decide`
> 再按**本地日历**做精确边界——所以 `crawlStrategy` 里 `since` 会故意各放宽一天（±1 天），
> 时区偏移最大 ±14h < 24h，±1 天足够覆盖。这是有意的分工，不是 bug。

## 5.3 评论与引用

若 focal、引用内容、回复集合或推广内容过滤本身错误，属于 core 契约结果问题；去组件仓库修，不在 mac 解析原始 X 响应。

| 现象 | 根因 | 解法 |
|---|---|---|
| 二级回复展示范围有限 | mac 只展示 core 契约返回的回复集合，不额外直连 X 补抓 | 若返回集合本身异常，转到 core 排查；mac 只负责映射与展示 |

## 5.3.1 连转同一条推文 → 卡片后面一片空白

**现象**：某账号为刷浏览量连续转推同一条推文，列表里出现多张空白卡片
（只有第一张正常）。搜索页尤其常见。

**根因**：转推展平后，**每条的 `post.id` 都等于被转发的原推文 id**。
于是同一页里出现多个相同 id，而 SwiftUI 的 `ForEach` 要求 id 唯一——
重复时只渲染第一个，其余留空。**不是布局问题，是数据有重复 id。**

**解法**：**同页去重**（此前只做了跨页去重）。

- `HomepageStore.loadPostList`：原为 `seenPostIds = Set(posts.map(\.id))`——
  只**记录**不过滤，同页重复全部进列表。现改为先过滤再记录：
  ```swift
  var pageSeen = Set<String>()
  let dedupedPage = posts.filter { pageSeen.insert($0.id).inserted }
  seenPostIds = pageSeen
  ```
- `loadMorePostList` 的 `seenPostIds.insert().inserted` **本身就覆盖同页与跨页**，
  无需额外改动（已加注释说明，避免以后被"优化"掉）。
- `HomeTimelineStore.reload` 同样是 `Set(newPosts.map(\.id))`，已一并修正。

**如何避免再犯**：任何进 `ForEach` 的列表都要确认 id 唯一。
"展平转推"这类操作会让**多条数据的 id 相同**，是重复 id 的高危来源。

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

**回收语义（1.0.1 起）**：设置项是「超限回收目标（占上限 %）」，默认 60、区间 0–90。
占用**超过上限**后，从最旧的文件开始删，直到占用降到 `上限 × 这个百分比` 为止
（上限 1 GB、目标 60%：占用 2 GB → 删到剩 600 MB）。目标只由**上限**决定，与当前占用无关。

- 旧语义是"一次清掉已用容量的百分之几"（默认 30），严重超限时靠"至少降到上限以下"兜底——
  回收量随占用增长，且刚降到上限又会立刻越界、反复全目录扫描。新语义一次留出固定余量。
- 区间上限是 **90 而不是 100**：必须让目标**严格低于上限**，否则清完立刻再超限。
- `0%` = 超限后全部清空（想每次超限都清干净时用）。
- 设置项**改了存储键**（`cacheReclaimTargetPercent`），老用户的旧值（30 那种）不再被读取，
  直接落到新默认 60%——语义变了两不相容，宁可回到默认，也不要让旧数值被按新含义解读。
- 「缓存上限」可选**无上限**（哨兵值 `Settings.unlimitedCacheLimitMB = 0`）：此时不做容量控制，
  连全目录扫描都不做。用 `0` 而非 `Int.max`，越界判断与乘法都不会溢出。

> 教训：「比例」这类设置项必须把**基数是哪个量**写进名字与提示文案（这里 = 上限，不是已用容量）。

## 5.6 构建与分发

- **"修复无效"先确认跑的是哪个构建**（见 §0.3）；
- **未签名分发**：不做签名与公证（无开发者账号），README 里说明三种放行方式
  （右键打开 / `xattr -dr com.apple.quarantine` / 系统设置放行）；


# 第 6 部分 · 约定与清单

## 6.1 改代码前自检

1. **要动"数据怎么取 / 请求长什么样"** → 去组件仓库
   （`github.com/LeeDespo/x-spider-core`），本仓库只写映射与产品语义。
   要改的是**契约本身**（加 method / 改出参）→ 先改契约，再改组件与外壳；
2. **要改解析** → 这里只处理 `XSpiderMapping` / `XSpiderJSON` 的**契约 JSON → 应用模型**映射；
   原始 X 响应解析、字段抽取或分页结果问题属于 core，不在 mac 侧补第二套解析；
3. **要加客户端筛选** → 必须同时想好**停止条件**，否则会翻到服务端尽头吃限流
   （爬取侧的精确筛选见 `CreationTaskStore.decide`）；
4. **要动 UI 层级或悬停** → 记住 §4.7 的三个 AppKit 陷阱；
5. **要删/改下载判定** → 先读 §3.3 的取舍说明，规范见 `MEDIA_RECORDS.md`；
6. **不要写版本降级分支**（支持 15.0+，直接用满足该版本的 API）。

## 6.2 验证清单

按改动类型「改什么测什么」的实测清单、live 测试门控（`XSPIDER_LIVE=1`）与日志观察
手法统一维护在 [`docs/TESTING.md`](TESTING.md)；任何改动的基线是
`xcodebuild test` 全绿。

## 6.3 已知限制（不是 bug）

1. **二级回复展示范围取决于 core 契约结果** —— mac 不额外直连 X 补抓；
2. **X 的视频一般没有内嵌字幕**，因此不提供字幕选择；
3. **搜索结果可能有极个别遗漏** —— 浏览走搜索接口求快，而**下载**始终由爬虫逐页抓取，
   会把遗漏补上；
4. **未签名** —— 首次打开需手动放行。

## 6.4 已移除的死代码（勿再当作"已实现"）

| 已删 | 原因 |
|---|---|
| `NetworkClient` / `RequestGate` / `XClientTransaction` | HTTP 重试/退避、限流闸门、请求签名——**已收进组件**（第 2 部分） |
| 旧直连 X / 下载实现 | 已迁入 `x-spider-core`；mac 侧只保留契约客户端、映射与产品逻辑 |
| 评论发布输入框 | 从未形成可用产品能力，已删除，避免把未完成入口误认为已支持功能 |
| `SelectiveDownloadSheet.swift` | 从未被引用（选择模式一直是内联的），留着会让人以为"选择页面"是那个弹窗 |
| 字幕选择 | 那是"视频内嵌字幕轨"，与需求（实时翻译字幕）不是一回事 |
