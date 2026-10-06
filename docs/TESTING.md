# 测试与验收

> 单元测试的跑法与范围、live 测试门控、组件冒烟、行为验收清单与日志观察手法。
> 测试之外的构建命令见根目录 `../AGENTS.md` 质量门与 `../CONTRIBUTING.md`。

## 1. 单元测试

```bash
cd XSpiderMac && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
  -destination 'platform=macOS,arch=arm64' test
```

- 范围：`XSpiderMac/Tests/XSpiderMacTests/`（映射、记录层、判定、设置、同步窗口等
  纯逻辑用例；记录体系的测试清单见 `../MEDIA_RECORDS.md` §12）。
- **live 测试默认跳过**：`ComponentLiveTests` 由环境变量 `XSPIDER_LIVE=1` 门控
  （`XCTSkipUnless`），默认全跳——所以 CI 测试 job **无需任何凭据**。真跑 live 时：

  ```bash
  XSPIDER_LIVE=1 xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
    -destination 'platform=macOS,arch=arm64' test
  ```

- 编译通过**不等于**行为正确；下表的实测项按改动类型执行。

## 2. 组件冒烟

- **账本校验**：`script/verify_components.sh` 纯校验不改文件（七项：lock 可解析、
  两二进制存在、arm64 Mach-O、可执行位、sha256 与 lock 一致、`--version` 契约主版本
  与 lock 一致、lock 与 `XSpiderComponent.swift` 的主版本常量一致）。
  动过随包组件、或打包/发布前必跑。
- **绿灯语义**：设置页「组件状态」绿灯 = 进程真的起来并完成握手
  （详见 `COMPONENTS.md` §3）。冒烟三查：绿灯；改代理后取数/下载恢复；
  换一份组件后启动日志的 `组件已就绪 … path=` 指向新目录。

## 3. 行为验收清单（改什么测什么）

| 改动 | 必须实测 |
|---|---|
| 分页 / 爬虫 | 下面 §4 的两条路径 |
| 组件对接 | 设置页「组件状态」绿灯（进程真起来并握手）；改代理后取数/下载恢复；换一份组件后启动日志的 `path=` 指向新目录 |
| 图片管线 | 快速来回滚动不掉帧；滚回顶部不重新闪载 |
| 时间范围 | 取一个已知有长空窗期的账号，设跨越空窗期的范围，确认能持续翻页并显示内容 |
| UI 层级 | 详情浮层打开时，底层卡片的悬停提示不出现 |
| 任何改动 | `xcodebuild test` 全绿 |

视觉/手感类项（图片管线、UI 层级等）由**用户**确认——见 §6，Agent 不截图/录屏。

## 4. 两条实测路径（分页 / 爬虫改动后必测）

1. **持续翻页不重复**：搜索页滑到底能持续加载**超过 ~40 条且不重复**
   （媒体量大的用户更佳）；
2. **跳过判定幂等**：「下载全部」创建任务对同用户同条件执行**两遍**，
   第二遍应**全部 skip** 而非重复创建。

## 5. live 测试纪律

- **不弄脏用户的下载历史**：测试宿主有自己的备份/还原机制
  （见 `ComponentLiveTests`），live 运行不得把测试数据留在用户真实记录里。
- live 会真连 X 与真下载，**最小副作用**：能跳过则跳过（默认门控就是为此）、
  能用临时目录则不写用户路径；live 数据（cookie、响应）**不得**写进日志、
  fixture 或文档——需要留证据时先脱敏。
- 离线/本地测试能回答的问题，不做 live。

## 6. UI 视觉验收

**不要截图 / 录屏做视觉验收**（用户明确要求，太耗 token）。需要"看一眼"的验收
由用户自己做：改完 UI 后**说明改了什么、请用户确认**；自己则用单测 +
真实 API 响应核对正确性。

## 7. 日志与观察

- 运行日志用 `AppLogger`（分类 `NET` / `DL` / `HOME` / `REC` / `SYNC` / `APP` /
  `CORE`…）；**组件日志以 `组件: …` 出现在分类 `CORE`**。
- 验证行为：`log stream --predicate 'process == "XSpiderMac"'` 或 Console.app；
  或读 `~/Library/Logs/XSpiderMac/xspider.log`（单文件 10MB，超出轮转为
  `xspider.log.1`，仅保留一份历史）。
- 要看组件更细的日志：设 `XSPIDER_LOG=debug` 再启动（默认 `warn`）。
