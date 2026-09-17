# 瀑布流滚动修复 + 网络连接层审查方案

> 读者：本项目 AI 代理（跨会话续接）。前置：分页/爬虫/限流/下载均已修复（`4e5d3b4`…`23d8e44`）。
> **状态（2026-09-17 更新）**：A（回退 bug）、B（预取一屏）、C.1①（代理重建）、C.1③（重试预算/超时/失败可见）**已实施**；
> **C.1②（session invalidate）与 C.1④（异常状态 TTL）留待下次**。
> 所有结论带代码位置与实测数据，可直接核对。
>
> 三部分：**A** 瀑布流回退 bug（已定位到行）｜**B** 无缝加载（见解与方案）｜**C** 网络连接层审查。

---

# A. 瀑布流滚到底加载新内容时"退回前面"

## A.1 定位（已确认，是我上一轮引入的回归）

```swift
// HomeTimelineView.swift:96
.onChange(of: store.flatMediaSignature) { _, _ in
    waterfallVisibleCount = 40     // ← 每次数据变化都重置
}
```

```swift
// HomeTimelineStore.swift:50
var flatMediaSignature: String {
    "\(flatMedia.count)|\(first.media.id)|\(last.media.id)"   // ← 含 count
}
```

**根因**：指纹里包含 `flatMedia.count`，而"加载下一页"必然让 count 增长 → 指纹变化 →
`waterfallVisibleCount` 被重置回 40 → 已渲染的条目骤减 → **视觉上跳回前面**。

"位置貌似固定"也由此解释：无论滚到第几屏，重置后都退回**前 40 条**那个固定位置。

这个机制本意是"切换数据源时重置分批进度"，但判据选错了——**数据增长**与**数据源切换**是两件事，
前者不该重置。

## A.2 修复方案

判据从"内容变了"改为"**数据源身份变了**"：

```swift
// 方案：给 store 一个数据源代际标识，只在"换了一批数据"时递增
// —— mode 切换、followingSort 切换、reload 完成 → generation += 1
// —— loadMore 追加 → 不递增
@ObservationIgnored private(set) var sourceGeneration = 0
```

视图侧改为 `onChange(of: store.sourceGeneration) { waterfallVisibleCount = 40 }`。

要点：
1. **追加不重置**：`loadMore` 只 append，不动 `sourceGeneration`；
2. **切换必重置**：`setMode` / `setFollowingSort` / `reload` 结束时 `sourceGeneration += 1`；
3. **重置时机**：重置后应立即补足视口（否则用户看到的是"回到 40 条但没继续填"），
   复用 `advanceIfVisible` 的同一套推进逻辑即可。

替代方案（更简单但有副作用）：干脆不重置 `waterfallVisibleCount`，让它只增不减。
数据源变少时 `prefix(count)` 会自动截断到实际数量，不会越界。
**代价**：切换数据源后已展开的条目数会沿用（比如切到只有 20 条的列表，计数器仍是 200，
但 `prefix` 截断为 20 → 无害）。这个方案更少状态、更少出错面，**推荐优先考虑**。

---

# B. 无缝加载（见解与方案）

当前"分批渲染 + 触底加载"会让人感到卡顿，原因不是网络，而是**两段串行的等待**：
先等 `waterfallVisibleCount += 40` 的布局（非 lazy 布局要测量 40 个新单元），
再等 `loadMore()` 的网络往返。用户滚到底时两者都还没发生。

三种做法，按推荐度排序：

| 方案 | 做法 | 效果 | 成本 |
|---|---|---|---|
| **① 预取下一屏（推荐）** | 哨兵位置提前判定：当已渲染内容底部距视口还有**一屏**时就触发推进（现在是一进入视口才触发） | 用户滚到时数据已就绪，视觉上无缝 | 极低：只改阈值（`sentinelMaxY <= viewportHeight * 2`） |
| ② 网络与渲染并行 | 触底时同时发起 `loadMore()` 与展开本地批次，不等网络 | 减少一轮串行等待 | 低：把两个操作并行发起即可 |
| ③ 缩略图预取 | 对"即将进入视口"的下一批媒体提前请求缩略图 | 滚动时图片已就位，无白块 | 中：需与 `ImageCache` 协作，注意别抢带宽 |

**我的建议：先做 ①，它与上游 `InfiniteScroll` 的阈值语义一致**（上游 `threshold` 默认取
`clientHeight`，即提前一屏开始补），属于"回归上游语义"而非发明新机制。②③ 视实测再定。

注意：① 的提前量必须**只提前一屏**，不能更大。本项目已有教训——无节制的连续补拉会触发 429
（`docs/DEVELOPMENT.md` P0-A、`AGENTS.md` 大坑 3）。

---

---

# C. 网络连接层审查（代理与断连判定）

## C.1 你描述的症状 → 多个独立根因叠加

> 实施状态：① 与 ③ 已完成；② 与 ④ 待做（见下方各自标注）。

你的体验是"代理波动 → X 断连 → 代理恢复后应用仍显示断连很久，重试/重设都没用，
除非重启应用"。审查后确认这**不是一个 bug，而是三个叠加**，每个都独立成立：

### 根因 ①：改代理设置**完全不会**重建网络客户端（最严重）✅ 已实施

```swift
// AppStore.swift:11-14 —— 只有 cookie 变化才触发 configure
var cookieString: String = "" {
    didSet {
        UserDefaults.standard.set(cookieString, forKey: "app.cookieString")
        Task { await TwitterAPI.shared.configure(cookie: cookieString, proxy: SettingsStore.shared.settings.proxy) }
    }
}
```

全仓库搜索 `.configure(cookie` 只有这一处调用。而 `SettingsStore.save()`（设置持久化路径）
只做三件事：写 UserDefaults、应用语言、同步限流闸门——**没有任何通知网络层的动作**。

**后果**：在设置里改代理地址/开关/系统代理，`TwitterAPI.client` 仍持**旧配置的 URLSession**。
你在 UI 上"重新设置"代理，对已运行的网络栈毫无影响 → 正是"无论怎么重设都没用"。

**修复方案**：代理设置变更必须重建 client。推荐做法——在 `SettingsStore` 增加一个
"代理配置指纹"，变化时调用 `TwitterAPI.configure`（复用 cookie 那条路径）：

```swift
// SettingsStore
private var lastAppliedProxyFingerprint: String?
private func applyProxyIfChanged() {
    let fp = "\(settings.proxy.enable)|\(settings.proxy.useSystem)|\(settings.proxy.url)|\(settings.proxy.username ?? "")"
    guard fp != lastAppliedProxyFingerprint else { return }   // 幂等，避免无谓重建
    lastAppliedProxyFingerprint = fp
    Task { await TwitterAPI.shared.configure(cookie: AppStore.shared.cookieString, proxy: settings.proxy) }
}
```
在 `save()` 里调用它（与 `applyRateLimit()` 并列）。

### 根因 ②：URLSession 从不 invalidate → 旧连接池与失效连接被长期持有 ⬜ 待实施

```swift
// TwitterAPI.swift:19-24
func configure(cookie: String, proxy: ProxySettings) async {
    self.client = NetworkClient(proxy: proxy)   // ← 旧 client 直接丢弃
    ...
}
```
`NetworkClient` 的 `session` 是 `URLSession(configuration:)`，**引用被丢弃但从未
`invalidateAndCancel()`**。后果：

- 旧的 HTTP/2 连接池不会被主动关闭；代理切换后，已建立的 TCP/TLS 连接可能仍指向
  **已经不存在的代理路径**，这些连接会在超时前一直"挂着"；
- 每次 configure 泄漏一个 session。

**修复方案**：`NetworkClient` 增加 `func invalidate()`（内部 `session.invalidateAndCancel()`），
`configure` 里在替换前调用旧 client 的 invalidate。另外让 `NetworkClient` 成为
`deinit { session.invalidateAndCancel() }` 的持有者，保证不遗漏。

### 根因 ③：重试预算过大 → "加载到永远"，且期间无法恢复 ✅ 已实施

实测量化（`maxRetryCount = 16`、`maxRetryDelay = 16`、单次请求超时用系统默认 60s）：

```
16 次退避累计等待: 153.5s
最坏总耗时 ≈ 16 × 60s + 153.5s ≈ 1114s ≈ 19 分钟
```

**这就是"加载到永远、也不显示失败"的原因**——不是 UI 不刷新，而是**底层还没放弃**。
`loading` 状态由 `defer { loading = false }` 兜底，理论上最终会复位，但要等最多 19 分钟，
用户根本等不到。

更糟的是它**阻塞恢复**：代理恢复后，正在进行的那个请求仍在它的重试循环里（可能处于
16 秒退避中），新请求又要排队挤过同一个 `RequestGate`（同类串行），导致"恢复后还要等很久"。

**修复方案**（三层，建议全做）：

1. **给重试设总预算**：把"最多 16 次"改为"**最多 N 次 或 总耗时 ≤ T**"（建议 T = 20–30s）。
   上游是浏览器环境（fetch 有天然超时），Swift 侧照搬 16 次不合理。
2. **显式设置 URLSession 超时**：`timeoutIntervalForRequest = 15`、
   `timeoutIntervalForResource = 60`，别依赖 60s/7天 的系统默认。

   > 补充（核对代码后的精确结论）：`requestInternal` 里 `withTimeout` **只在传了 `timeout`
   > 时才启用**，而 `timeout` 只有 `requestFast`（同步页）会传——
   > **主页时间线、翻页、爬虫这些主路径全程没有任何超时**，`request.timeoutInterval` 也没设，
   > 完全依赖 `URLSessionConfiguration.default` 的系统默认值。所以 19 分钟是**下限**，
   > 实际可能更久（resource 超时默认 7 天）。
3. **失败要可见**：`HomeTimelineStore.reload` 失败时目前只写日志
   （`AppLogger.warn("主页时间线加载失败")`），**不设置任何 UI 状态** → 用户看到空白/一直加载。
   应增加 `loadError` 状态并在视图显示"加载失败，点击重试"。
   （`HomepageStore` 已有 `postListError` 可参考，主页时间线缺这个。）

### 根因 ④（附加）：熔断/异常状态没有自动解除路径 ⬜ 待实施

`RequestGate.resetBreakers()` 只在两处调用：用户点侧边栏重试、设置页「立即恢复」。
`AccountStatusStore` 的 `offline` / `timedOut` 状态**只能靠"下一次请求成功"来清除**——
但网络已断时不会有成功的请求，形成死锁；而 `waitWhileThrottled` 的爬虫挂起又依赖这个状态。

**修复方案**：给异常状态加**到期自动重试**（不是主动轮询，而是"状态过期即视为可重试"）：
- `offline`/`timedOut` 状态设 TTL（建议 30s），到期后允许下一次请求真的发出去；
- 或更简单：`effectiveHealth` 对 `offline`/`timedOut` 做 TTL 判定，超时即回 `.normal`，
  让用户的下一次操作不再被挂起逻辑挡住。

这与已有设计一致——`rateLimited` 就是用 `until` 到期判定的，`offline`/`timedOut` 当时漏了。

## C.2 精简与结构问题

| 项 | 现状 | 建议 |
|---|---|---|
| 三个 store 各自持有代理状态 | `SettingsStore.settings.proxy` 被 `TwitterAPI`、`DownloadStore`、`Aria2Engine` 分别读取 | 代理变更集中到一个"配置应用"入口（见 C.1①），三方共用一个通知点 |
| `NetworkClient` 每次 configure 新建 | 泄漏 session（C.1②） | 加 `invalidate()` + `deinit` |
| `requestInternal` 的 timeout 分支 | `withTimeout` 包一层，但 `request.timeoutInterval` 也设了 → 双重超时语义重叠 | 只用 `timeoutInterval`，删掉多余的 `withTimeout` 包装（少一层竞速 task） |
| `NetworkError` | 只有 `unknown` / `httpStatus` | 补 `timedOut` / `offline` / `proxyFailure`，便于状态分类与文案（现在靠字符串匹配 `message.contains("429")`，脆弱） |
| `probeConnection` | 走 `getAccountInfo(fast:)`（抓首页 HTML） | 可接受（复用登录验证），但注意它依赖 `x.com` 首页可解析；若失败应能区分"连不上"与"页面结构变了" |
| 重试日志 | 每次重试都 `AppLogger.warn` | 16 次重试会刷 16 行；降为 debug（首末次 warn） |

## C.3 建议实施顺序

1. **C.1① 代理变更重建 client** —— 直接解决"重设代理无效"，改动最小、收益最大；
2. **C.1③ 重试总预算 + 显式超时 + 失败可见** —— 解决"加载到永远"，让用户能自助重试；
3. **C.1② session invalidate** —— 消除连接池泄漏与陈旧连接；
4. **C.1④ 异常状态 TTL** —— 消除恢复死锁；
5. **C.2 精简** —— 随手做。

## C.4 验收标准

1. 代理软件断开 → 状态显示断连；**代理恢复后 30 秒内**（不是 19 分钟）状态自动转正常，
   或点一次重试立即正常；
2. 在设置里改代理地址 → **无需重启**，下一个请求即走新代理；
3. 断网时主页时间线应在约 20–30 秒内显示"加载失败 + 重试"按钮，而非无限转圈；
4. 断网→恢复过程中，应用不再需要重启；
5. `log stream` 中单次逻辑请求的 NET 日志不超过约 20–30 秒窗口。

---

---

# D. 附：本轮实测数据（供核对）

| 测量 | 结果 |
|---|---|
| 代理 `127.0.0.1:12451` 对 `x.com` 成功率 | 约 6/10 |
| 代理对 `pbs.twimg.com` 成功率 | 约 7/10 |
| aria2 经不稳定代理下载（带 `--max-tries=5`） | 最终成功 457864 字节，JPEG 魔数正确，exit 0 |
| 失败时残留文件 | 0 字节（exit 1/2/3 均如此，已由 `FileIntegrity` 拦下） |
| 16 次重试最坏耗时 | 约 1114 秒（19 分钟） |
