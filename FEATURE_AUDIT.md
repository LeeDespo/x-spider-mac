# 上游功能对齐审计与移植设计

> 生成于 2026-09-11。基于上游 v2.2.2（MiningCattiva/x-spider）源码逐文件阅读。
> 目的：列出上游**全部**用户可见功能、上游实现方式、本仓库移植方案（放哪个页面、用什么 UI、怎么实现）。
> 结论先行：当前移植完成度约 **25%**，网络层只完成 getUser，列表/下载/模板/跳过/管理页均未接通。缺口清单见 §13。

---

## 1. Cookie 登录（账户卡）

**上游实现**（`components/Account.tsx` + `stores/app-state.ts` + `twitter/api.ts#getAccountInfo`）

- 侧边栏个人信息卡：未登录时显示"未登录 + 点击登录"；已登录显示头像 + screenName + 登出按钮
- 点击弹出 Modal 表单：**两个独立字段 `auth_token` 和 `ct0`**，附获取 Cookie 的说明链接
- 提交时拼接 `auth_token=xxx; ct0=xxx` → 调 `getAccountInfo(cookie)` **在线验证**（GET `https://x.com`，正则提取 `"screen_name":"..."` 和 `"profile_image_url_https":"..."`）→ 验证成功才保存 cookie 并关弹窗；失败弹"无法登录，请检查 Cookie 或代理配置是否正确"
- cookie 持久化到 `app-state.json`（zustand persist + Tauri 文件存储），重启保留
- app 启动时若已有 cookie，自动调 `getAccountInfo` 刷新账户显示；失败弹错误
- **登录前搜索框禁用**（placeholder 变为"请先登录后再搜索"）

**移植方案**

- 页面/位置：侧边栏 `SidebarView` 账户卡（已有位置）
- UI：点击账户卡弹 `.sheet` → `CookieImportView` 改为两个 `SecureField`（`auth_token`、`ct0`），附说明文字（如何在浏览器 DevTools → Application → Cookies 里找这两个值）；"验证并登录"按钮调 `TwitterAPI.getAccountInfo`，成功后 `AppStore.cookieString` 保存 + sheet 关闭 + 账户卡显示头像（`AsyncImage`）+ 昵称 + 登出按钮；失败显示红字错误
- 实现要点：
  - `AppStore` 增加 `accountInfo: TwitterAccountInfo?`，启动时若有 cookie 自动刷新
  - `getAccountInfo` 已有 Swift 版（`TwitterAPI.swift`），需接 UI + 错误分支（网络失败 vs cookie 无效）
  - 持久化已有（UserDefaults），可后续换成 JSON 文件与上游对齐

## 2. 用户搜索 + 搜索历史

**上游实现**（`pages/Homepage.tsx` + `stores/homepage.ts`）

- 输入 **screen_name（即 @handle，不是数字 ID）**，回车或点"加载"触发
- 流程：`clearUser + clearPostList` → `loadUser(sn)`（GraphQL `UserByScreenName` 拿 userId/头像/昵称/mediaCount）→ 成功后自动 `loadPostList()`（`UserMedia` 第一页）
- 搜索历史：持久化、小写去重、最新在前、显示为可点击链接列表、可一键清空；点击历史项直接重新搜索
- 未登录（cookie 为空）时输入框和按钮禁用
- 加载失败弹"加载失败，请检查用户 ID 是否正确"

**移植方案**

- 页面/位置：`HomeView` 顶部
- UI：搜索框（`.textFieldStyle(.roundedBorder)` + glass 容器）+ "加载"按钮；下方 `searchHistory` 以 capsule chips 显示（点击搜索、尾部"清空"）；未登录时 `.disabled(true)`
- 实现要点：
  - 新建 `HomepageStore`（`@Observable`，**不放 @State**，解决"切换页面丢输入"的 bug）：`keyword / userInfo / postList / cursor / filter / loading`
  - `AppStore` 增加 `searchHistory: [String]` + add/clear，UserDefaults 持久化
  - `TwitterAPI.getUser` 已有，需接 UI；错误映射成用户可读文案

## 3. 媒体网格浏览（无限滚动）

**上游实现**（`components/homepage/PostListGridView.tsx` + `InfiniteScroll.tsx`）

- 数据：`getUserMedias(userId, cursor, count=20)` 分页；返回 `{twitterPosts, cursor}`
- 展示：自适应网格（`minmax(12rem,1fr)`）铺缩略图（`media.url + ?format=jpg&name=small`），`loading="lazy"`
- 角标：视频显示时长（`mm:ss`，来自 `videoInfo.duration` 毫秒）；GIF 显示 "GIF"
- hover：黑色遮罩浮层 + 操作按钮：打开推文（外链 `x.com/{sn}/status/{postId}`）/ 下载图片 / 下载视频 / 下载 GIF（视频）——点击即创建单个下载任务，toast"已添加到下载队列"
- 无限滚动：滚到底自动 `loadMorePostList`；无 cursor 时显示"列表没有更多数据了"
- 首次加载显示"加载图片列表中..."

**移植方案**

- 页面/位置：`HomeView` 用户信息卡下方
- UI：`ScrollView` + `LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))])`；`AsyncImage`（缩略 URL 同上游 `?format=jpg&name=small`）+ `.aspectRatio(1, contentMode: .fill)`；视频时长/GIF 角标用 `.overlay(alignment: .bottomTrailing)`；hover（`onHover`）显示玻璃浮层按钮（打开推文 = `NSWorkspace.open`、下载 = 调 `DownloadStore.createDownloadTask`）
- 实现要点：
  - `getUserMedias` **必须新写**（§12 详见 GraphQL 细节），含 cursor 提取
  - 触底加载：`.onScrollGeometryChange` 监听 contentOffset 接近底部时 `loadMore`；`cursor == nil` 时显示"没有更多数据了"
  - 状态全在 `HomepageStore`，切页面不丢

## 4. 下载配置（筛选器）+ 批量下载入口

**上游实现**（`components/homepage/DownloadController.tsx`）

- 用户加载成功后显示"下载配置"卡片：
  - **日期范围** DatePicker（预设：至今/最近 7 天/15 天/1 个月/6 个月/1 年；不可选未来）
  - **媒体类型** checkbox（视频/照片/GIF，默认全选）
  - **下载源** radio（帖子 tweets / 媒体 medias，tooltip：帖子能下到更早推文但慢；媒体快但可能下不到很早的）
  - **开始下载**按钮 → `createCreationTask(user, filter)`，toast"已成功创建下载任务，请到下载管理页查看"
  - 校验：未加载用户/未选媒体类型时禁用并报错

**移植方案**

- 页面/位置：`HomeView`，用户信息卡和网格之间
- UI：`Form` 内一行：`DatePicker`（`...range` 样式 + 预设 Menu）、媒体类型 `Toggle`×3、下载源 `Picker(.segmented)`（附 help tooltip）、"开始下载" `.buttonStyle(.glassProminent)`
- 实现要点：`DownloadFilter` 模型已有（需补默认 `mediaTypes = [.photo,.video,.gif]`）；点击后调 `DownloadStore.createCreationTask`

## 5. 批量爬取任务（CreationTask）

**上游实现**（`stores/download.ts#runCreationTask + scheduleCreationTasks`）

- 创建任务：nanoid 生成 id + AbortController（可取消），入队 `creationTasks`（状态 waiting）
- 调度器：`requestIdleCallback` 轮询，同一时刻只跑一个 waiting 任务 → active
- 执行循环：`while (nextCursor !== null && now > since)`：
  - 按下载源选 `getUserMedias` / `getUserTweets`
  - 每页：过滤日期范围（until/since）→ 统计被过滤掉的媒体数为 skipCount
  - 每条推文的每个媒体：过滤媒体类型 → `prepareDownloadTask` 解析模板得到 dir/fileName → **`sameFileSkip` 开启且文件已存在 → skipCount++ 跳过** → 否则收集
  - 批量 `batchCreateDownloadTask`（aria2.addUri dir/out）→ completeCount += n
  - 每页更新 UI 进度；abort 随时生效
- 结束/失败：移除任务；失败发系统通知"爬虫任务运行失败"
- 下载管理页顶部显示"共 N 个任务创建中"：每条含用户（头像+昵称+@sn，点击跳主页）、已发送数、已跳过数（tooltip 解释跳过原因）、取消按钮

**移植方案**

- 页面/位置：逻辑放 `Services/CreationTaskRunner`（Swift `Task` + `Task.cancel()`）；UI 在 `DownloadsView` 顶部（见 §7）
- 实现要点：
  - `for await` 分页循环，`Task.isCancelled` 检查
  - `FileManager.default.fileExists(atPath:)` 实现 sameFileSkip
  - 失败 `UNUserNotificationCenter` 通知
  - `CreationTask` 模型已有，需补 `isRunning` 状态机

## 6. 下载引擎（aria2 → URLSession）

**上游实现**（`utils/aria2.ts` + `src-tauri/binaries/aria2c.exe`）

- 侧车进程 aria2c（RPC 6801 + secret），`aria2.addUri [url] {dir, out}` 建任务
- 操作：pause / unpause / pauseAll / unpauseAll / remove / removeDownloadTask（本地列表移除 + aria2.remove）
- 状态同步：500ms 轮询 `tellStatus` 在屏任务，合并 gid/status/completedLength/totalLength/fileName/errorMessage
- **错误自动重试**：`ariaRetryCountRemains=5`，error 时移除重建任务，重试耗尽才标 error + 应用内通知 + 系统通知（标题"任务下载失败"，正文=文件名+原因）
- 下载全部完成时（队列数从非 0 变 0）：通知"任务下载完成"

**移植方案**

- `Services/DownloadEngine`（已有骨架，需重写）：
  - `URLSession.downloadTask` + `URLSessionDownloadDelegate`：`didWriteData` 回调直接给进度（优于上游 500ms 轮询）、`didCompleteWithError` / `didFinishDownloading` 落盘
  - 暂停 = `task.cancel(byProducingResumeData:)`，恢复 = `downloadTask(withResumeData:)`
  - 模型调整：`DownloadTask` 瘦身（post/media 冗余存储改为轻量引用 + 需要的字段快照，否则 Codable 巨大）
  - 重试 5 次逻辑照搬；完成/失败通知用 `UNUserNotificationCenter`（需加 entitlement `com.apple.security.notifications.user-selected`… 实际用 usernotifications 无需额外沙盒权限，macOS 通知在系统设置里允许即可）
  - 并发控制：URLSession `configuration.httpMaximumConnectionsPerHost`，可顺带做全局"同时下载数"设置（上游依赖 aria2 默认）

## 7. 下载管理页（三 Tab + 任务列表）

**上游实现**（`pages/DownloadManagement` + `Tabs/DownloadList/DownloadListItem/CreationTasks`）

- 三个 Tab（带计数）：**下载中**（waiting/active/paused；排序 active>paused>waiting；批量：全部开始/全部暂停/删除全部）、**已完成**（complete；删除全部）、**失败**（error；重新下载全部/删除全部）
- 列表项卡片：
  - 左：缩略图（点击打开推文页）
  - 文件名（title 提示全名）
  - 用户行：头像+昵称+@sn（点击跳用户主页）
  - 操作按钮（按状态）：active→[暂停,删除]；paused→[继续,删除]；error→[重新下载,删除]；complete→[打开,打开目录,重新下载,删除]
  - 进度条（百分比）+ 状态文本（速度/已下载大小/总大小/错误信息）
  - 删除需确认对话框（"已下载的文件不会被删除"）
  - react-window 虚拟滚动（列表可能很大）
- 顶部 CreationTasks 区（见 §5）

**移植方案**

- 页面/位置：`DownloadsView`（现有空壳重写）
- UI：
  - 顶部 `Picker(.segmented)` 三 Tab（带 count badge）+ 右侧批量操作按钮（`glassEffect`）
  - `List` + 自定义 row（macOS List 自带虚拟化，无需 react-window 等价物）：缩略图 `AsyncImage`、文件名 `Text.lineLimit(1).help()`、用户行、`ProgressView(value:)`、状态文本（速度用 `ByteCountFormatter` + delta 计算）、操作按钮 `.buttonStyle(.borderless)` / 菜单
  - 删除用 `.confirmationDialog`
  - 打开文件/目录：`NSWorkspace.shared.open` / `activateFileViewerSelecting`
  - 外链：`NSWorkspace.open(URL)`
- 实现要点：`DownloadStore` 已有骨架，需接 `DownloadEngine` delegate 回调更新进度

## 8. 文件名 / 目录模板引擎（完整变量集）

**上游实现**（`constants/file-name-template.ts` + `utils/file-name-template.ts`）

13 个变量（`REPLACER_MAP`）：

| 变量 | 说明 | 参数 |
|---|---|---|
| `%POST_ID%` | 推文 ID | |
| `%POST_TIME%` | 推文发布日期 | `d`：0/1，=1 时仅日期 `YYYY-MM-DD`，否则 `YYYY-MM-DD HH-mm-ss`；无日期时输出"未知日期" |
| `%USER_ID%` | 用户 ID | |
| `%USER_NAME%` | 用户昵称 | |
| `%USER_SCREEN_NAME%` | 用户名 | |
| `%MEDIA_ID%` | 资源 ID | |
| `%MEDIA_WIDTH%` / `%MEDIA_HEIGHT%` | 宽/高 | |
| `%MEDIA_INDEX%` | 该媒体在推文中的序号（1 起） | |
| `%CONTENT%` | 推文内容 | `t`：截断长度（默认 16，非法时 32；unicodeSubstring 代理对安全截断） |
| `%MEDIA_TYPE%` | photo/video/animated_gif | |
| `%EXT%` | 扩展名（**从真实下载 URL 提取**，`split('.').last.split('?').head` 前置 `.`） | |
| `%TAGS%` | 推文 hashtag 逗号连接 | |

- 参数语法：`%VARIABLE,a=1,b=2%`
- 解析：正则 `%KEY((?:,[a-z]=.+?)+)?%` 全局替换；结果再过 `unicodeFilenamify`（替换 Windows 非法字符 `<>:"/\|?*` 和控制字符 + Windows 保留名 con/prn/aux/nul/com\d/lpt\d——**macOS 只需处理 `/` `:` 和控制字符**）
- 设置页配套：`VariablePicker`（可折叠"可用变量"列表，每项按钮显示 `%KEY% - 说明`，tooltip 列参数，**点击复制**）、`TemplateExample`（用内置示例数据实时渲染当前模板的输出预览）
- 目录模板用同一引擎（空模板 → 直接存保存根目录）
- 校验（Joi）：文件名模板不能空/不能含 `? * / \ < > : " |`；目录模板可空

**移植方案**

- `Services/FileNameTemplate.swift` **重写**：
  - 正则 `#%([A-Z_]+)((?:,[a-z]=[^,]+)+)?%#` 捕获 key+params
  - 13 个变量全覆盖（当前 Swift 版只有 15 个错误实现：MEDIA_INDEX 写死 "1"、EXT 不从 URL 提取、缺 TAGS/MEDIA_TYPE/CONTENT 截断/参数支持）
  - `makeSafeFileName` 只清 `/:` 与控制符
- 设置页 UI：`SettingsView` 下载 section 内嵌 `TemplateEditor` 组件：变量面板（`DisclosureGroup` 或 `Grid` 按钮，点击**插入到光标位置**而非仅复制）+ `TextField`（monospaced）+ 实时预览（`TemplateExample` 用上游同款示例数据）

## 9. 设置页（完整项）

**上游实现**（`pages/Settings.tsx`，即时保存：200ms debounce + Joi 校验 + 行内错误提示）

| Section | 项 |
|---|---|
| 下载 | 保存路径（只读输入 + "打开"按钮 + "选择路径"目录选择器）；文件夹模板（可空，说明：空则直接存保存路径）；文件名模板；跳过相同文件开关（说明：存在同名文件时是否跳过下载） |
| 代理 | 启用代理开关；使用系统代理开关（说明：代理未生效可能是代理软件没设系统代理，此时手动填）；代理地址输入（http URI 校验，例 `http://127.0.0.1:7890`） |
| 应用 | 自动检查更新；接收预览版（说明：更新频繁不稳定）；记录日志文件（说明：体积大，排障才开，需重启）；打开日志文件夹按钮 |

**移植方案**

- `SettingsView` 重写为 `Form` + 三个 Section（SwiftUI 原生即对齐上游布局）
- 保存路径：只读 `TextField` + "选择…"（`NSOpenPanel` `canChooseDirectories`）+ "打开"（`NSWorkspace`）；沙盒需 entitlement `user-selected.read-write`（已配置）+ 安全作用域书签（`NSOpenPanel` 返回的 URL 要 `startAccessingSecurityScopedResource`，**重启后仍能写**，当前缺失必须补）
- 模板两项用 §8 的 `TemplateEditor`
- 校验：路径模板 `^[^\\/:*?"<>|]+$`、代理 URL `^http://...`，错误红字显示在行下
- 持久化已有 `SettingsStore`；日志开关 + `Logger`（os.Logger 落文件可后补）

## 10. 代理与网络细节

**上游实现**

- `network_fetch`（Rust reqwest）：enable_proxy 时——useSystem=用系统代理（reqwest 默认）/ 否则手动 proxy_url；关闭则 `no_proxy`
- 系统代理探测：`network_get_system_proxy_url`（Rust 读系统设置）+ 前端轮询存 `systemProxyUrl`（设置页展示用）
- 重试：失败最多 **16 次**，指数退避 100ms 起、上限 16s
- 所有 GraphQL 请求带：`User-Agent`（前端浏览器 UA）、`Referer: https://x.com`、`Authorization: Bearer <公开 web token>`、`Cookie`、`X-Csrf-Token: ct0`

**移植方案**

- `NetworkClient`（已有）补齐：
  - `URLSessionConfiguration.default` 自动走系统代理（useSystem 分支天然满足）；手动代理设 `connectionProxyDictionary`；关闭设 `connectionProxyDictionary = [:]`
  - UA 用固定 Safari UA 字符串（上游 `navigator.userAgent` 的等价物）
  - 重试 16 次指数退避照搬
  - 系统代理探测：`CFNetworkCopySystemProxySettings` 读取展示
- Bearer token：上游写死在 `api.ts`（公开 web client token），Swift 侧同值常量（读源码时已被脱敏，实现时从上游仓库该行原样拷贝，不要改写）

## 11. 关于页 / 更新检查

**上游**：版本号、检查更新按钮（对比 latestVersion）、新版本链接、依赖列表、赞助区。

**移植方案**：`AboutView` 保留现有（版本、上游链接、GPL-3.0）；检查更新后补（Sparkle 2 或手动 GitHub Releases API 对比 tag），P2 优先级。

## 12. GraphQL 端点清单（照抄即可，含解析路径）

| 功能 | 端点 | queryId |
|---|---|---|
| 用户信息 | `UserByScreenName` | `NimuplG1OB7Fd2btCLdBOw` |
| 用户媒体 | `UserMedia` | `cEjpJXA15Ok78yO4TUQPeQ` |
| 用户推文 | `UserTweets` | `9zyyd1hebl7oNWIPdA8HRw` |

- features JSON 每个端点不同（源码 `api.ts` 逐字段照抄，勿合并）
- 解析路径：`data.user.result.timeline_v2.timeline.instructions[]` → `TimelineAddEntries.entries[]`
  - UserMedia：找 `TimelineTimelineModule`（`content.entryType`）→ `content.items[].item.itemContent.tweet_results.result`；或 `TimelineAddToModule.moduleItems`；`__typename == TweetWithVisibilityResults` 时取 `.tweet`
  - UserTweets：entries 里 `entryId` 以 `tweet` 开头取 `content.itemContent...`；`profile-conversation` 开头取 `content.items[]...`；**过滤转推**（`legacy.retweeted_status_result` 存在则丢）
  - Bottom cursor：`entries[].content.cursorType == "Bottom"` 的 `content.value`
- 推文字段映射：`rest_id / views.count / legacy.*（created_at 全文等）/ legacy.entities.media[] / legacy.entities.hashtags[] / core.user_results.result.*`
- 媒体映射：photo→`media_url_https`；video→`video_info.variants`（**取最高 bitrate 且有 url 的**）；gif→`variants[0].url`（上游 gif 只存单个 url，注意与 video 结构不同）
- 下载 URL：photo 加 `?name=orig`；video 取最高码率；gif 用 variants[0]

## 13. 当前移植缺口清单（按优先级）

| # | 缺口 | 影响 | 优先级 |
|---|---|---|---|
| 1 | `getUserMedias` / `getUserTweets` 未实现 | 主页网格完全没有数据 | P0 |
| 2 | HomeView 未接任何 store（@State 局部 → 切页丢状态；Fetch 按钮空实现） | 搜索完全不可用 | P0 |
| 3 | Cookie 表单不分字段、不验证、无登出、无账户信息展示 | 登录流程不可用 | P0 |
| 4 | 模板引擎变量/参数不全（MEDIA_INDEX 恒 1、EXT 不取真实扩展名、无 TAGS/MEDIA_TYPE/CONTENT 截断/参数语法） | 文件名/目录生成错误 | P0 |
| 5 | sameFileSkip 未实现 | 重复下载 | P0 |
| 6 | CreationTaskRunner 未实现 | 批量下载（核心场景）不可用 | P0 |
| 7 | DownloadEngine 未接 UI / delegate 进度 / resumeData / 重试 | 下载不可见不可控 | P0 |
| 8 | DownloadsView 三 Tab/列表项/操作/批量 未实现 | 下载管理不可用 | P0 |
| 9 | 设置页缺模板编辑器/变量面板/预览/校验/路径选择器(NSOpenPanel+安全书签) | 设置功能残缺 | P0 |
| 10 | 搜索历史、下载完成/失败通知、速度显示 | 体验缺失 | P1 |
| 11 | 系统代理探测展示、日志文件、更新检查 | 体验缺失 | P2 |
| 12 | 悬浮下载条当前是写死 3/12 假数据 | 误导（用户已报告）| P0（改成真数据或先移除）|

## 14. 页面 → 功能归属总表

| 页面 | 功能 |
|---|---|
| **侧边栏** | 账户卡（登录/登出/头像昵称） |
| **主页 Home** | 搜索框 + 搜索历史；用户信息卡（头像/昵称/@sn/媒体数，点击跳主页）；下载配置（日期范围/媒体类型/下载源/开始下载）；媒体网格（缩略图/角标/hover 操作/无限滚动/单个下载） |
| **下载管理 Downloads** | 创建中任务区（进度/跳过数/取消）；三 Tab（下载中/已完成/失败，计数）；任务列表（缩略图/文件名/用户/进度/速度/状态操作）；批量操作（全部开始/暂停/重下/删除） |
| **设置 Settings** | 下载（保存路径+安全书签/目录模板/文件名模板+变量面板+实时预览/跳过相同文件）；代理（开关×2/地址+校验）；应用（更新/预览版/日志/打开日志目录） |
| **关于 About** | 版本/上游链接/协议/（后补：检查更新） |

## 15. 实施顺序建议（下一轮开发）

1. **P0-网络补全**：`getUserMedias`/`getUserTweets` + 解析（§12）→ `HomepageStore` → HomeView 搜索+网格跑通
2. **P0-登录闭环**：Cookie 双字段表单 + 验证 + 账户卡真实数据 + 未登录禁用搜索
3. **P0-模板引擎重写**：13 变量+参数+安全文件名（附单元测试，用上游 `EXAMPLE_*` 示例数据做黄金用例）
4. **P0-下载闭环**：DownloadEngine（delegate 进度/resume/重试）+ DownloadStore 接线 + DownloadsView 三 Tab + sameFileSkip
5. **P0-批量爬取**：CreationTaskRunner + 下载管理页创建中任务区
6. **P0-设置页补全**：NSOpenPanel+安全作用域书签（沙盒写权限关键）、TemplateEditor、校验
7. **P1**：通知、速度、搜索历史 chips、移除假数据下载条（改真数据）
8. **P2**：更新检查、日志文件、系统代理展示
