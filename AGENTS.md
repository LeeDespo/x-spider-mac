# AGENTS.md — x-spider-mac

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.

## 这是什么项目

上游 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)（Tauri + React + zustand，Windows 优先，
已停止维护）到 macOS ARM / SwiftUI 的移植，App 名 **XSpiderMac**。上游源码完整 vendor 在本仓库
`src/`（前端）与 `src-tauri/`（Rust 侧）里，**只作行为参照，不再构建、不要修改**。

**取数与下载已经不在本仓库里。** 自 2026-10-01 起，X 的请求（签名 / 限流 / 重试 / queryId 自愈）、
写操作、下载引擎与爬取全部收进组件 **`x-spider-core`**（Rust sidecar `xspiderd` + 本地 JSON-RPC，
契约版本 **1.5.1**；仓库 `github.com/LeeDespo/x-spider-core`，开发机上一般是它的并列目录）。本仓库（外壳）只做
**契约 JSON ↔ 应用模型的映射**与 UI——**不要再在本仓库里实现取数、下载或请求逻辑**。

> 上游的其他内容（官网 `homepage/`、Windows 版截图、Tauri/Vite 脚手架）已从本仓库移除：
> 它们与移植无关，且官网含上游的赞助入口。`src/` 与 `src-tauri/` **保留**——
> 上游已停止维护，这是唯一一份可对照的 **X 端点行为**参照。

## 目录速览

| 路径 | 内容 |
|---|---|
| `XSpiderMac/` | Swift 应用本体（xcodegen `project.yml` 生成 xcodeproj） |
| `XSpiderMac/Sources/XSpiderMac/` | `Stores/`(状态) `Services/`(组件客户端 / 契约映射 / 记录层) `Views/`(UI) `Models/` `Support/` |
| `XSpiderMac/Resources/Binaries/` | 随包携带的组件兜底：`xspiderd` + `aria2next`（外部目录优先，见 `docs/DEVELOPMENT.md` §2.7） |
| `src/`, `src-tauri/` | 上游源码，**X 端点行为的参照**（尤其 `src/twitter/api.ts`、`src/stores/`）；**不是"本仓库该怎么取数"的答案** |
| `docs/DEVELOPMENT.md` | **开发者手册**：架构、组件边界、组件部署与更新、踩坑与设计决策（改代码前必读） |
| `MEDIA_RECORDS.md` | **记录体系规范**：下载/同步记录、判定三选一、命名（改记录前必读） |
| `SETTINGS_DEFAULTS.md` | 设置项默认值一览（改默认值须 bump `settingsSchemaVersion`，见 `MEDIA_RECORDS.md` §9.2） |
| `script/build_and_run.sh` | 构建 + 启动 Debug 版（arm64） |
| `script/package_dmg.sh` | 打包 Release 为 dmg（未签名分发） |

## 黄金法则：外壳只做映射，取数与下载看组件仓库

**本仓库是外壳。** 它不直接向 X 发请求，也不自己实现下载——签名、限流闸门与 429 熔断、
重试、queryId 自愈、下载引擎、爬取终止判据，全部在组件 `x-spider-core` 里。外壳只剩
**契约 ↔ 应用模型的映射**（`Services/XSpiderMapping.swift` / `XSpiderJSON.swift`）
和**产品语义 + UI**。所以"与上游逐字对齐"这条旧法则**只对 X 端点行为成立，不再适用于外壳**：

| 你要改的东西 | 去哪儿看 |
|---|---|
| 数据怎么取、请求长什么样、某个**错误码**是什么意思 | 组件仓库（`docs/07-API-REFERENCE.md`、`docs/CONTRACT.md`）；**不要在本仓库里仿上游发明取数逻辑** |
| 契约 JSON → `TwitterPost` / `TwitterUser` / `TwitterMedia` / `ReplyNode` | `Services/XSpiderMapping.swift`（映射的唯一入口） |
| 下载队列、跳过判定、目录与文件名 | `Stores/DownloadStore.swift` + `Services/MediaJudgement.swift`；记录规范见根目录 `MEDIA_RECORDS.md` |
| X **端点行为**（请求形状、分页语义、解析路径）到底怎样 | 上游 `src/twitter/api.ts`、`src/stores/`、`src/components/InfiniteScroll.tsx`——仍是**端点行为参照**，但**不再是外壳的实现答案** |

组件与外壳的接口只有一个：**`xspider_call(method, json)` + `system.version` 握手**
（外壳侧对应 `XSpiderComponent.call(_:_:)`；sidecar 里是 `POST /` 加 `X-XSpider-Token` 头）。端点路径 / `queryId` / `features` /
HTTP 头**都不进契约**，也不该出现在本仓库的新代码里。

> 组件从哪来、怎么部署/更新（`xattr -cr` + ad-hoc 签名，漏了会以退出码 137 静默被杀）、
> 出问题时看什么、错误码到界面的映射，见 `docs/DEVELOPMENT.md` 第 2 部分。

### 曾经踩过的大坑（勿再引入）

> **先分清归属**：**讲 X 取数 / 分页 / 搜索结果解析**的那几条（含第 23 条），实现现在
> **都在组件里**——留在这里是给"理解 X、排障、写外壳映射"用，**改外壳代码时不要再去动这些逻辑**。
> 其余条目（UI 层级、映射、记录、命名、图片管线、手势）是**外壳侧的纪律**，照旧遵守；
> 若其中还提到已废弃的函数，以现役实现为准。

1. **variables.cursor 硬编码 null**：导致每页都请求第一页 → 无限加载 / 创建任务重复检索同一页。
   首页请求应**省略** cursor 键（上游 `JSON.stringify` 会丢弃 undefined），翻页才传真实 cursor。
2. **爬虫循环里 `continue` 前不推进 cursor**：同一页会被无限重抓。上游语义：fetch 返回后第一件事
   就是 `nextCursor = cursor`，日期/类型过滤在推进之后。
3. **把"翻到服务端尽头"当成无限滚动**：上游 InfiniteScroll 只补拉到视口填满（约两屏），剩余靠用户
   滚动逐页触发。无停止条件的连发循环会触发 429 限流风暴。
4. **空页必须终结**：上游 getUserMedias 解析出 0 条时返回 `cursor: null`（到底信号）。
5. **图片按 `?name=small` 全尺寸解码**：small 是 680px 宽（不是 120px）。缩略图必须离主线程、
   按目标尺寸降采样解码，并做缓存；否则网格滑动卡顿。
6. **评论区混进广告**：TweetDetail 的 `conversationthread-*` 里会插广告，
   判据是 `item.itemContent.promotedMetadata` 非空（实测 3 条/会话）。
   所有解析入口都要过滤，漏一个就会在对应界面露出广告。**过滤现在在组件里**——
   外壳拿到的是已经清过广告的数据。
7. **评论树不要压平，父指针别丢**：契约已经给了 `parent_id` / `in_reply_to_screen_name`，
   外壳的层级构建在 `Services/XSpiderMapping.swift` 的 `replyNodes`（按父链算深度）；
   孤儿（父不在本页）**不能丢**，要标 `isPartialParent`。
   「回复 @xxx」必须用**被回复者**，不是本条作者。
   （旧的 `TwitterAPI.extractReplyNodes` 只剩测试引用，不要接线。）
8. **浮层内换推文必须 `.id(post.id)`**：不加的话 SwiftUI 复用视图实例，
   `@State`（replies/liked/mediaIndex）串味、`.task` 不重跑，
   表现为"跳到引用推文后内容还是上一条的"。（代价见下条）
9. **别为回退重复请求**：`.id` 重建会重跑 `.task` → 再请求一次 TweetDetail。
   回看已看过的推文走 `TweetDetailCache`（TTL 5 分钟）；
   详情页只调 `getTweetDetailTree` 一个入口（分别取 focal 与回复会把同一请求打两遍）。
10. **一个窗口只能有一个 `.escape` 快捷键**：两个都注册时只有一个生效，
    语义随注册顺序漂移（"ESC 有时返回、有时直接关"）。
11. **原生焦点环画在 SwiftUI 之上**：搜索框的蓝色焦点环会盖住详情浮层，
    `zIndex` 无效。用 `.textFieldStyle(.plain)` + `.focusEffectDisabled()`，
    并在浮层出现时广播 `.homeResignSearchFocus` 交出焦点。
12. **评论媒体不是"没有数据"，是渲染层没画**：`legacy.entities.media` 早已
    映射进 `post.medias`。遇到"某功能好像不存在"，先分清**解析缺失**还是**渲染缺失**。
    评论缩略图：单张保宽高比、多张 64pt 方格（4 张才放得进 410pt 卡片），
    一律走 `ImageCache` 降采样。
13. **强调色用在按钮背景上**，不是把图标/文字染成强调色。行内文字型小操作仍可用强调色文字。
14. **媒体卡的按钮一律走 `Views/MediaCardActions.swift`**，不要各写一份：
    三处（评论缩略图/瀑布流/搜索网格）必须都按已下载状态切换按钮，
    各写一份必然漂移——瀑布流曾因此完全没有下载按钮。
15. **媒体查看窗口用 `NSWindow` 不是 `.sheet`**（`Support/MediaViewerCenter.swift`）：
    用户在窗口里选一张媒体再看另一张，各处的切换**范围**不同
    （详情=本推文 / 瀑布流=整个瀑布流），由 `Session.Origin` 决定，别混用。
16. **搜索页数据源按用户记忆、默认推文**：`HomepageStore.rememberedSource(for:)`。
    应用时机**必须在 `loadPostList` 之前**，否则先用默认源拉一页再切源重拉，
    白白多一次请求（项目一直在对抗 429）。
17. **别在 AppKit 控件上盖透明手势层**：`Color.clear { onTapGesture }` 会吃掉
    下层 `AVPlayerView` 控制条的全部点击（"播放按钮点不动"的根因）。
    手势直接挂在控件上。
18. **视频控件全放底栏**（`AVPlayerView.controlsStyle = .none`）：
    `.floating` 会浮在画面上遮挡内容。
19. **媒体区的手势提示别用 `.help`**：整片区域挂工具提示几乎一碰就弹，
    且同视图内移动不消失。这类区域改用按需的悬停态（`onHover`）自绘提示，
    不要整片挂 `.help`。
20. **「全选」必须表示全部**，所以选择集用 `MediaSelection` 的 include/exclude
    两种模式（`Models/`），**不要**退化成"把已加载的灌进一个 Set"——
    那样用户不知道自己选了什么。全选态靠**排除法**交给爬虫跳过（`excludedKeys`）。
21. **展示筛选（日期/类型）与爬虫必须同语义**：无 `createdAt` 放行、
    纯文字推文不受类型筛选影响。**去重必须先于筛选**（先 `seenPostIds` 再过滤）。
22. **加客户端筛选就要加停止条件**：判定"到底"只看**服务端原始条数**，
    而**客户端筛选的终止判据必须是"时间轴推进"**（`oldestSeenAt < since`，
    与爬虫 `now > since` 同义），**不要用"连续空页计数"**——
    账号停更一两个月的空窗期会被误判成"没有内容"（用户实测反馈）。
    计数要取服务端原始页，取筛选后的同样不推进。
23. **搜索端点（SearchTimeline）必须 POST + JSON body**：GET 一律 404，
    而**这个 404 与 queryId 无关**——实测新旧两个 queryId 用 POST **都返回 200**，
    只有随机乱写的才 404。曾用 GET 试并误判成"queryId 失效"，白做了自愈。
    **queryId 自愈现在在组件里**（外壳的 `SearchQueryIdProvider` 已删除）——
    外壳只传 `screen_name` / `since` / `until` / `media_only` / `count` / `cursor`
    （cursor 可选）。这也是"端点行为留在参照、实现归组件"的一个例子：本仓库不该再维护这份自愈。
24. **日期边界**：`DatePicker` 的 `end` 是**当天零点**，本地比较要用 `DateRange.inclusiveEnd`
    （否则「至」当天被整天排除）。拼给 X 的日期串由组件处理：契约 `fetch.search_timeline`
    的 `since` / `until` 按**本地日历**理解且**含当天**，组件内部按排他语义 **+1 天**——
    **外壳不要再自己加一天**（旧的 `searchRawQuery` / `nextDay` 已是历史）。
    爬取侧（`crawl.run`）按 **UTC 天**粗筛，所以 `CreationTaskStore.crawlStrategy` 故意各放宽一天，
    精确边界由 `decide` 用本地日历再判。
25. **容量的单位要统一**：缓存上限用**十进制 MB**（`× 1_000_000`），
    与 `ByteCountFormatter.file` 的显示口径一致。
    曾用 MiB（`× 1_048_576`）导致"设 200MB 显示 209MB"，用户以为上限失效。
26. **评论的评论只有贴主的**是 **X 服务端行为**，不是解析 bug
    （实测：以评论为 focal 也只返回贴主那条，且无"更多回复"游标）。
    别再为此改解析。
27. **视频字幕用 AVFoundation 媒体选择 API**（`select(_:in:)` 等，
    均为 macOS 10.8+，远低于基线 15.0，**不要写版本判断**）。
    选的是视频**内嵌**字幕轨；X 视频多数没有，此时按钮不显示属正常。
    （字幕选择已随 1.0.0（d6dca66）移除，此条留作将来重做字幕时的实现纪律。）

## 构建与验证

`XSpiderMac/project.yml` 是工程的唯一真源，`XSpiderMac.xcodeproj` 由它生成（入库）——
**改了 `project.yml`（加文件、改设置、改 target）必须重跑 `xcodegen generate`**
（需要 `brew install xcodegen`）。

```bash
# 生成工程（改了 project.yml 后必做）
(cd XSpiderMac && xcodegen generate)

# 构建 + 运行（arm64 Debug）
script/build_and_run.sh

# 单元测试
cd XSpiderMac && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
  -destination 'platform=macOS,arch=arm64' test
```

- 运行日志用 `AppLogger`（分类 NET/DL/HOME/REC/SYNC/APP/CORE…），验证行为用
  `log stream --predicate 'process == "XSpiderMac"'` 或 Console.app；
  **组件日志以 `组件: …` 出现在分类 `CORE`**，要看更细设 `XSPIDER_LOG=debug`。
- **组件没起来会阻断一切取数与下载**：设置页「组件状态」绿灯 = 进程真的起来并握手。
  换组件（外部目录里的 `xspiderd` / `aria2next`）后要 `xattr -cr` + `codesign --force --sign -`，
  否则以退出码 137 静默被杀（见 `docs/DEVELOPMENT.md` §2.7）。
- 改动分页/爬虫后，必须实测两条路径：① 搜索页滑到底能持续加载超过 ~40 条且不重复；
  ② 「下载全部」创建任务对同用户同条件执行两遍，第二遍应全部 skip 而非重复创建。

## 其他约定

- **不要截图 / 录屏做视觉验收**（用户明确要求）：太耗 token。
  需要"看一眼"的验收由用户自己做。改完 UI 后说明改了什么、请用户确认，
  自己则用单测 + 真实 API 响应核对正确性。
- 代码注释与 UI 文案以中文为主（与现状一致）；L10n 走 `Support/L10n.swift` 的 `L()`。
- 状态一律放 `@Observable` Store（`Stores/`），视图 `@State` 只放纯 UI 态；单例 `*.shared`。
- **取数与下载全部经组件**（`Services/XSpiderComponent.swift` 是唯一客户端）：
  本仓库不引入自己的 HTTP / 下载实现，也不在映射层里仿上游发明取数逻辑。
  接口只有 `xspider_call`（外壳侧对应 `XSpiderComponent.call(_:_:)`）+ `system.version` 握手
  （见上方黄金法则）。
- **最低系统版本 macOS 15.0**（改动时不要降低；15.0 是为了用系统
  `Translation` 框架，见 `docs/DEVELOPMENT.md` §4.6.1）。
  改动系统 API 前先确认其可用版本不低于 15.0。
- **不要为版本差异写降级分支**：支持范围就是 15.0+，直接使用满足该版本的 API，
  不要再加"旧系统隐藏按钮/回退旧实现"这类分支（会增加维护面且无法测试）。
- 返回导航统一走 `Support/NavigationHistory.swift`，不要在视图里各自维护"上一步"——
  多入口（引用推文 / 头像 / 搜索）各自记账必然互相打架。
