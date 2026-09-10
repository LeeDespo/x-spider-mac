# x-spider-mac 移植计划（代理执行手册）

> 读者：本项目 AI 代理（跨会话续作用）。写法：每步含"做什么 / 调用什么 / 验收标准"。
> 最近更新：2026-09-11。上游：https://github.com/MiningCattiva/x-spider（已停止维护，v2.2.2，GPL-3.0-only）。

---

## 0. 环境快照（已验证，勿重复检查）

| 项 | 值 |
|---|---|
| 硬件/系统 | M3 Pro，macOS 26（Tahoe），arm64-only |
| Xcode | 26.6 (17F113)，Swift 6.3.3，target `arm64-apple-macosx26.0` |
| **关键坑** | `xcode-select` 指向 CLT 且无 sudo → **所有 xcodebuild/swift 命令必须前置 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`** |
| git | 2.50.1，`http.sslVerify=false`（本机网络环境需要，勿改动） |
| gh | 2.100.0，已登录 **LeeDespo**（token 来自 keychain；fork API 返回 403 → 改用"建空仓库+推送"方案） |
| 仓库 | `/Users/mac/Documents/x-spider-mac` = 上游完整历史克隆；remote `upstream`→MiningCattiva/x-spider，`origin`→LeeDespo/x-spider-mac |
| MCP | `xcodebuildmcp` 2.7.0 已装于 `/opt/homebrew/bin`；codex 已启用 `build-macos-apps` 插件 |
| 待装 | `xcodegen`（M1 时 `brew install xcodegen`） |
| 上游实现 | Tauri 1.5 + React18 + antd + zustand + Rust reqwest + **aria2c sidecar（仓库里只有 win exe）** |

## 1. 目标与范围

**P0 保留（核心）**
1. 用户媒体浏览：按 screen_name 拉取时间线（GraphQL UserMedia/UserTweets，cursor 无限滚动）
2. 媒体筛选：日期范围 + 类型（photo/video/gif）+ 数据源（medias/tweets）
3. 下载：photo `name=orig`、video 最高码率 variant、gif variants[0]
4. 文件名/目录模板引擎（变量表见 §4.4）
5. 同文件跳过（sameFileSkip）、失败重试（5 次）
6. Cookie 登录（ct0 CSRF）、代理（系统/手动/关闭三态）
7. 下载管理：进度/暂停/恢复/重试/删除、系统通知

**P4 丢弃**：Windows 特有（explorer 打开、NSIS、win 图标体系）、赞助页、tauri 自动更新（可后补 Sparkle）。

**约束**：GPL-3.0-only 传染 → 本仓库保持同许可证与 LICENSE 文件；UI 全部 SwiftUI 重写；最低部署目标 macOS 26.0。

## 2. 技术选型（原实现 → mac 实现）

| 原实现 | mac 实现 | 理由 |
|---|---|---|
| React + antd + Tailwind | SwiftUI + `NavigationSplitView` | 原生一致性与系统材质 |
| zustand store | Swift 6 `@Observable` 类 | 语言级响应式，strict concurrency |
| Tauri `network_fetch`(reqwest) | `URLSession` + `AsyncBytes` | 原生代理/证书/HTTP2，删掉整个 Rust 层 |
| **aria2c sidecar (win exe)** | `URLSessionDownloadTask` | 上游只带 win exe；原生支持 resumeData、进度 delegate、代理配置 |
| tauri fs/path/dialog | `FileManager` / `NSSavePanel` + security-scoped bookmark | 原生沙盒友好 |
| tauri notification | `UserNotifications` | 原生 |
| dayjs | `Foundation.Date`（Twitter 格式 `EEE MMM dd HH:mm:ss Z yyyy`） | — |
| ramda 管道 | 普通 Swift 函数 | 可读性 |

依赖策略：运行时零第三方依赖；`xcodegen` 仅构建期工具。

## 3. 源码地图（上游文件 → 迁移动作）

| 上游路径 | 迁移到 | 动作 |
|---|---|---|
| `src/twitter/api.ts` | `Core/Twitter/TwitterAPI.swift` | **平移**：queryId、features JSON 全量照抄；`getCommonHeaders` 同构 |
| `src/twitter/utils.ts` (`getDownloadUrl`) | `Core/Twitter/MediaURL.swift` | 平移 |
| `src/utils/aria2.ts` + `src-tauri/binaries/` | — | **删除**，由 DownloadEngine 取代 |
| `src/stores/download.ts` | `Core/Download/DownloadEngine.swift` + `CreationTaskRunner.swift` | 重写（URLSession 语义），状态机/重试逻辑保留 |
| `src/constants/file-name-template.ts` | `Core/Templates/FileNameTemplate.swift` | 变量表 1:1 平移 |
| `src/utils/file-name-template.ts` | 同上 | 正则 `%VAR%`/`%VAR,k=v%` 解析重写 |
| `src/utils/unicode.ts` | — | Swift String grapheme 天然按字符切，Windows 保留名逻辑可删；`filenamified` 保留非法字符→`!` |
| `src/stores/settings.ts` + `constants/settings.ts` | `Core/Settings/SettingsStore.swift` | 结构照抄 V2，持久化改 `Application Support/settings.json` |
| `src-tauri/src/network.rs` | `Core/Networking/APIClient.swift` | reqwest 逻辑（代理三态）→ URLSessionConfiguration |
| `src/constants/routes.tsx` + `SideBar.tsx` | `Features/RootView.swift` | 四个页面：主页/下载管理/设置/关于 |

## 4. 协议细节（照抄上游，标注风险）

### 4.1 认证头
```
Authorization: Bearer <网页客户端 token，取自本仓库 src/twitter/api.ts 常量>
Cookie: <用户粘贴整串>        X-Csrf-Token: ct0 的值
Referer: https://x.com        User-Agent: 任意现代浏览器 UA
```

### 4.2 GraphQL 端点表（queryId 会随官网改版轮换 → 集中放 `QueryIds.swift`）

| 用途 | queryId | 关键 variables |
|---|---|---|
| UserByScreenName | `NimuplG1OB7Fd2btCLdBOw` | `screen_name` |
| UserMedia | `cEjpJXA15Ok78yO4TUQPeQ` | `userId, count=20, cursor, withV2Timeline:true` |
| UserTweets | `9zyyd1hebl7oNWIPdA8HRw` | 同上，`includePromotedContent:true` |

features JSON **必须全量照抄**源码（服务端校验严格，缺字段 400）。
解析路径：`data.user.result.timeline_v2.timeline.instructions[]`，取 `type==TimelineAddEntries` 的 `entries`；
推文在 `content.itemContent.tweet_results.result`，`__typename==TweetWithVisibilityResults` 时再取 `.tweet`；
**剔除**含 `legacy.retweeted_status_result` 的转推；**只留**有 `legacy.entities.media` 的；
下一页游标：`content.cursorType=="Bottom"` 的 `content.value`。
UserMedia 额外要处理 `TimelineTimelineModule`（profile-conversation 打包的多条）。

### 4.3 冒烟测试（M2 前先验证 queryId 是否仍有效）
```bash
# cookie 换成用户提供的；bearer 从 src/twitter/api.ts 里 grep 'Bearer' 拿
curl -s 'https://x.com/i/api/graphql/NimuplG1OB7Fd2btCLdBOw/UserByScreenName?variables=%7B%22screen_name%22%3A%22X%22%7D&features=<照抄api.ts>' \
  -H 'Authorization: Bearer <…>' -H 'Cookie: auth_token=…; ct0=…' -H 'X-Csrf-Token: …' | jq '.data.user.result.legacy.screen_name'
```

### 4.4 文件名模板（变量表 1:1 平移，语法 `%VAR%` 或 `%VAR,k=v%`）
`POST_ID`、`POST_TIME,d=1`、`USER_ID`、`USER_NAME`、`USER_SCREEN_NAME`、`MEDIA_ID`、`MEDIA_WIDTH`、`MEDIA_HEIGHT`、`MEDIA_INDEX`、`CONTENT,t=16`、`MEDIA_TYPE`、`EXT`、`TAGS`
默认模板：`%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%`
filenamify：非法字符 `<>:"/\|?*` 与控制符 → `!`。

### 4.5 下载引擎规格
- 并发 3，`URLSessionDownloadTask`，进度走 `urlSession(_:downloadTask:didWriteData:...)`
- 失败重试 5 次（沿用上游 `ariaRetryCountRemains` 语义）
- sameFileSkip：`FileManager.fileExists(解析后的 dir+fileName)`
- 代理三态照搬：`关闭`→`noProxy`（`connectionProxyDictionary=[:]`），`手动`→填 url，`系统`→`CFNetworkCopySystemProxySettings` 映射
- 暂停/恢复：cancel(producingResumeData) 持久化 resumeData；CDN 不支持 Range 时降级为重下

### 4.6 爬虫任务（CreationTask）
串行单队列；`while cursor != nil && lastPostDate > since`；每轮检查 `Task.isCancelled`；
统计 completeCount/skipCount；结束后 `UNUserNotificationCenter` 通知；完成后从队列移除（沿用上游行为）。

## 5. UI 规格（Liquid Glass，macOS 26）

- 骨架：`NavigationSplitView`，sidebar = 账户卡 + 四项导航；detail = 页面内容
- 玻璃用法（M1 起持续应用，M8 统一打磨）：
  - 浮层/工具条：`.glassEffect(.regular.interactive, in: .capsule)`
  - 相邻玻璃元素包 `GlassEffectContainer(spacing:)` 并用 `glassEffectID` 做 morphing
  - detail 内容顶到窗口边缘：`.backgroundExtensionEffect()`
  - 主/强调按钮：`.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`
- 主页网格：`LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)])`，卡片玻璃悬浮
- 统一组件：`GlassCard`（空态/错误态/信息卡共用）、间距 token 4/8/12/16/24、SF Symbols、跟随系统深浅色
- 签名以 SDK 头文件为准（M1 构建时校验，Apple WWDC25《Meet Liquid Glass》《Adopting Liquid Glass》为准绳）

## 6. 目标工程结构

```
XSpiderMac/
  project.yml                # xcodegen
  App/        XSpiderMacApp.swift  RootView.swift  Theme.swift
  Core/Networking   APIClient.swift  Proxy.swift
  Core/Twitter      QueryIds.swift  TwitterAPI.swift  Models.swift  MediaURL.swift
  Core/Download     DownloadEngine.swift  DownloadTask.swift  CreationTaskRunner.swift
  Core/Templates    FileNameTemplate.swift
  Core/Settings     SettingsStore.swift
  Features/  Home/  Downloads/  Settings/  About/
  Resources/  Assets.xcassets  Info.plist  XSpiderMac.entitlements  LICENSE 引用
  Tests/      TemplateTests.swift  TwitterParseTests.swift  MediaURLTests.swift
```

`project.yml` 骨架：
```yaml
name: XSpiderMac
options: { bundleIdPrefix: com.ledespo, deploymentTarget: { macOS: "26.0" } }
settings: { base: { SWIFT_VERSION: "6.0" } }
targets:
  XSpiderMac:
    type: application
    platform: macOS
    sources: [App, Core, Features, Resources]
    entitlements: { path: Resources/XSpiderMac.entitlements,
                    properties: { com.apple.security.network.client: true } }
  Tests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests]
    dependencies: [{ target: XSpiderMac }]
```

## 7. 里程碑（每步：做什么 / 调用什么 / 验收）

- **M0 仓库就绪（部分完成）**：上游完整历史已入库（master，领先上游 1 commit）；
  remote `upstream`→MiningCattiva/x-spider、`origin`→LeeDespo/x-spider-mac（URL 已配好）。
  **阻塞**：当前 gh token（fine-grained PAT）无 fork/建仓权限（API 403）。
  **人工步骤**：在浏览器打开 https://github.com/new ，名称填 `x-spider-mac`，Public，
  **不要**勾选 README/gitignore/license（本地已有完整历史）。建好后回到仓库目录执行：
  `cd /Users/mac/Documents/x-spider-mac && git push -u origin master`。
  备选：GitHub 上直接 fork MiningCattiva/x-spider 后 rename 为 x-spider-mac（会保留 fork 关系）。
- **M1 工程骨架**：`brew install xcodegen` → 写 `project.yml` → `xcodegen generate` →
  `export DEVELOPER_DIR=… && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac build`。
  验收：app 启动出现玻璃质感空窗口 + sidebar 骨架。
- **M2 网络层**：APIClient（Cookie/Bearer/UA/代理三态）+ §4.3 curl 冒烟验证 queryId。
  验收：单测通过 + 真实请求返回 200。
- **M3 模型与解析**：Models + TwitterAPI + 解析单测（用上游 api.ts 同款样本数据构造 fixture JSON）。
  验收：`xcodebuild test -scheme Tests -destination 'platform=macOS'` 全绿。
- **M4 主页 UI**：用户搜索 → 信息卡 → 媒体网格 → cursor 无限滚动 → 创建下载任务入口。
- **M5 下载引擎**：DownloadEngine（§4.5 全规格）+ 单测（模板/URL 规则）。
- **M6 下载管理 UI**：进行中/已完成/失败三 tab（对应上游 TabDownloading/Complete/Error），进度条 + 操作按钮。
- **M7 设置页**：代理三态、模板输入（变量选择器 + 示例预览，对齐上游 VariablePicker/TemplateExample）、保存目录（NSOpenPanel + bookmark）。
- **M8 玻璃打磨**：GlassEffectContainer/ID morphing、backgroundExtensionEffect、通知、Dock 进度徽标。
- **M9 发布**：`xcodebuild archive` → ad-hoc 或 Developer ID 导出 → `create-dmg`；更新 README。

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| queryId 轮换（上游已停维护） | 集中 `QueryIds.swift`；M2 冒烟；404/400 时提示更新并给出 grep 官网 js 的恢复步骤 |
| 未登录拿不到视频 variants | 引导必须 Cookie 登录（上游同样依赖） |
| features 缺字段 400 | 全量照抄，不精简 |
| cookie 过期 | 401 → 弹引导重新粘贴 |
| Liquid Glass API 细节偏差 | 以本机 SDK 头文件为准，M1 时校验签名 |
| GPL 合规 | 保持 GPL-3.0-only，README 注明 fork 来源与改动 |

## 9. 会话恢复清单（给未来的我）

1. `cd /Users/mac/Documents/x-spider-mac && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
2. 读本文件 §7 找当前里程碑；`git log --oneline -10` 看进度
3. 上游源码在本仓库 git 历史与 `src/` 目录（重写后保留在 git 历史）
4. 构建验证命令见 M1；提交用 conventional commits，只描述产品变更
