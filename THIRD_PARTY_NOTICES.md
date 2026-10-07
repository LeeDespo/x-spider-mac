# 第三方组件与许可证声明（THIRD PARTY NOTICES）

本文件声明 XSpiderMac 随包分发的组件二进制（`XSpiderMac/Resources/Binaries/`）的
来源与许可证。各二进制的**精确版本、对账锚与 SHA256 的唯一账本是
`XSpiderMac/Resources/Binaries/components.lock.json`**；本文件只做许可证与出处声明，
不重复记账版本号。

## 1. xspiderd（X 取数与下载组件）

- **来源**：[LeeDespo/x-spider-core](https://github.com/LeeDespo/x-spider-core)
  （随包二进制的版本与升级对账锚见 `components.lock.json` 的 `xspiderCore` 节）。
- **许可证**：**GPL-3.0-only**。依据其仓库根 `LICENSE`（GPL-3.0 全文）与 `NOTICE` §1：
  该组件的 X GraphQL 请求构造、分页与解析逻辑移植自 GPL-3.0 的
  MiningCattiva/x-spider 及其 macOS 移植（x-spider-mac），衍生作品沿用同一许可证。
- **随包形式**：编译后的 sidecar 可执行文件，通过本地 JSON-RPC（`xspider_call`）与本应用通信。
- **分发义务**：GPL-3.0 要求随分发提供对应源码的获取方式——即上方仓库地址，
  以及 `components.lock.json` 里记录的 tag / asset（对账锚）。
- **备注**：随包二进制与其来源仓库 Release 资产的对应关系（对账锚）只记录在
  `components.lock.json`；这只影响版本溯源，不影响许可证归属（同一仓库、同一授权）。

## 2. aria2next（下载引擎）

- **来源（上游仓库）**：[AnInsomniacy/aria2-next](https://github.com/AnInsomniacy/aria2-next)，
  所用版本 tag：`v2.7.5`（上游资产 `aria2-next-2.7.5-macos-arm64`）。
- **版本**：2.7.5（随包二进制内嵌版本串实测，与 x-spider-core `NOTICE` §3、上游 tag 一致）。
- **许可证**：**GPL-2.0**（"version 2, or (at your option) any later version"）。
  完整许可证文本随本仓库根 **`LICENSE.aria2`** 分发（复制自 x-spider-core 仓库同名文件），
  打包时也会拷入 DMG 根（「GPL-2.0 许可证（aria2next）.txt」）。
- **与上游 aria2 的关系**：Aria2Next 是 aria2 的 fork（x-spider-core `NOTICE` §3 提及其
  "fork 专有项" `--stream-max-connections`，并说明指向上游 aria2 的二进制会被组件预检拒绝）。
  **原始 aria2 项目（官方出处）**：项目主页 <https://aria2.github.io/>、
  源码仓库 <https://github.com/aria2/aria2>、许可证同为 **GPL-2.0-or-later**
  （官方声明 "either version 2 of the License, or (at your option) any later version"）。
- **分发义务**（x-spider-core `NOTICE` §3）：随包分发其二进制时必须
  a) 附上 GPL-2.0 完整许可证文本（本仓库 `LICENSE.aria2`）；
  b) 提供对应源码的获取方式（上方仓库链接 + 所用版本 tag `v2.7.5`）；
  c) 指明所用版本号与校验和（见 `components.lock.json`）。

## 3. 本应用自身

- XSpiderMac 以 **GPL-3.0** 发布（见仓库根 `LICENSE`）。
- Aria2Next 是**独立的可执行程序**，本应用通过「子进程 + JSON-RPC」调用它，
  属于聚合（aggregation），各自许可证互不传染（与 x-spider-core `NOTICE` §3 的定性一致）。

---

## 组件升级

更换随包二进制一律走 `script/update_components.sh`（`components.lock.json` 的唯一写手，
会同步本文件里 aria2next 的版本号），更换后用 `script/verify_components.sh` 校验账本一致性；
打包时 `script/package_dmg.sh` 会先跑同一校验，并把本文件拷入 dmg 根
（「许可证与第三方声明.txt」）。
