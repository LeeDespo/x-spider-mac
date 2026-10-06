# 组件接入（x-spider-core）

> 外壳与组件的全部对接纪律：职责边界、唯一接口、错误码、部署与更新、版本账本。
> 请求形状 / 分页语义 / 错误码定义的**权威在组件仓库**：
> [LeeDespo/x-spider-core](https://github.com/LeeDespo/x-spider-core) 的
> `docs/07-API-REFERENCE.md`（各 method 入参/出参、数据形状、错误、可直接抄的时序）、
> `docs/CONTRACT.md`（契约与错误码）、`docs/02-X-DOMAIN-NOTES.md`（X 域实测事实与 fixtures）。
> 本仓库**不实现取数、下载或请求逻辑**（边界总纲见根目录 `../AGENTS.md`）。

## 1. 组件是什么、为什么

组件 `x-spider-core` 是 Rust sidecar 可执行文件 `xspiderd`（配 `aria2next` 下载引擎），
通过本地 JSON-RPC 对外服务。X 的请求（签名、限流闸门与 429 熔断、重试、queryId 自愈）、
写操作、下载引擎与爬取全部在组件里。

**为什么抽出去**：签名、请求闸门、queryId 自愈、下载引擎与断点/完整性校验，
这些若在每个平台外壳里各实现一遍必然漂移，而限流治理是这条链上最容易出事的地方。
组件同时被 CLI（第一个真实消费方）与其它平台复用。

### 能力对照：组件做什么，外壳只做什么

| 能力 | 组件（契约 method） | 外壳 |
|---|---|---|
| 用户 / 时间线 / 详情 / 搜索 / 关注 | `fetch.*` | `TwitterAPI` + `XSpiderMapping` 映射成 `TwitterPost` 等 |
| 写操作（赞 / 转推 / 书签 / 关注） | `fetch.mutate` | 映射 + 关注态缓存失效 |
| 登录校验 / 当前账号 | `auth.whoami` / `auth.set_cookie` | 登录流程调用；凭据**只进不出** |
| 限流 / 代理 / 探测 | `net.set_limits` / `net.set_proxy` / `net.status` / `net.probe_size` | 把设置推下去、读状态展示 |
| 下载 | `dl.enqueue` / `pause` / `resume` / `cancel` / `list` / `events` | 算目录与文件名、跳过判定、进度展示、收尾校验、写记录 |
| 爬取 | `crawl.run` | 分块驱动；产品语义（勾选/排除/精确日期/去重） |

外壳保留的只有三类：① 契约 JSON ↔ 应用模型的映射；② 产品语义（怎么命名、放哪、
勾了哪些、判断依据）；③ UI。凡是"数据怎么取、请求长什么样"的问题，**去看组件仓库**，
不要在外壳里发明默认值。

### 外壳不得重建的能力

以下能力已收进组件或已删除，**不要在外壳里重新实现**（历史上它们存在过，
`docs/history/x-endpoint-pitfalls.md` 留有叙事）：

- HTTP 客户端 / 重试退避、限流闸门、请求签名（`NetworkClient` / `RequestGate` /
  `XClientTransaction`）→ 组件；
- 下载引擎与 aria2 RPC 客户端、queryId 自愈（`Aria2Engine` / `Aria2RPCClient` /
  `SearchQueryIdProvider`）→ 组件；
- 评论发布输入框：从未实现且契约无对应写端点；
- 视频内嵌字幕选择：已随 1.0.0 移除（那是"内嵌字幕轨"，与实时翻译不是一回事）。

## 2. 接口：一个入口、版本握手，内务不外泄

- **唯一入口** `xspider_call(method, json) -> json`（sidecar 里是 `POST /` 加
  `X-XSpider-Token` 头）；另有 `system.version` 做握手。外壳侧唯一客户端是
  `Services/XSpiderComponent.swift`，**其他文件不得自建 sidecar 传输或直连本地 RPC**
  （`DownloadStore` 直调 `dl.enqueue` / `dl.resume`、`AccountStatusStore` 直调
  `net.status` 也经由它）。
- **契约主版本不匹配就拒绝启动**，不降级成"部分可用"
  （`XSpiderComponent.supportedContractMajor = "1"`，见 `XSpiderComponent.swift:37`
  与 `XSpiderComponent.swift:377` 的启动闸）。
- 契约里**不出**：端点路径、queryId、features 常量、HTTP 头、Rust 类型、签名细节。
  所以本仓库不该再看到它们——**不要仿上游在外壳发明取数逻辑**。
- 外壳持有的只有受限 JSON 值类型 `XSpiderJSON.JSONValue`（`Any` 不是 `Sendable`，
  跨 actor 会被 Swift 6 拒）。参数与结果就是契约里的 JSON，没有中间类型。
- **兼容口径**：运行时兼容只按契约**主版本**（真源是握手，不是文档）；
  长期文档**不写死组件 PATCH 版本**，随包组件的精确版本与哈希唯一归宿是
  `XSpiderMac/Resources/Binaries/components.lock.json`（见 §5）。

### 外壳侧调用纪律

- **首页必须省略 `cursor` 键**（不是传 `null`）——否则每页都请求第一页。
  映射层保证首页不传该键，翻页才传真实 cursor。
- `fetch.search_timeline` 外壳只传 6 个业务参数，其余（端点、queryId、features、HTTP 头）
  全在组件：

  | 参数 | 说明 |
  |---|---|
  | `screen_name` | 目标用户 |
  | `since` / `until` | **本地日历**日期、**含当天**（组件内部按排他语义 +1 天；外壳不要再加一天，见 `ARCHITECTURE.md` §5.1） |
  | `media_only` | 仅媒体 |
  | `count` | 每页条数 |
  | `cursor` | 翻页游标；**可选，首页省略该键** |

- **判断一律用结构化 `code`，不要匹配 `message` 文案**——组件与外壳都遵守这条。
  `TwitterAPI.translate` 把 `code` 翻成 `TwitterAPIError`，上层
  （`SyncStore.classify`、`DownloadStore.isRetryable`）再决定给用户什么提示。
- **取消语义由组件保证**（取消必须抛取消、不重试）。外壳侧下载失败按结构化
  `reason` / `status` 决定重试与 CDN 降并发（`DownloadStore.isRetryable`），
  只有 `isTransport` 值得重试。
- **评论区数据已由组件清过广告，外壳勿重复过滤**。

### 外壳会拿到哪些错误码（排障先看这个）

| 组件的 `code` | 什么情况 | 外壳翻成 |
|---|---|---|
| `not_found` | 用户 / 推文不存在 | `userNotFound` 或按上下文 |
| `unauthorized` | cookie 失效，或**账号被限制写操作**（上游 141） | `notAuthorized(原因)` → 提示"重新登录 / 换账号" |
| `rate_limited` | X 返回 429（带 `retry_after_s`） | 状态行显示限流；下载侧降并发 |
| `parse` | 响应结构与预期对不上——**"X 改版了"的信号** | `parseFailure` |
| `upstream` | 其它上游错误（带 HTTP `status`） | `responseError(status:)` |
| 传输 / 形状（无 `code`） | 组件没起来 / 超时 / 响应不是契约包络 | `transport` / `shape`；只有 `isTransport` 值得重试 |

### 限流与代理的外壳侧

限流治理本体（请求闸门、429 熔断、X API 与媒体 CDN 分开治理）在组件。外壳只需：

- 被动读 `net.status` 展示；用户点「重试」时主动探一次（`AccountStatusStore`）；
- **代理**：组件是独立进程，**不继承 macOS 系统代理**。"跟随系统"那一档由
  `SystemProxy.current()` 解析成具体 URL，经 `net.set_proxy` 告诉它；
  **改代理无需重启**（`null` = 明确关闭，与"字段缺失"语义不同）。

## 3. 组件从哪来、怎么部署 / 更新

### 查找顺序（`XSpiderComponent.searchDirectories()`，**外部目录优先**）

1. `~/Library/Application Support/moe.keli.xspider.mac/XSpiderCore/`
2. `~/Library/Application Support/XSpiderMac/XSpiderCore/`
3. `XSpiderMac.app/Contents/Resources/`（随包携带的兜底；仓库里是
   `XSpiderMac/Resources/Binaries/`）
4. 可执行文件所在目录（`Contents/MacOS`，开发时为构建产物旁）
5. `PATH`

目录里放**两个文件**即可：`xspiderd` 与 `aria2next`。
bundled 那份由 lock 记账（§5）；external 目录里的由用户自管，
运行时主版本握手兜底。

### 部署事故纪律（换外部组件必读）

**更新组件 = 换掉那两个文件 + 重新签名，不必重新构建应用**（这正是分进程形态的意义）。
两步都要做，漏了会被内核静默杀掉：

```bash
DIR=~/Library/Application\ Support/moe.keli.xspider.mac/XSpiderCore
xattr -cr "$DIR"                                             # 清隔离属性（从浏览器下载来的必做）
codesign --force --sign - "$DIR"/xspiderd "$DIR"/aria2next   # ad-hoc 签名
```

- **漏签 / 带隔离属性的典型表现**：文件在、却以**退出码 137** 静默被杀——
  `ready` 行永远不出现，只有一行日志。
- 因此设置页「组件状态」**绿灯的判据是进程真的起来并完成握手**，不是"文件存在"
  （文件在但被隔离会是假绿灯，所以刻意不这么判）。组件没起来会阻断一切取数与下载。
- **为什么不用 cdylib**：本机 hardened runtime 打开时 `dlopen` 任何 dylib 都会被
  library validation 拒，所以主形态是 sidecar（换组件 = 换一个二进制）。
- **用脚本换组件**：`script/update_components.sh`（§5）会自动完成下载校验、
  `xattr -cr`、签名、原子替换与 lock 回写；手工换二进制后跑
  `script/verify_components.sh` 对账。

### 排障：组件出问题时看什么

- **组件日志走 stderr**，被 `XSpiderComponent` 逐行转发到 `AppLogger`
  （分类 `CORE`，以 `组件: …` 前缀出现）。想看更细：设环境变量 `XSPIDER_LOG=debug`
  再启动（默认 `warn`）。日志观察手法见 `TESTING.md`。
- **改动没生效**先确认加载的是哪一份组件：启动日志会打
  `组件已就绪 … path=…`（外部目录优先，bundle 里的是兜底）。
- `ComponentError.transport` = 连不上 / 起不来；`notInstalled` = 没找到二进制；
  `shape` = 响应对不上契约（版本不匹配或找错了文件）；`contract` = 组件返回了结构化错误。
- **契约版本核对**：命令行跑 `xspiderd --version` 会打印
  `xspiderd <build> (契约版本 <contract>)`；应用要求主版本 `1.x`。

## 4. 版本账本：`components.lock.json`

`XSpiderMac/Resources/Binaries/components.lock.json` 记录**随包组件**的精确版本与哈希，
是"随包带了什么"的唯一真源。字段语义（lock 本体不加注释，语义在这里）：

| 字段 | 语义 |
|---|---|
| `sha256` | **随包二进制文件自身**的 sha256（`shasum -a 256` 该文件），不是 Release tar.gz 的——bundled 二进制与 Release 资产、core 本地构建三者**字节互异**，不能互引校验和 |
| `tag` / `asset` | **升级对账锚**（应来自哪个 Release 的哪个资产），不参与本机校验；下载期完整性由 Release 自带的 `.sha256` sidecar / 上游 checksums 文件负责 |
| `version` | 随包二进制的自报版本：xspiderd 取 `--version` 输出的 build 版本；aria2next 取二进制内嵌版本（上游 tag 佐证） |
| `contractMajor` | 随包 xspiderd 契约版本的**主版本段**（字符串，与 `supportedContractMajor` 同型）；**运行时兼容真源仍是握手**，lock 里的契约信息只作部署对账 |

- **写手唯一**：只有 `script/update_components.sh` 更新 lock
  （换二进制后重算 sha256 并按新 Release 回写 version/tag/asset）。
  **禁止手改 lock 与二进制不一致地提交**。
- `script/verify_components.sh` 做**纯校验**（不改任何文件）：lock 可解析、两二进制存在
  且为 arm64 Mach-O、可执行位、sha256 与 lock 一致、`--version` 可运行且契约主版本与
  lock 的 `contractMajor` 一致、lock 的 `contractMajor` 与 `XSpiderComponent.swift` 的
  `supportedContractMajor` 字面一致。任一失败 exit 1。调用方：`script/package_dmg.sh`
  （打包前置）、CI、人工换组件后。
- `script/update_components.sh xspiderd|aria2next [--tag vX.Y.Z]`：从组件仓库 /
  上游 Release 下载资产并用其校验文件核验 → 解包取二进制本体 → **`xattr -cr`**
  （漏了以退出码 137 静默被杀，此步在签名之前）→ `codesign --force --sign -`
  （ad-hoc）→ 原子替换进 `XSpiderMac/Resources/Binaries/` → 重算 sha256 回写 lock →
  收尾跑 verify。前置要求 `git status` 干净（二进制与 lock 必须同 commit 提交）；
  THIRD_PARTY_NOTICES.md 中对应条目的版本号随更新同步。

## 5. 当前对账状态（已知差异，待用户决策）

> 本节是**当前快照**（2026-10-07 建档）；精确数值以 lock 与各产物自报为准，
> 决策后请更新本节。

- **bundled xspiderd 的来历**：随包那份是 core v0.1.0 **定稿前的工作区构建**，
  与 GitHub Release v0.1.0 资产内、core 本地构建的产物**三者字节互异**
  （bundled 的契约 PATCH 落后于 core 现行，主版本同为 1、握手兼容）。
  三者的精确版本与哈希见 lock 与 core 侧产物自报。
  处置选项（openItem，**本次未自动替换**）：
  a) 维持现状仅记账（默认）；
  b) 用 core 本地构建产物替换（需先核验其校验和）；
  c) 等 core 重打 Release 后走 `script/update_components.sh` 升级。
- **aria2next**：随包为 2.7.5（上游 `AnInsomniacy/aria2-next`，GPL-2.0，
  许可证事实见根目录 `../THIRD_PARTY_NOTICES.md` 与 `../LICENSE.aria2`）；
  上游已有更新版本，升级走 `script/update_components.sh` 并同步 lock 与
  THIRD_PARTY_NOTICES（openItem）。
- **core 仓库侧遗留**：core 文档/注释尚有数处写"行为权威 = 外壳源码"的指针
  （上游源码已从本仓库移除后悬空），需在 core 仓库一轮改口（openItem，跨仓库）。
