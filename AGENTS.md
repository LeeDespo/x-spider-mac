# AGENTS.md — x-spider-mac

## 项目定位

**XSpiderMac** 是面向 macOS 的原生 SwiftUI X（Twitter）媒体客户端。当前代码、架构与构建链均独立维护。

应用侧只负责：
- SwiftUI / AppKit 界面与交互；
- `x-spider-core` 契约 JSON ↔ Swift 应用模型的映射；
- 产品语义、设置、本地缓存、下载/同步记录与展示；
- `xspiderd` 的启动、握手、版本展示与错误呈现。

**X 数据访问不属于本仓库。** 请求构造、GraphQL、端点路径、queryId / features、签名、分页解析、上游响应归一化、限流 / 429、爬取和下载引擎全部由 [x-spider-core](https://github.com/LeeDespo/x-spider-core) 负责。

项目早期参考过已停止维护的 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)。它现在只作为历史来源 / 致谢存在，**不是本仓库的实现或行为真源**；不要为了核对 X 端点行为去读、复制或恢复它的源码。相关考古若仍有价值，应在 core 仓库维护。

## 真源与边界

| 问题 | 真源 |
|---|---|
| X 数据怎么取、请求怎么构造、响应怎么解析 | `x-spider-core` 的契约、实现、fixture 与测试 |
| core 对外接口、字段、错误码 | `x-spider-core/docs/CONTRACT.md`、`docs/07-API-REFERENCE.md` |
| 契约 JSON → Swift 模型 | `XSpiderMac/Sources/XSpiderMac/Services/XSpiderMapping.swift` |
| 组件进程启动 / 握手 / 调用 | `Services/XSpiderComponent.swift` 与应用侧 API facade |
| UI / 产品语义 | 本仓库现役 Store / View / Model + `docs/DEVELOPMENT.md` |
| 下载 / 同步记录 | `MEDIA_RECORDS.md` |
| 组件部署、查找顺序、随包版本账本 | `docs/COMPONENTS.md` |
| 测试、live 验收、验证清单 | `docs/TESTING.md` |
| 发布 / Tag / DMG / checksum | `docs/RELEASING.md` |
| 设置默认值 | `SETTINGS_DEFAULTS.md` |
| 工程文件 | `XSpiderMac/project.yml`（`.xcodeproj` 由 xcodegen 生成、不入库） |

### 不要越过的边界

1. **不要在本仓库研究或实现 X 端点行为。** 一旦问题定位到请求、分页、原始响应、queryId/features、限流等，去 core 修；mac 只消费修正后的契约结果。
2. **不要新增直连 X 的 HTTP / 下载旁路。** 取数、写操作、爬取与下载全部经 `x-spider-core`。
3. **不要复制 core 的行为知识到 mac 文档。** mac 文档只记录契约如何消费、产品如何呈现和本地状态如何维护。
4. **不要把组件版本号写死在文档。** 实际版本以 `system.version` 握手和所用 Release 为准；随包二进制的精确版本与 SHA256 以 `XSpiderMac/Resources/Binaries/components.lock.json` 为准。
5. **不要把历史参考项目重新 vendor 进仓库。**

## 目录速览

| 路径 | 内容 |
|---|---|
| `XSpiderMac/Sources/XSpiderMac/Models/` | 应用模型 |
| `XSpiderMac/Sources/XSpiderMac/Services/` | core 契约客户端、映射、本地记录 / 判定服务 |
| `XSpiderMac/Sources/XSpiderMac/Stores/` | 应用状态与产品流程 |
| `XSpiderMac/Sources/XSpiderMac/Views/` | SwiftUI / AppKit 界面 |
| `XSpiderMac/Sources/XSpiderMac/Support/` | 缓存、日志、导航、窗口等基础设施 |
| `XSpiderMac/Tests/XSpiderMacTests/` | 应用侧单元 / 接线测试 |
| `docs/` | DEVELOPMENT（手册）、COMPONENTS（组件部署与账本）、TESTING（测试与验收）、RELEASING（发布）、history/（仅历史来源） |
| `MEDIA_RECORDS.md` | 下载 / 同步记录真源 |
| `SETTINGS_DEFAULTS.md` | 设置默认值真源 |
| `script/` | 构建与打包脚本 |

## 开发路由

| 要改什么 | 先看什么 |
|---|---|
| 契约字段映射、模型缺字段 | `XSpiderMapping.swift`，再核 core 契约 |
| core 启动失败、握手失败、版本不匹配 | `XSpiderComponent.swift`、组件日志 |
| X 返回内容不对 / 分页不对 / 请求失败 | **core 仓库**；不要在 mac 加补丁 |
| 下载按钮、下载记录、跳过判定 | `DownloadStore` / `MediaJudgement` + `MEDIA_RECORDS.md` |
| 同步 | `SyncStore` + `MEDIA_RECORDS.md` |
| 搜索 / 首页 / 时间线展示流程 | 对应 Store + View；只处理产品侧筛选与呈现 |
| 设置项 | `Settings` / `SettingsStore` + `SETTINGS_DEFAULTS.md` |
| UI / 窗口 / 手势 | `Views/` + `Support/`，并读 `docs/DEVELOPMENT.md` |
| 组件部署 / 换二进制 / 组件账本 | `docs/COMPONENTS.md` |
| 测试与 live X 验收 | `docs/TESTING.md` |
| 发布 / Tag / DMG | `docs/RELEASING.md` |
| 追溯项目来源 / 许可证历史 | `docs/history/UPSTREAM_REFERENCE.md`；不要用于判断 X 行为 |

## 应用侧黄金法则

- `XSpiderMapping` 是组件契约到应用模型的唯一映射入口；不要在 View / Store 到处手拆 JSON。
- 结构化错误按 core 的 `error.code` 分流，不做错误文案字符串匹配。
- 状态放 `@Observable` Store；View 的 `@State` 只放纯 UI 状态。
- 下载 / 同步记录的文件形状和判定语义只在 `MEDIA_RECORDS.md` 维护。
- `project.yml` 是 Xcode 工程真源；加文件、删文件或改 target 后必须重跑 `xcodegen generate`。
- 最低系统版本 macOS 15.0；不要为更老系统增加无法测试的功能降级分支。
- 运行日志统一走 `AppLogger`；组件相关日志归 `CORE` 分类。
- 返回导航统一走 `Support/NavigationHistory.swift`。
- 媒体卡操作统一走 `Views/MediaCardActions.swift`，不要各页面复制按钮逻辑。
- 更换外部 `xspiderd` / `aria2next` 后要处理 quarantine 与 ad-hoc 签名，具体见 `docs/COMPONENTS.md` §2。
- 本地化文案走 `Support/L10n.swift` 的 `L()`，界面文案以中文为主。
- 升级随包组件一律走 `script/update_components.sh`（账本唯一写手），不要手工换文件后直接提交。

## 构建与验证

工程由 `XSpiderMac/project.yml` 生成（`.xcodeproj` 不入库）；生成工程、构建 / 运行、
单元测试的命令见 [`CONTRIBUTING.md`](CONTRIBUTING.md#构建与运行)。

改动完成后至少运行与改动相关的单元测试。涉及组件接线时，另外确认设置页「组件状态」可完成启动和 `system.version` 握手。

### 质量门

- 普通 Swift 行为改动：跑相关单测，收尾前 `xcodebuild test` 全绿。
- 动过随包组件、或打包 / 发布前：`script/verify_components.sh`（与 `components.lock.json` 对账，见 `docs/COMPONENTS.md` §5）。
- 涉及组件 / API 的改动收尾前：`script/check_boundaries.sh`（生产源码零边界泄漏）。
- **不要用截图 / 录屏做视觉验收**（太耗 token）：改完 UI 描述改动、请用户确认；行为验证用单测 + `AppLogger` 日志（细则见 `docs/TESTING.md`）。

## 历史来源

[MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider) 对本项目早期功能设计有历史影响。
当前开发不要把它当作“上游实现”或 X 行为权威；需要追溯来源或许可证历史时使用 Git 历史与
`docs/history/UPSTREAM_REFERENCE.md`，不要把旧源码或端点行为文档重新放回当前工作树。
