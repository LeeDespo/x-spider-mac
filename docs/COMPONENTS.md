# 组件部署与版本账本（x-spider-core）

> 本册只管组件**从哪来、怎么部署、怎么换、怎么对账**。
> 组件的职责边界、契约接口与错误码语义见 `DEVELOPMENT.md` 第 2 部分；
> 请求形状 / 分页语义 / 错误码定义的**权威在组件仓库**
> [LeeDespo/x-spider-core](https://github.com/LeeDespo/x-spider-core)
> 的 `docs/07-API-REFERENCE.md` 与 `docs/CONTRACT.md`。
> 本仓库不实现取数、下载或请求逻辑（边界总纲见根目录 `../AGENTS.md`）。

## 1. bundled 与 external：两种来源，两套纪律

组件以两个可执行文件存在：`xspiderd`（Rust sidecar）与 `aria2next`（下载引擎）。

| | bundled（随包兜底） | external（用户目录） |
|---|---|---|
| 位置 | `XSpiderMac/Resources/Binaries/`，随 app bundle 分发 | 见 §2 查找顺序的前两级 |
| 版本与哈希 | **由 `components.lock.json` 记账**（§3） | 用户自管，自行对版本 |
| 兼容性 | 打包前过 `verify_components.sh`（§5） | 运行时 `system.version` 契约**主版本**握手兜底 |

运行时兼容只按契约**主版本**判断（`XSpiderComponent.supportedContractMajor = "1"`，
不匹配拒绝启动）；长期文档**不写死组件 PATCH 版本**，随包二进制的精确版本与
SHA256 的唯一归宿是 §3 的账本。

## 2. 组件从哪来、怎么部署

**查找顺序**（`XSpiderComponent.searchDirectories()`，**外部目录优先**）：

1. `~/Library/Application Support/moe.keli.xspider.mac/XSpiderCore/`
2. `~/Library/Application Support/XSpiderMac/XSpiderCore/`
3. `XSpiderMac.app/Contents/Resources/`（随包携带的兜底；仓库里是 `XSpiderMac/Resources/Binaries/`）
4. 可执行文件所在目录（`Contents/MacOS`，开发时为构建产物旁）
5. `PATH`

目录里放**两个文件**即可：`xspiderd` 与 `aria2next`。

**更新组件 = 换掉那两个文件 + 重新签名，不必重新构建应用**（这正是分进程形态的意义）。
两步都要做，漏了会被内核静默杀掉：

```bash
DIR=~/Library/Application\ Support/moe.keli.xspider.mac/XSpiderCore
xattr -cr "$DIR"                                             # 清隔离属性（从浏览器下载来的必做）
codesign --force --sign - "$DIR"/xspiderd "$DIR"/aria2next   # ad-hoc 签名
```

**漏签 / 带隔离属性的典型表现**：文件在、却以**退出码 137** 静默被杀——`ready` 行永远不出现，
只有一行日志。因此设置页「组件状态」绿灯的判据是**进程真的起来并完成握手**，不是"文件存在"
（文件在但被隔离会是假绿灯，所以刻意不这么判）。

**为什么不用 cdylib**：本机 hardened runtime 打开时 `dlopen` 任何 dylib 都会被
library validation 拒，所以主形态是 sidecar（换组件 = 换一个二进制）。

## 3. 版本账本 `components.lock.json`

位置：`XSpiderMac/Resources/Binaries/components.lock.json`。这是随包二进制
**精确版本与 SHA256 的唯一真源**，字段语义：

| 字段 | 语义 |
|---|---|
| `version` / `sha256` | **随包文件自身**的实测版本输出与哈希（`shasum -a 256`） |
| `tag` / `asset` | 来源 Release 的**对账锚**（升级时比对用），不保证随包文件字节等于该资产 |
| `contractMajor` | 与 `XSpiderComponent.supportedContractMajor` 对账（§5 校验第 7 项） |

> **现状注记**：随包 `xspiderd` 报契约 1.5.1，与来源仓库 Release `v0.1.0` 资产
> 字节不同——所以 `sha256` 记随包文件自身、`tag`/`asset` 只作对账锚，两者不能互验。
> 是否用 `update_components.sh` 把随包替换成某个正式 Release 资产，由维护者决策。

账本的**唯一写手**是 `script/update_components.sh`（§4）；不要手工替换二进制后直接提交，
否则 §5 的校验必然失配。

## 4. 组件升级

```bash
script/update_components.sh xspiderd            # 按 lock 里的 tag/asset 拉
script/update_components.sh aria2next --tag v2.7.6   # 或显式指定版本
```

脚本流程：读 lock → 下载 Release 资产 → SHA256 校验 → 确认 arm64 Mach-O →
替换 staging → `chmod +x` → ad-hoc 签名 → 原子替换 `Resources/Binaries` →
回写 lock → 跑 §5 校验收尾。lock 里存在 `TODO` 字段时直接报错退出（不猜下载地址）。

升级联动：

1. 同步 `THIRD_PARTY_NOTICES.md` 中对应条目的版本号（脚本会同步 aria2next 的版本号）；
2. 跑单测；需要真机验证时按 `TESTING.md` 的 live 门控；
3. 再走 `RELEASING.md` 发本仓库新版本（**先组件、后发版**）。

## 5. 账本校验

```bash
script/verify_components.sh
```

七项检查：lock 可解析；两二进制存在；均为 arm64 Mach-O；有执行位；SHA256 与 lock 一致；
`xspiderd --version` 可运行且契约主版本与 lock 一致；lock 的 `contractMajor` 与
外壳握手常量一致。任一项失败非零退出。

**何时跑**：动过随包组件之后；`script/package_dmg.sh` 打包前会自动先跑（不过不进构建）；
CI 每次推送都会跑。换 external 目录组件时用 §2 的两步手动处理，不适用本账本。

## 6. 第三方许可

随包分发 `aria2next` 的许可证义务由本仓库自己承担（不是组件仓库的义务）：

- `THIRD_PARTY_NOTICES.md`：各二进制的出处与许可证声明（xspiderd **GPL-3.0-only**、
  aria2next **GPL-2.0**）；`package_dmg.sh` 会把它拷入 DMG 根（「许可证与第三方声明.txt」）。
- `LICENSE.aria2`：GPL-2.0 全文。
- 原始 aria2 项目的官方出处声明待补（core 仓库 NOTICE 未记录，不臆写）。
