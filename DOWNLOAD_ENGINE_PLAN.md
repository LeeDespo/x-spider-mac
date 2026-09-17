# 下载引擎优化方案（损坏文件根因 · aria2 进程模型 · 限流协同）

> 读者：本项目 AI 代理（跨会话续接）。前置：分页/爬虫/限流缓解已提交（`4e5d3b4`…`8d00e7a`）。
> 约定：改 X API / 分页语义前先读 `src/`（上游），见 `AGENTS.md` 黄金法则。
> 本文所有结论都带代码位置，可直接核对。

---

## 0.0 实施状态（2026-09-17 更新）

**已实现并通过 76 项单元测试**（按本文 §8 的顺序落地）：

| 项 | 状态 | 落点 |
|---|---|---|
| §1 完整性校验（止血 0 字节文件） | ✅ | `Services/FileIntegrity.swift`（新建）+ `DownloadStore.finalizeDownload` + `Aria2Engine` 完成回调 |
| §5.3 记录与文件双向校验（自愈坏记录） | ✅ | `DownloadStore.recordEntryIsBackedByFile` / `purgeRecordEntry`；记录升级为 v2（含 `files` 映射，兼容 v1） |
| §2 临时文件命名统一 + 引擎切换丢弃断点 | ✅ | `tmpFileName` 唯一化、`legacyAria2FileName` 仅用于清旧残留、`discardPartialArtifacts`；`DownloadTask.engine` 记录实际引擎 |
| §6 CDN 与 GraphQL 分开的限流状态 | ✅ | `AccountStatusStore.cdnRateLimitedUntil` / `noteCDNRateLimited` / `probeCDN`；侧边栏两行 |
| §3 aria2 常驻 + RPC | ✅ | `Services/Aria2RPCClient.swift`（新建）；`Aria2Engine` 优先 RPC、失败自动回退子进程 |
| §4 引擎按大小分流 | ✅ | `DownloadStore.engineFor` / `estimatedSize`；`DownloadEngine.auto` |
| 用户补充：aria2 端口可配 | ✅ | `Aria2PortMode`（固定 6801 / 随机空闲端口）+ `Settings.aria2Port` |
| §6 CDN 自适应并发 + 指数退避 | ✅ | `pump()` 的 `effectiveMaxConcurrent()`；`handleTaskError` 指数退避 + 可重试判定 |
| 爬虫限流挂起（保 cursor） | ✅ | `CreationTaskStore.waitWhileThrottled` / `pageThrottle` 自适应 |
| §7 精简（拆分 DownloadStore 等） | ⬜ 未做 | 见 §7，可独立提交 |

**实测验证（不是推断）**：
- 用内置 aria2next 对不可达 URL 下载，**三次**都留下 0 字节文件，且**失败退出码不止一种：
  实测到 exit 1（未知错误）、exit 2（超时）、exit 3（资源未找到）都会留下 0 字节文件**；
- 成功路径实测：真实可达资源（经代理）下载得到 549 字节、exit 0、PNG 魔数正确；
- RPC 服务器可正常启动、`--rpc-secret` 鉴权生效（未授权调用返回 `Unauthorized`）；
- **`aria2.addUri` 确实支持 `dir`/`out`**：实测按参数创建了 `custom-dir/custom-name.jpg`；
- **完整 RPC 下载路径实测通过**（含代理）：`status=complete`、`completedLength=549`、
  文件按 `dir`/`out` 落入指定目录、内容为有效 PNG；
- `--conf-path=/dev/null` 生效（`getGlobalOption` 回读确认），不会被其它 aria2 安装的配置污染。

> 本机代理端口为 `127.0.0.1:12451`（用户提供）。aria2 不继承系统代理，应用侧由
> `Aria2Engine.systemProxy()` / 手动代理设置显式传递；上述 RPC 测试即经该代理完成。
> 实测确认应用的系统代理探测把本机解析为 `http://127.0.0.1:12451`，无需手动配置。

### 0.2 用户实际文件库的损坏审计（2026-09-17）

用代理跑通下载后，对已有媒体库做了一次实际审计（`~/Pictures/photo`）：

| 项 | 结果 |
|---|---|
| 下载历史记录任务 | 1246 条，全部 `complete` |
| 历史记录中标记完成但文件为 0 字节 | **0**（历史本身没有被污染） |
| 磁盘上的 0 字节媒体文件 | **130 个**（集中在 `いぬい_シオ-@inui_chien`） |
| 这 130 个是否在历史记录/下载记录里 | **都不在** |
| 每个 0 字节文件能否找到对应的正常文件 | **130/130 全部能找到**（1.3–1.9 MB，内容完好） |

**结论：这些不是"内容损坏"，而是旧版留下的临时文件残留，没有任何内容丢失。**

成因与 §2.1 描述的缺陷完全对应：旧版 aria2 临时文件名为 `<gid>-<原名>`（gid 是 UUID），
而清理逻辑删除的是另一个从未被创建的路径（`.xspider-tmp-<gid>-<原名>`），
于是每一次成功下载都会在用户目录里留下一个 0 字节的临时文件。130 个即 130 次下载的残留。

**本轮修复已从源头消除该现象**：临时文件名统一（`tmpFileName` 单一来源）、
成功路径 `finalizeDownload` 会把临时文件 rename 成正式文件（不再残留）、
失败路径 `cleanupFailedArtifacts` 主动删除半成品与控制文件。

**遗留垃圾处理**：130 个残留可安全删除（全部有正常对应文件）。因为删除文件不可逆，
未自动执行；如需清理，逐目录确认后删除形如
`^[0-9A-F]{8}-[0-9A-F]{4}-...-` 前缀且大小为 0 的文件即可。

---

## 0. 先把结论说清楚

你问的几件事，答案如下（细节见后文）：

| 你的疑问 | 结论 |
|---|---|
| 0 字节 / 损坏文件是怎么来的？ | **已实测复现**：aria2 下载失败时会留下 0 字节文件（实测 exit 1/2/3 都是这样），而 `Aria2Engine.swift:185` 把"文件存在"当作成功（尤其放行了 exit 1）→ 标记完成 + 写记录文件 + 永不重试。这是"某时间段文件成批坏、偶尔正常"的直接原因。**结论：修法是校验文件完整性，而非调整退出码白名单。** |
| 每个任务吊一个 aria2 子进程？ | 是（`Aria2Engine.swift:3`、`:110`）。这是**偏离上游**的设计。 |
| RPC 能否指定下载路径？ | **能**。`aria2.addUri([url], {dir, out})` 就支持，上游正是这么用的（`src/stores/download.ts:136-139`）。你担心的这点不成立。 |
| 常驻进程 vs 每任务子进程？ | **改为常驻 + RPC**，与上游一致。端口冲突可用"协商空闲端口 + `--conf-path=/dev/null` + 随机 secret"彻底解决（见 §3）。 |
| 小文件要不要用 aria2？ | **不要**。照片通常 <2MB，多连接无收益却有进程开销与失败面；`video/gif` 才是 aria2 的用武之地。方案是自动分流（见 §4）。 |
| 记录文件是成功后写吗？ | 是（`DownloadStore.swift:722`，仅在 `finalizeDownload`）。**但"成功"判定本身是错的**（见 §1），所以坏文件也会被记为已下载、并被 `sameFileSkip` 永久跳过。 |
| 引擎切换 / 暂停恢复会造成损坏吗？ | **会**，且是独立于上一条的第二个根因。见 §2。 |

---

## 1. P0 根因一：失败被当作成功（0 字节文件的直接来源）

### 1.0 实测复现（2026-09-17，本机）

用仓库内置的 `XSpiderMac/Resources/Binaries/aria2next` 直接对一个不可达 URL 下载，两次都复现了物证：

```
$ aria2next "https://pbs.twimg.com/media/NOPE_404.jpg" --dir=. --out=t.jpg \
    --continue=true --auto-file-renaming=false --allow-overwrite=true
（失败返回后）
$ ls -la
-rw-r--r--  1 mac staff  0 Sep 17 02:21 t.jpg     ← 0 字节文件被留下
```

放宽重试参数（`--max-tries=1`）拿到退出码后：

| 实测 | 遗留文件 | 当前代码判定（`Aria2Engine.swift:185`） |
|---|---|---|
| `exit=1` | 0 字节 | **SUCCESS** ← 标记完成 + 写下载记录 ⇒ **坏文件被固化** |
| `exit=2` | 0 字节 | FAILURE（正确，会重试） |
| `exit=3` | 0 字节 | FAILURE（正确，会重试） |

**结论一**：故障 URL 下 aria2 会先创建 0 字节输出文件再失败——这与你看到的"损坏/0 字节文件"完全对应。

**结论二（比原判断更重要）**：旧代码放行的是 `exit 0 || exit 1`，而实测 **exit 1/2/3 都会留下
0 字节文件**，其中只有 exit 1 被放行——也就是说这类损坏**不止一种触发码**。
**仅凭退出码判断"是否下载成功"从根上就不可靠**——真正的修复是**校验文件完整性**，
而不是继续调整退出码白名单。

### 证据

```swift
// Aria2Engine.swift:183-192
let status = process.terminationStatus
// exit 1 常见于极小文件：还没输出 summary 就下完了。只要目标文件存在就按成功收尾
if (status == 0 || status == 1) && FileManager.default.fileExists(atPath: destPath) {
    self?.completionHandler?(gid, .success(URL(fileURLWithPath: destPath)))
```

aria2 退出码语义：`0` 成功、`1` **未知错误**、`2` **超时**、`3` 资源未找到、`7` 暂停（优雅）、
`13` 文件已存在、`24` 认证失败。

`:185` 的注释假设"exit 1 常见于极小文件"，但它把判据从"下载完成"降级成了"文件存在"：

```
下载 → CDN 429/不可达 → aria2 建了 0 字节文件 → exit 1
     → fileExists == true → .success
     → finalizeDownload 标记 .complete（size = 0）
     → recordDownloaded 写入下载记录
     → 永不重试
```

这正解释了"限流/弱网那段时间文件成批损坏、偶尔几个正常"（少数真正下完的）。
更糟的是因为写进了记录文件，`sameFileSkip` 之后会**永远跳过**它们——损坏被固化。

### 修复

1. **不再以"文件存在"作为成功判据**，改为**完整性校验**（下条），退出码只用于决定
   "是否值得重试"与错误文案。
2. 新增统一落盘校验，作为两个引擎的共同出口：

```swift
/// 判定一次下载是否真的完成（两个引擎共用）
/// 1) 文件必须存在且大小 > 0
/// 2) 已知期望大小时必须完全相等（防"下了一半"被当完成）
/// 3) aria2 控制文件（.aria2）必须已消失——存在说明是中断态而非完成态
/// 4) 可选：图片类型校验文件头魔数（JPEG/PNG/GIF/WebP），成本极低且能挡住
///    "CDN 返回 HTML 错误页却 200"这类隐蔽损坏
private func verifyDownloadedFile(at path: String, expectedTotal: Int64, type: MediaType) -> Result<Int64, EngineError>
```

3. **失败要清理**：校验不通过时删除半成品与 `.aria2` 控制文件，再走既有
   `handleTaskError` 重试路径。不清理的话，下次 `--continue` 会读到脏状态。
4. 重审 `Aria2Engine.start()` 的预删除逻辑（`:122-127`）：

```swift
if !FileManager.default.fileExists(atPath: destPath + ".aria2") {
    try? FileManager.default.removeItem(atPath: destPath)
```

`--continue=true` 下"数据文件在、控制文件不在"会被 aria2 当作已完成（注释担心的"假完成"），
删除方向正确；但删除后必须让任务**从头开始并递减重试计数**，否则出现"文件没了但任务显示完成"。
第 2 步的校验能同时兜住两种情况。

**验收**：用不可达/会 429 的媒体 URL 建任务 → 必须进入 `.error` 或重试路径，
**不得**出现 `.complete`；`download-history.json` 与记录文件中不得出现该 media id。

---

## 2. P0 根因二：暂停/恢复与引擎切换造成的文件错配

这是独立于 §1 的第二条损坏路径，也是你"切换过几次引擎、暂停又恢复几次"的直接后果。

### 2.1 三种临时文件名并存，且记录与实际不符

| 函数 | 产出 | 实际用在哪 |
|---|---|---|
| `tmpFileName` (`:479`) | `.xspider-tmp-<gid>-<name>` | 只写进 `aria2StagingPaths[gid]`（**从未用于 aria2 实际写入**） |
| `aria2FileName` (`:487`) | `<gid>-<name>` | **这才是传给 `aria2.start(fileName:)` 的名字**（`:466`） |
| URLSession 分支 (`:797`) | `.xspider-tmp-urlsession-<uuid>` | 内置引擎 |

后果：`remove()` 按 `aria2StagingPaths` 删除时（`:544`）删的是**那个从未被创建过的路径**，真正的残留 `<gid>-<name>` 永远留在用户目录里；同时 `<gid>-<name>` **没有隐藏前缀**，会在用户的下载文件夹里显式可见。

**修复**：统一为一种临时命名（建议 `.xspider-tmp-<gid>-<原名>`，隐藏前缀 + 可反查任务），删除 `aria2FileName`；`remove`/`removeVisibleRecords`/`removeAll` 的清理列表由同一函数生成，避免三处各写一遍。

### 2.2 暂停/恢复与引擎切换交错时，断点数据与数据文件可能来自不同引擎

- 用内置引擎暂停 → 内存里存 `resumeDataMap[gid]`（`resumeData` 与 URLSession 的任务状态强绑定）；
- 切到 aria2 后恢复 → `launch()` 走 aria2 分支（`:419`），**完全忽略 `resumeDataMap`**，而 aria2 `--continue=true` 会去续写目录里可能残留的、来源不明的半成品；
- 反向切换同样会留下孤儿文件。

**修复**：
1. **暂停时记录引擎身份**（`DownloadTask` 增加 `engine: DownloadEngine?`）。
2. 恢复时若引擎已变更：**丢弃断点、清理半成品、从头下载**（并记一条日志说明原因）。宁可重下，不要拼出损坏文件。
3. 切换引擎设置时（`SettingsStore` 的 `engine` setter）**不打断进行中的任务**，但给它们打上"引擎已变更"标记，供恢复时判定。
4. `resumeDataMap` 加 TTL（如 24h）与体积上限，并持久化到 Application Support（现在只在内存，重启即丢，但半成品文件还在磁盘——同样错配）。

**验收**：对同一任务做"内置下载 30% → 暂停 → 切 aria2 → 恢复"，结果必须是**从头下载的完整文件**，且不产生孤儿文件。

---

## 3. 引擎进程模型：改为常驻 aria2 + RPC（与上游对齐）

### 3.1 上游怎么做的

`src/utils/aria2.ts:53-113`：启动**一个** aria2c 子进程，带 `--enable-rpc --rpc-secret <随机> --rpc-listen-port 6801`，然后走 WebSocket JSON-RPC 收发指令；任务通过 `aria2.addUri` 下发（`src/stores/download.ts:136-139`）：

```ts
const gid = await aria2.invoke('aria2.addUri', [task.downloadUrl], {
  dir: task.dir,          // ← 下载目录，RPC 完全支持
  out: task.fileName,     // ← 文件名
});
```

注意上游是 `system.multicall` 批量下发（`aria2.ts:245-254`），批量建任务只发一次请求。

### 3.2 为什么必须改（不只是"更优雅"）

当前"每任务一个子进程 + 解析 stdout 文本"的方案有三个硬伤：

1. **进度靠正则解析 stdout**（`Aria2Engine.swift:231-254`）。aria2 的 summary 用 `\r` 覆盖刷新，解析脆弱且无法区分"这一行是本次还是上次"；
2. **暂停靠 `SIGINT`**（`:259-267`）。这是"让进程自己保存控制文件再退出"的近似做法，时序上无法确认控制文件已完整落盘 → §1/§2 的损坏窗口；
3. **N 个任务 = N 个进程**，每个都重新解析代理、重复读配置，资源开销随并发放大。

RPC 模型直接消除这三点：`aria2.pause/unpause` 是**真正的暂停**（引擎内部维护控制文件，不存在 kill 竞态）；`aria2.tellStatus` 返回结构化进度；批量任务一次 multicall。

### 3.3 端口冲突与"其它 aria2 软件"的顾虑（你的疑问）

两处要防，且都能彻底解决：

1. **配置串扰**：aria2 默认会读 `~/.aria2/aria2.conf`。用户若装过别的 aria2 工具，其配置（RPC 端口、密钥、限速、目录）会**悄悄污染我们的实例**。→ 必须 `--conf-path=/dev/null`（同时用 `--no-conf` 更保险）。
2. **端口占用**：不要硬编码 6801（上游的写法，恰好最容易撞）。→ **协商空闲端口**：先 `bind` 一个随机端口拿到号再关闭，把它传给 `--rpc-listen-port`；万一仍被抢占，启动失败则顺延重试 3 次。

再加两道隔离：

- `--rpc-secret=<每次启动随机>`：即使别的程序连上端口，没有密钥也调不动；
- `--stop-with-process=<我们的 pid>`：App 退出时 aria2 自动收尾（这条现有代码已有，保留）。

RPC 通道建议用 **HTTP POST /jsonrpc**（`URLSession` 直接可用）而非 WebSocket：我们不需要服务端推送，用 1Hz 定时 `aria2.tellStatus`（multicall 批量）拉活跃任务进度即可，实现量和故障面都小得多。

### 3.4 目标形态（建议重构后的结构）

```
Services/Aria2Engine.swift        → 保留：二进制发现、系统代理探测（结果缓存）
Services/Aria2RPCClient.swift     → 新增：JSON-RPC 客户端（addUri/pause/unpause/tellStatus/
                                     remove/multicall/changeGlobalOption），含启动与健康检查
Services/DownloadEngine.swift     → 新增：协议，统一两个引擎的对外契约
  ├─ URLSessionEngine             （现有 DownloadDelegate 逻辑内聚进来）
  └─ Aria2Engine(RPC 版)
```

`DownloadStore` 只依赖 `DownloadEngine` 协议，不再出现 `if engine == .aria2` 分支散落各处。

**验收**：并发 5 个任务时 `pgrep aria2next` 只有 **1** 个进程；暂停/恢复不产生新进程；aria2 启动日志里能看到随机 secret 与协商端口；`~/.aria2/aria2.conf` 存在时也不影响行为。

---

## 4. 引擎选择策略：不是所有文件都该走 aria2

结论：**同意你的判断**——小文件不必用 aria2。

理由：aria2 的价值是**多连接分块**与**跨会话断点续传**，收益随文件增大而显现；照片通常 100KB–2MB，单连接即可跑满，多连接反而增加首字节延迟与握手开销，还多一层"进程/RPC 是否就绪"的失败面。

建议策略（做成设置项，默认"自动"）：

| 模式 | 行为 |
|---|---|
| **自动（默认）** | `photo` → 内置 URLSession；`video`/`gif`（有 `videoInfo.variants`）→ aria2。判据来自媒体自身类型，不依赖文件大小（省一次 HEAD 请求，也就省一次限流风险） |
| 始终内置 | 全部 URLSession（离线网络/极简环境） |
| 始终 aria2 | 全部走 aria2（保留现有行为偏好的用户） |

注意：**不要**为了判断"是否大文件"去发 HEAD 请求——`pbs.twimg.com`/`video.twimg.com` 也是要计配额的，而媒体类型在 GraphQL 解析阶段就已知（`TwitterMedia.type`）。

**验收**：自动模式下下载一张照片，`pgrep aria2next` 不新增进程；下载一个视频，走 aria2。

---

## 5. 下载记录文件（回答你的疑问 + 加固）

- **现状**：仅在 `finalizeDownload` 成功分支写入（`DownloadStore.swift:722`），符合"成功后记录"的预期；异步串行队列落盘（`:284`），并发安全。
- **上游根本没有记录文件**：上游只做 `fs.exists(filePath)`（`src/stores/download.ts:470`）。记录文件是 mac 侧新增的能力（好处：改文件名模板后仍能识别已下载）。这个增强是合理的，保留。
- **问题不在时机，而在"成功"的定义**（§1）。修好 §1，记录文件自然可信。

加固建议：

1. 记录写入前后做一次**同目录临时文件 + 原子替换**（现在是 `data.write(options: .atomic)`，已满足）。
2. 记录文件首次创建时机（`:271` 注释写"开始下载即创建"）与实现不符（实际在成功时才创建）——要么改注释，要么在前端 `hasDownloaded` 判定时容忍文件不存在（当前已容忍，改注释即可）。
3. **校验记录 + 文件的双向一致**：`sameFileSkip` 命中记录时，顺带确认目标文件确实存在且非 0 字节；不一致则以文件系统为准并清掉记录的该条目。这样即使历史上被写入过坏记录（§1 遗留），也能自愈。
4. 记录文件加一个版本字段（现在是裸 `{"downloaded": [...]}`），便于将来迁移。

---

## 6. 与限流缓解的协同（自适应调度）

### 6.1 职责边界先厘清

- **X GraphQL API**（`x.com/i/api`）→ 受 429 约束，由 `RequestGate` + 熔断管。
- **媒体 CDN**（`pbs.twimg.com` / `video.twimg.com`）→ 与 GraphQL 配额**不同域**，但同样会 429/403，且是下载失败的主要原因。

所以"缓解下载压力"要分两头：**爬取（GraphQL）降速** 与 **下载（CDN）降并发**。

### 6.2 建议：一个自适应策略对象，两个执行点

新增 `Stores/AdaptivePolicy.swift`（或并入 `AccountStatusStore`），对外只暴露"当前应处于哪一档"：

```swift
enum LoadLevel { case normal, cautious, halted }
// normal   : 用户配置的并发 / 爬虫 500ms
// cautious : 并发 = min(2, 配置) / 爬虫 1.5s
// halted   : 暂停爬虫；下载并发 = 1（已在飞的任务不打断）
```

判定完全复用 `AccountStatusStore.effectiveHealth`（**被动**，零额外请求）：

| 状态 | 档位 |
|---|---|
| `.normal` | normal |
| `.rateLimited` | **halted**（熔断期内不再产生新的 GraphQL 请求；下载降到 1） |
| `.timedOut` / `.offline` | halted（连不上就没必要继续排队，避免重试风暴） |
| `.unauthenticated` | halted（再爬也是 401） |
| `.serverError` | cautious |

**执行点一：`CreationTaskStore.runCreationTask`** —— 每轮翻页前检查档位：halted 则**挂起**（不是失败退出，保留 cursor 与进度），等状态恢复后自动继续；cautious 则把页间节流从 500ms 提到 1.5s。这与既有"游标停滞即判到底"的加固不冲突。

**执行点二：`DownloadStore.pump()`** —— 有效并发数改为 `min(用户配置, 档位上限)`，并在档位从 halted 回到 normal 时自动 `pump()` 唤醒被压住的 waiting 任务（否则会卡住直到下次用户操作）。

**另外两点**：
- **创建任务与下载互相让路**：CreationTaskStore 完成一批 `batchCreateDownloadTasks` 后，若当前有大量 active 下载，可短暂让出（现有 `pageThrottle` 已是 500ms，够用；不建议加更复杂的优先级）。
- **CDN 429 的退避**：`handleTaskError` 现在是固定 1s × 5 次（`:678`）。改为指数退避（1s/2s/4s/8s/16s），并对 403/404 这类**不可重试**错误直接终结（现在会白重试 5 次，放大限流）。

**验收**：人为触发 429（快速翻页）→ 侧边栏状态变红的同时，爬虫应停止产生新请求（日志无新 `UserMedia`），下载并发降为 1；状态恢复后爬虫自动续跑且**不丢 cursor**。

---

## 7. 精简与代码质量（可独立提交）

| 项 | 现状 | 建议 |
|---|---|---|
| `DownloadStore` 820 行 / 5 种职责 | 任务 CRUD + 引擎分发 + 记录文件 + 历史持久化 + 通知 | 拆：`DownloadStore`(CRUD/调度) + `DownloadRecordStore`(记录文件) + `DownloadHistoryStore`(持久化) + `DownloadNotifier`(通知) |
| 死代码 `DownloadStore.creationTasks`（`:17`） | 与 `CreationTaskStore.creationTasks` 重复，视图只用后者（`DownloadsView:16`） | 删除 |
| 三种临时文件名 | §2.1 | 收敛为一个函数 |
| `Aria2Engine.systemProxy()` | 每次 `launch` 都跑 CFNetwork，回退时还会 **spawn `scutil` 子进程**（`:83`） | 结果缓存 N 秒；代理设置变更时失效 |
| `waitUntilAllSettled`（`:749`） | 2s 轮询 | 改为 `AsyncStream`/continuation 唤醒；或保留但在注释里注明"仅关机前使用" |
| 进度解析 | 正则扫 stdout（`:231`） | RPC `tellStatus` 结构化字段（随 §3 一并消失） |
| 错误文案 | `EngineError` 两种 case，丢失 aria2 具体错误码 | 带上 aria2 errorCode（RPC 会返回），便于用户/日志定位 |
| 引擎分支散落 | `launch`/`pause`/`remove` 里各自 `if aria2` | 统一到 `DownloadEngine` 协议 |

---

## 8. 建议实施顺序（每步可独立验收）

1. **§1 完整性校验**（最高优先：直接止血损坏文件）。核心是"不再以文件存在作为成功判据"，
   改成"大小 > 0 + 期望大小匹配 + 控制文件已消失（+ 可选魔数校验）"。改动集中在
   `DownloadStore.finalizeDownload` 与 `Aria2Engine` 的完成回调，风险低、见效直接。
2. **§5.3 记录与文件双向校验**（自愈历史上已被固化的坏记录）。
3. **§2 临时文件命名统一 + 引擎切换丢弃断点**（消除第二条损坏路径）。
4. **§6 CDN 退避与创建任务挂起**（限流协同；不依赖 §3）。
5. **§3 aria2 常驻 + RPC**（结构性改造，收益最大也最需要实测）。
6. **§4 引擎自动分流**（依赖 §3 的协议抽象）。
7. **§7 精简**（随手做，不阻塞功能）。

第 5 步是唯一"大改"，建议单独分支 + 与第 1–4 步分开提交，便于回退。
第 1 步不应等待第 5 步——损坏是当前正在发生的问题。

---

## 9. 验证清单（改动下载相关后必做）

1. `xcodebuild … test` 全绿。
2. **损坏防护**：用一个会 429/404 的媒体 URL 建任务 → 必须失败重试，**不得**标记完成；`download-history.json` 与记录文件里不得出现它。
3. **记录自愈**：手工把一个已下载文件清空为 0 字节 → 下次同媒体应重新下载（而非被记录跳过）。
4. **引擎切换**：下载中暂停 → 切引擎 → 恢复 → 得到完整文件，目录内无 `<gid>-` 前缀孤儿文件。
5. **进程模型**（若已做 §3）：并发 5 任务时 `pgrep -f aria2next` 计数为 1；暂停/恢复不新增进程；`~/.aria2/aria2.conf` 存在时行为不变。
6. **限流协同**：触发 429 时观察日志——无新的 `UserMedia` 请求、下载并发降为 1；恢复后爬虫自动续跑且 cursor 连续。
7. 启动日志确认测的是本次构建（`executablePath`），避免重演"改了但跑的是旧构建"的误判（`docs/DEVELOPMENT.md` §2 开头）。
