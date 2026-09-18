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

- 代码注释与 UI 文案以中文为主（与现状一致）；L10n 走 `Support/L10n.swift` 的 `L()`。
- 状态一律放 `@Observable` Store（`Stores/`），视图 `@State` 只放纯 UI 态；单例 `*.shared`。
- 下载引擎为内置 aria2Next（`Services/Aria2Engine.swift`），不引入其它下载器。
- **最低系统版本 macOS 15.0**（改动时不要降低；15.0 是为了用系统
  `Translation` 框架，见 `docs/DEVELOPMENT.md` §8）。
  改动系统 API 前先确认其可用版本不低于 15.0。
- **不要为版本差异写降级分支**：支持范围就是 14.4+，直接使用满足该版本的 API，
  不要再加"旧系统隐藏按钮/回退旧实现"这类分支（会增加维护面且无法测试）。
