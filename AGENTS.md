# AGENTS.md — x-spider-mac

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.

## 这是什么项目

上游 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)（Tauri + React + zustand，Windows 优先，
已停止维护）到 macOS ARM / SwiftUI 的移植，App 名 **XSpiderMac**。上游源码完整 vendor 在本仓库
`src/`（前端）与 `src-tauri/`（Rust 侧）里，**只作行为参照，不再构建、不要修改**。`homepage/` 是上游
官网，与 App 无关。

## 目录速览

| 路径 | 内容 |
|---|---|
| `XSpiderMac/` | Swift 应用本体（xcodegen `project.yml` 生成 xcodeproj） |
| `XSpiderMac/Sources/XSpiderMac/` | `Stores/`(状态) `Services/`(网络/下载) `Views/`(UI) `Models/` `Support/` |
| `src/`, `src-tauri/` | 上游源码，**移植行为的唯一权威参照**（尤其 `src/twitter/api.ts`、`src/stores/`） |
| `script/build_and_run.sh` | 构建 + 启动 Debug 版（arm64） |
| `docs/DEVELOPMENT.md` | 架构地图、构建验证方法、已知问题与修复方案（改代码前必读） |

## 黄金法则：与上游逐字对齐

X 的 GraphQL 端点对 queryId / features / variables 的格式极其敏感，服务端分页语义也有坑。
**凡是要动 X API 请求或分页逻辑，先读上游对应函数，逐字对齐，再动手**：

| 要改的东西 | 先读上游 |
|---|---|
| UserMedia / UserTweets / TweetDetail 请求与解析 | `src/twitter/api.ts` |
| 搜索页媒体列表加载与翻页 | `src/stores/homepage.ts` 的 `loadPostList` / `loadMorePostList` |
| 无限滚动触发节奏 | `src/components/InfiniteScroll.tsx`（**视口填满即停**，不是爬到底） |
| 创建任务爬虫（下载全部） | `src/stores/download.ts` 的 `runCreationTask`（fetch 后**立即**推进 cursor，再过滤） |
| 网格渲染 / 缩略图 | `src/components/homepage/PostListGridView.tsx`（`<img loading="lazy">` + `?name=small`） |

### 曾经踩过的大坑（勿再引入）

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
   三个解析入口（`extractPostsFromModuleInstructions` / `extractPostsFromTweetEntries` /
   `extractReplyNodes`）都要过滤，漏一个就会在对应界面露出广告。
7. **评论扁平化会丢掉父指针**：`legacy.in_reply_to_status_id_str` 与
   `in_reply_to_screen_name` 是响应里**现成**的，别再压平成 `[TwitterPost]`。
   层级用 `extractReplyNodes`；孤儿（父不在本页）**不能丢**，要标 `isPartialParent`。
   「回复 @xxx」必须用**被回复者**，不是本条作者。
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
13. **强调色用在按钮背景上**，不是把图标/文字染成强调色
    （回看 `docs/DEVELOPMENT.md` §10.3）。行内文字型小操作仍可用强调色文字。
14. **媒体卡的按钮一律走 `Views/MediaCardActions.swift`**，不要各写一份：
    三处（详情/瀑布流/搜索网格）必须都按已下载状态切换按钮，
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
    且同视图内移动不消失。用 `idleHoverHint`（`onContinuousHover` 闲置判定，
    一动就取消）。

## 构建与验证

```bash
# project.yml 变更后重新生成工程
xcodegen generate   # 在 XSpiderMac/ 目录下（需要 brew install xcodegen）

# 构建 + 运行（arm64 Debug）
script/build_and_run.sh

# 单元测试
cd XSpiderMac && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
  -destination 'platform=macOS,arch=arm64' test
```

- 运行日志用 `AppLogger`（分类 HOME/NET/DOWNLOAD…），验证行为用
  `log stream --predicate 'process == "XSpiderMac"'` 或 Console.app。
- 改动分页/爬虫后，必须实测两条路径：① 搜索页滑到底能持续加载超过 ~40 条且不重复；
  ② 「下载全部」创建任务对同用户同条件执行两遍，第二遍应全部 skip 而非重复创建。

## 其他约定

- **不要截图 / 录屏做视觉验收**（用户明确要求）：太耗 token。
  需要"看一眼"的验收由用户自己做。改完 UI 后说明改了什么、请用户确认，
  自己则用单测 + 真实 API 响应核对正确性。
- 代码注释与 UI 文案以中文为主（与现状一致）；L10n 走 `Support/L10n.swift` 的 `L()`。
- 状态一律放 `@Observable` Store（`Stores/`），视图 `@State` 只放纯 UI 态；单例 `*.shared`。
- 下载引擎为内置 aria2Next（`Services/Aria2Engine.swift`），不引入其它下载器。
- **最低系统版本 macOS 15.0**（改动时不要降低；15.0 是为了用系统
  `Translation` 框架，见 `docs/DEVELOPMENT.md` §8）。
  改动系统 API 前先确认其可用版本不低于 15.0。
- **不要为版本差异写降级分支**：支持范围就是 15.0+，直接使用满足该版本的 API，
  不要再加"旧系统隐藏按钮/回退旧实现"这类分支（会增加维护面且无法测试）。
- 返回导航统一走 `Support/NavigationHistory.swift`，不要在视图里各自维护"上一步"——
  多入口（引用推文 / 头像 / 搜索）各自记账必然互相打架。
