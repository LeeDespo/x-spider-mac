# AGENTS.md — x-spider-mac

本文件只写本项目特有规则；通用工程原则由用户级全局 AGENTS.md 提供（各 Agent 工具按自己的约定加载，不在本仓库内）。

## 项目是什么

XSpiderMac：X（Twitter）媒体下载器的 **macOS SwiftUI 外壳**。X 的取数、签名、限流/重试、
queryId 自愈、写操作、下载引擎与爬取全部在组件 **x-spider-core**（Rust sidecar `xspiderd`
+ 本地 JSON-RPC，仓库 `LeeDespo/x-spider-core`）。本仓库只做**契约 JSON ↔ 应用模型映射**
与产品 UI——**不要在本仓库实现取数、下载或请求逻辑**。

## 目录速览

| 路径 | 内容 |
|---|---|
| `XSpiderMac/Sources/XSpiderMac/` | `Stores/`(状态) `Services/`(组件客户端/契约映射) `Views/`(UI) `Models/` `Support/` |
| `XSpiderMac/Resources/Binaries/` | 随包组件兜底 `xspiderd`/`aria2next` + 版本账本 `components.lock.json` |
| `docs/` | `ARCHITECTURE.md` `COMPONENTS.md` `TESTING.md` `RELEASING.md` 与 `history/` |
| `MEDIA_RECORDS.md` / `SETTINGS_DEFAULTS.md` | 记录体系规范 / 设置默认值一览 |
| `script/` | `build_and_run.sh` `verify_components.sh` `update_components.sh` `check_boundaries.sh` `package_dmg.sh` |

## 组件边界（黄金法则）

- 外壳与组件的唯一接口是 **`XSpiderComponent.call(_:_:)`**（sidecar 的 `xspider_call` +
  `system.version` 握手）；`Services/XSpiderComponent.swift` 是唯一组件客户端，
  其他文件不得自建 sidecar 传输或直连本地 RPC。
- 本仓库不得新增：X GraphQL 端点、queryId/features 常量、X 请求头、签名、限流重试、
  爬取游标协议、aria2 RPC、任何 X 上游响应解析。映射层（`Services/XSpiderMapping.swift` /
  `XSpiderJSON.swift`）只理解契约形状。
- 请求形状、错误码含义、分页语义 → 组件仓库 `docs/07-API-REFERENCE.md` 与 `docs/CONTRACT.md`；
  **不要仿上游在外壳发明取数逻辑**。外壳侧组件纪律见 `docs/COMPONENTS.md`。
- 兼容性只按契约**主版本**（`XSpiderComponent.supportedContractMajor`）；长期文档**不写死
  core PATCH 版本**，随包组件的精确版本与哈希以 `components.lock.json` 为准。
- 组件查找：外部目录优先、bundle 兜底。bundled 由 lock 管；external 由用户自管，
  运行时主版本握手兜底（换外部组件的 xattr/签名纪律见 `docs/COMPONENTS.md`）。

## 按任务阅读路由

| 要改的东西 | 先读 |
|---|---|
| 组件接入 / 二进制 / 契约调用 | `docs/COMPONENTS.md`（必要时组件仓库 docs） |
| Store / Service / 架构 / UI 纪律 | `docs/ARCHITECTURE.md` |
| 下载队列、跳过判定、目录与文件名 | `Stores/DownloadStore.swift` + `Services/MediaJudgement.swift`；规范 `MEDIA_RECORDS.md` |
| 测试与 live X 验收 | `docs/TESTING.md` |
| 设置默认值 | `SETTINGS_DEFAULTS.md`（改动须 bump `settingsSchemaVersion`，见 `MEDIA_RECORDS.md` §9.2） |
| 发布 / Tag / DMG | `docs/RELEASING.md` |
| 历史迁移与旧实现考据 | `docs/history/`（仅当前文档不足时） |

## 硬性约定

- `XSpiderMac/project.yml` 是工程唯一真源；改它必须 `(cd XSpiderMac && xcodegen generate)`（xcodeproj 入库）。
- 状态一律放 `@Observable` Store（单例 `*.shared`）；视图 `@State` 只放纯 UI 态——
  会随视图重建丢失的业务数据放 `@State` 属 bug。
- 返回导航统一走 `Support/NavigationHistory.swift`，不要在视图里各自维护返回栈。
- 代码注释与 UI 文案以中文为主；本地化走 `Support/L10n.swift` 的 `L()`。
- 最低系统 **macOS 15.0**（为系统 `Translation` 框架）：不要降低基线，也不为旧系统写降级分支；
  新用 API 的可用版本不得低于 15.0。
- **不要截图/录屏做视觉验收**（用户明确要求，太耗 token）：改 UI 后描述改动、请用户确认；
  自己用单测 + 真实响应核对正确性。

## 质量门

```bash
# 常规 Swift 行为改动的基线验证
cd XSpiderMac && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
  -destination 'platform=macOS,arch=arm64' test

# 日常构建 + 运行（arm64 Debug）
script/build_and_run.sh

# 动过随包组件、或打包/发布前：随包二进制与账本对账
script/verify_components.sh

# 涉及组件/API 的改动收尾前：生产源码零泄漏（token 清单与豁免见脚本头注释）
script/check_boundaries.sh
```

- 行为验证用 `AppLogger`（组件日志以 `组件: …` 出现在 CORE 分类）+
  `log stream --predicate 'process == "XSpiderMac"'`；细则、live 测试门控（`XSPIDER_LIVE=1`）
  与两条实测验收路径见 `docs/TESTING.md`。
- 组件没起来会阻断一切取数与下载：设置页「组件状态」绿灯 = 进程起来并握手成功
  （语义与排障见 `docs/COMPONENTS.md`）。
