# 推文详情浮层修复 + 限流状态提示 + 配额保护计划

> 读者：本项目 AI 代理（跨会话续接）。写法：每步含「做什么 / 改哪些文件 / 验收标准」。
> 前置：分页与爬虫修复已提交（`4e5d3b4`）。
> 约定：动手前先读 `AGENTS.md` 与 `docs/DEVELOPMENT.md`；改 X API/分页逻辑须对照 `src/` 上游源码。

---

## 0. 现状取证（已核实，勿重复确认）

| 事项 | 事实 |
|---|---|
| 详情浮层呈现路径 | **有两条**：① 全窗浮层 `ContentView.swift:45` ← `DetailOverlayCenter.open()`（主页时间线、搜索页网格双击走这条）；② `HomeView.swift:68` 的 `.sheet(item: $detailPost)`（搜索页"推文时间线"卡片点击走这条，是孤岛路径）。两条并存正是 UI 不一致与"写崩"的温床。 |
| 三卡布局 | `MediaDetailView.swift:45-57`：左媒体卡（弹性）+ 右列固定宽 410（推文卡固定高 260 + 评论卡弹性）。 |
| 关闭方式 | 只有两条：点击卡片外空白（`onTapGesture { close() }`）与 ESC。**没有可见的关闭按钮** —— 全屏浮层下用户找不到出口，这是"崩了"的主观来源之一。 |
| 媒体切换 | 三套并行：`ScrollWheelCatcher`（双指横滑）、`DragGesture(minimumDistance: 40)`（已在 `:145`）、左右箭头按钮（`:118-129`）。 |
| 日期显示 | `MediaDetailView.swift:239` 与 `HomeTimelineView.swift:108` 均为 `.dateTime.month().day()`（无年份）；`HomeView.swift:227` 的注册时间用 `.year()`；`SelectiveDownloadSheet.swift:108` 用 `.numeric`（含年）。 |
| 我引入的相关改动 | `HomepageStore.swift:261` 推文时间线用 `requireMedia: false` 放行**无媒体推文**进入列表；`MediaDetailView` 的 **mediaCard 对 `current == nil` 无任何占位**（`:100` 的 `if let media` 为空即只剩黑底）。**纯文字推文 → 媒体卡全黑 → 视觉上"三卡写崩"**。 |
| 429 现状 | 仅 `NetworkClient.swift:71-86` 局部退避 + 日志；**无全局状态、无 UI 提示、无跨请求配额治理**。429 异常在 `NetworkClient` 抛出 `NetworkError.httpStatus(429)`，是所有请求的**唯一汇聚点**（难得的单一采集口）。 |
| 侧边栏 | `SidebarView.swift:61-99` 账户卡：头像 + screenName + `@screenName`，点开花式 popover（已登录账户/添加账户/关注清单/登出）。**状态标签缺失**，`VStack(alignment:.leading, spacing:2)` 处是天然挂载位。 |

---

## 1. 修复详情三卡（P0，先做）

### 1.1 症状定性（先复现，再改）

"三卡写崩"至少含三个独立缺陷，须分别复现并逐一验收：

- **A. 纯文字推文 → 媒体卡空黑**（我引入的回归）。推文时间线点开无媒体推文时，`current == nil`，媒体卡只剩 `Color.black.opacity(0.65)` 底 + 空的下载胶囊，看起来像布局崩溃。
- **B. 两条呈现路径不一致**：`HomeView` 的 `.sheet` 走的不是全窗浮层，尺寸/背景/关闭语义都与主页不同，用户会觉得"搜索页的详情坏了"。
- **C. 无可见关闭按钮**，全屏浮层下只能盲点空白或按 ESC。

### 1.2 改法

1. **统一到单一路径**：删除 `HomeView.swift:68-75` 的 `.sheet(item: $detailPost)`，`detailPost` 改调 `DetailOverlayCenter.shared.open(post, mediaIndex:)`；`HomeView` 内 `detailPost` / `detailMediaIndex` 两个 `@State` 一并删除。`MediaDetailView` 只保留 `onClose`/`onSearchUser` 注入形式（`.sheet` 里 `@Environment(\.dismiss)` 的回退分支可留但不再被走）。
   验收：主页时间线、搜索页媒体网格、搜索页推文时间线三处点击，浮层外观与关闭行为完全一致。
2. **媒体卡空态**（修 A）：`mediaCard` 的 `if let media = current { … } else { … }` 补 else 分支——居中显示「该推文没有媒体」+ 图标（复用 `photo.on.rectangle.angled`），并**隐藏下载胶囊**（`medias.isEmpty` 时 `downloadCapsule` 不渲染）。同时三卡高度不再被空媒体卡撑成黑块。
   验收：点开纯文字推文，左卡显示空态文案而非黑屏；顶栏不再出现「下载全部(0)」。
3. **右上角圆形悬浮关闭按钮**（你的改进 1）：在 `MediaDetailView` 的**最外层** `HStack` 之上叠 `.overlay(alignment: .topTrailing)`，圆形玻璃按钮（`xmark`，36–40pt），`padding(22)` 与三卡留白对齐，`zIndex` 高于所有卡片，点击 `close()`。
   - 复用现有 `arrowButton` 的视觉语言（`Circle().fill(.black.opacity(0.45))`）或 `glassIconButton`；建议**新写** `closeButton` 走 `.liquidGlass(interactive: true)` 以贴合本项目风格。
   - 必须挂在最外层 overlay（不能挂在 mediaCard 内），否则右侧推文/评论卡区域点不到。
   - 保留 ESC 快捷键。鼠标悬停给 `.help(L("关闭"))`。
   验收：窗口任意大小、任意卡片上方都能看到并点到该按钮；点击后浮层退出且不触发卡片自身的 `onTapGesture`。
4. **媒体切换手势去重**（为你的改进 3 铺垫）：`ScrollWheelCatcher` 与 `DragGesture` 目前同时存在且都可能触发切换（`ScrollWheelCatcher` 的 `allowsHitTesting(false)` 只挡点击，不挡 scrollWheel 与 drag 竞争）。二者语义重复：
   - 触控板双指横滑 → 保留 `ScrollWheelCatcher`（这是你的改进 3 要强化的目标）；
   - 鼠标拖拽（`DragGesture`）→ 保留但提高阈值/或仅在 `mediaIndex` 有效时生效，避免与双指手势互相误触发；
   - 验收标准：连续双指左右滑**每次只切换一张**，不跳号、不重复触发。
5. **多媒体切换的真实缺陷检查**：`mediaIndex` 由 `post.medias` 初始，但 `loadReplies()` 完成后 `detail` 被赋值，`medias` 计算属性切到 `detail?.medias`。若二者数量/顺序不同，`mediaIndex` 会越界或错位（`current` 有 `indices.contains` 保护，但页码会显示错乱）。改为：`detail` 到达后若 `detail.medias.count != post.medias.count`，按 `media.id` 重新定位 `mediaIndex`。
   验收：切换媒体过程中评论加载完成，当前媒体不发生跳变。

---

## 2. 日期显示改为带年份（你的改进 2）

**需求**：详情卡、主页时间线卡、搜索页推文卡——**全部显示年**（现状只有月日）。

1. 抽一个统一的日期格式化入口（避免三处各写一遍、今后再漂移）。建议放 `Support/`（如 `Support/DateDisplay.swift`）或直接扩展 `TwitterDate`：

```swift
extension Date {
    /// 推文/媒体卡统一时间样式：yyyy年M月d日(本地化)
    var postDisplayText: String {
        formatted(.dateTime.year().month().day())
    }
}
```

2. 三个调用点替换：
   - `MediaDetailView.swift:239`（详情推文卡）
   - `HomeTimelineView.swift:108`（主页时间线卡）
   - `HomeView.swift` 的 `TimelinePostCard`（搜索页推文卡的作者行日期，现为 `.month().day()`）
3. **本地化注意**：`.formatted(.dateTime…)` 跟随 `Locale.current`，而本项目 UI 走 `L10n.language`（应用内三语切换，与系统语言可能不同）。验收时切换应用语言，确认日期随之变化（若要求严格跟随应用语言，需显式设 `.locale(Locale(identifier: ...))`，与 `L10n.language` 联动——**这一点必须先决定**，否则中英混排）。
4. 顺带核对 `SelectiveDownloadSheet.swift:108` 的 `.numeric`（已含年，保持或统一为上表样式）。
   验收：四处在中文/英文下均含年份，且无 `2026年9月16日` 与 `9/16/2026` 混排。

---

## 3. 双指左右滑切换媒体（你的改进 3）

`ScrollWheelCatcher` 已存在且已挂在媒体区（`MediaDetailView.swift:135-144`），但**当前实现有已知弱点**，需按下列条目加固后才能算"支持双指左右滑"：

1. **阈值与阻尼**：现为 `accumulated` 累积 + 42 阈值 + 300ms 冷却（`ScrollWheelCatcher.swift:33-38`）。触控板惯性滚动会让 `accumulated` 连续过阈值 → 连续跳多张。加**惯性判定**：`event.momentumPhase != []` 时只累积不触发；一次手势结束后重置 `accumulated`。
2. **手势边界行为**：`MediaDetailView.swift:137-142` 已在最后一张/第一张时静默忽略。可加轻微回弹（`.transition` + `offset` 动画）给用户"到头了"的反馈，非必需。
3. **与横向 ScrollView 冲突**：详情卡内若存在横向滚动（标签行 `:249-262`），`ScrollWheelCatcher` 挂在外层媒体区，标签行在其**右侧卡内**，不冲突；但需实测确认标签行横滑不会切媒体。
4. **双向一致性**：确认"自然滚动"方向语义正确（现 `direction = accumulated > 0 ? -1 : 1`）。做一张 5 图的推文实测：右滑→上一张、左滑→下一张（按 macOS 自然滚动直觉）。
   验收：5 图推文连续双指滑 4 次，逐张推进不跳号；到首/末张无越界；惯性滚动不误触发。

---

## 4. 账号状态提示（被动检测，你的第 4 项）

### 4.1 设计原则：被动、集中、零额外请求

**不主动探测**（不做定时 ping、不做预检请求），只在**真实操作遇阻**时记录，恢复正常时自动清除。这样没有额外配额消耗——这正是限流敏感场景下唯一正确的做法。

### 4.2 采集点：`NetworkClient` 是唯一汇聚口

所有 X 请求都经 `NetworkClient.request(...)`，且响应状态在此已明朗（`:71` 与 `:89`）。在此处埋一个**状态上报**即可覆盖全部路径，无需在每个 Store 里重复埋点。

```swift
// 新增 Support/AccountStatusStore.swift（@Observable @MainActor 单例）
enum AccountHealth: Equatable {
    case normal
    case rateLimited(until: Date?)   // 429
    case unauthenticated             // 401/403 cookie 失效
    case networkError(String)        // 超时/离线
    case serverError(Int)            // 5xx
}
```

**上报规则（关键：避免频繁刷新 UI）**：

| 事件 | 动作 |
|---|---|
| 成功响应（2xx） | 仅当当前状态 **非** `.normal` 时改写为 `.normal`（快路径：读一个 `if` 即返回，无分配、无动画） |
| 429 | 置 `.rateLimited(until:)`；`until` 取服务端 `Retry-After`，缺失则用 `now + 15min`（经验值，可配） |
| 401/403 | 置 `.unauthenticated`（提示重新导入 Cookie） |
| 5xx | 置 `.serverError`，下次成功自动清 |
| 取消（`CancellationError`） | **不上报**（这是用户操作，不是异常） |

**性能约束（明确提出并遵守）**：
- 上报是**主线程外的纯值写入** → 进入 `AccountHealthStore` 时用 `MainActor.run` 仅在**值真的变化**时写；用 `Equatable` 比较，相同则直接 return（避免 `@Observable` 触发无谓重绘）。
- **不写日志**（除状态迁移那一次），避免日志 I/O 成为热路径。
- 状态文案里的倒计时（"429 限流 · 12:34 后恢复"）若要做，用**单一** `TimelineView`/`Timer` 驱动标签自身，不驱动整棵侧边栏。

### 4.3 展示位置：侧边栏账户卡

`SidebarView.swift:72-86` 的 `VStack(alignment: .leading, spacing: 2)`，在 `@screenName` 下方插入状态标签（有状态时才渲染，`.normal` 时整个视图不出现 → 零布局成本）：

- 正常：不显示（保持现状的干净外观）。
- `.rateLimited`：红色胶囊「429 限流」+ 可选剩余时间；`.help` 里给完整说明（"X 短期访问过多，稍后自动恢复"）。
- `.unauthenticated`：橙色「登录失效」→ 点击直达 Cookie 导入（复用 `.openCookieImport` 通知）。
- `.networkError` / `.serverError`：黄色/灰色文案。
- 文案全部走 `L("…")` 并补 `L10n.swift` 三语表。

验收：① 手动构造 429（连续快速翻页触发）后标签变红；② 停止操作一段时间后再成功请求一次，标签自动消失；③ 状态不变时反复请求**不产生重复渲染**（可用 Instruments 或临时计数器验证）。

---

## 5. 避免触发限流：配额治理计划（你的第 5 项）

### 5.1 先明确约束

X 的 GraphQL 配额是**按账号+端点的时间窗**，现有代码已有四处节流（翻页 400ms、爬虫 500ms、429 退避、`maxRateLimitRetries=3`）。缺口不在"单次间隔"，而在**并发与总量无全局视图**。

### 5.2 建议改动（按收益/成本排序）

| 优先级 | 措施 | 说明 | 文件 |
|---|---|---|---|
| P0 | **全局请求闸门（令牌桶 + 单飞行）** | 所有 GraphQL 请求经一个 `RequestGate` actor：按端点分类（时间线/详情/互动/媒体），各类**串行**且共享令牌桶（如 10 请求/10s，可配）。消除"翻页循环 + 图片 + 详情 + 爬虫"叠加并发。这是最有效的一条。 | 新增 `Services/RequestGate.swift`，接入 `NetworkClient.request` |
| P0 | **429 全局熔断** | 收到 429 后，`RequestGate` 进入冷却：**该端点类别**在 `Retry-After`（或 15min）内直接短路返回 `.rateLimited`，不再发真实请求。避免"越限越试"。 | 同上 + `AccountStatusStore` |
| P1 | **详情浮层懒加载降级** | `MediaDetailView.task` 里同时发 `getTweet` + `getTweetReplies` 两个请求（`:416-421`）。改为：先发 `getTweet`，评论**滚动到可见或延迟 1s** 再拉；对同 `post.id` 做结果缓存，避免反复开合同一推文重复请求。 | `MediaDetailView.swift` |
| P1 | **图片请求与 API 分离计数** | 图片走 `pbs.twimg.com`，与 GraphQL 配额不同域，但会抢带宽造成超时误判。给 `ImageCache` 限并发（如 6），避免网格滚动瞬间并发几十个下载。 | `ImageCache.swift` |
| P1 | **爬虫自适应节流** | `CreationTaskStore` 固定 500ms。改为根据 `AccountStatusStore` 状态自适应：正常 500ms → 曾 429 则 1.5s 起并逐步退回。不设页数上限（保持上游语义），只调节奏。 | `CreationTaskStore.swift` |
| P2 | **可配置速率** | 设置页暴露"请求间隔/每日上限"（默认值即当前行为）。给用户自救手段。 | `SettingsView.swift` + `Settings.swift` |
| P2 | **配额用量可视化** | 若 P0 闸门记录了请求计数，可在设置页显示"今日 GraphQL 请求数"，帮助用户理解限流来源。 | `SettingsView.swift` |

### 5.3 明确不做（避免过度设计）

- 不做定时健康检查/预检请求（额外配额消耗，且与 §4 被动原则冲突）。
- 不引入第三方限流库（`RequestGate` 约 100 行可自足）。
- 不改变上游 GraphQL 参数语义（`queryId`/`features`/`variables` 一律不动，见 `AGENTS.md` 黄金法则）。

---

## 6. 验收清单（合并）

1. `xcodebuild … test` 全绿（现 28 项，新增日期/状态机/闸门单测）。
2. 三处入口（主页时间线 / 搜索媒体网格 / 搜索推文时间线）点击卡片 → 浮层外观一致、右上角有关闭按钮、ESC 可关。
3. 点开纯文字推文（推文时间线）→ 左卡显示空态文案，不是黑屏，无「下载全部(0)」。
4. 所有推文卡片日期含年份，且随应用语言切换而变。
5. 5 图推文：双指左右滑逐张切换、不跳号、到头停住、惯性不误触。
6. 触发 429 → 侧边栏账户卡出现红色「429 限流」；恢复后自动消失；期间不产生额外探测请求。
7. 用 `log stream --predicate 'process == "XSpiderMac"'` 观察：正常翻页请求间隔 ≥1s 量级，**无同一毫秒内的连续重试**（这是 `4e5d3b4` 修的回归点，勿再引入）。
8. 启动日志确认测试的是本次构建（`executablePath`），避免再次误判（见 `docs/DEVELOPMENT.md` §2 开头的教训）。

---

## 7. 建议实施顺序

1. §1 详情三卡修复（含关闭按钮、空态、路径统一）—— 用户可感知的回归，最先修。
2. §2 日期显示（改动小、独立）。
3. §3 双指手势加固。
4. §4 状态提示（依赖 §5 的 429 全局感知，但可先用 `NetworkClient` 单点上报跑通）。
5. §5 配额治理（P0 闸门 + 熔断优先，P1/P2 视情况）。
