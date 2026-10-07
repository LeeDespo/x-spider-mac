# X-Spider for macOS

> 面向 macOS 的原生 SwiftUI X（Twitter）媒体客户端。
> 应用负责界面、产品逻辑与本地数据；X 数据访问、写操作、爬取与下载由独立 Rust 组件 [x-spider-core](https://github.com/LeeDespo/x-spider-core) 提供。

原生 macOS 应用，SwiftUI 重写界面，用于简单浏览与批量下载 X（Twitter）用户的媒体。

取数、写操作、下载与爬取由 **Rust 组件 `x-spider-core`**（sidecar 可执行文件 `xspiderd`）提供，
应用本体只负责界面与产品逻辑。组件怎么装、怎么更新见「[组件](#组件x-spider-core)」一节。

## 安装

1. 下载 `XSpiderMac-x.x.x.dmg`（见 [Releases](../../releases)）；
2. 打开 dmg，把 **X-Spider** 拖进「应用程序」（Finder 里显示为 X-Spider，实际文件名是 `XSpiderMac.app`）；
3. 首次打开若提示 **"已损坏，无法打开"** 或 **"无法验证开发者"**，见下一节。

> 组件（`xspiderd` 与 `aria2next`）随 DMG 一起分发，**无需单独安装**；需要更新组件时见「组件」一节。

## ⚠️ 解除系统拦截（未签名应用，必读）

本应用**没有 Apple 开发者签名与公证**，因此首次打开时 macOS 会拦下来。
这是预期行为，不是应用损坏。三种解决办法，任选其一：

**方法一：右键打开（推荐，最简单）**

1. 在「应用程序」里**右键点击**（或按住 Control 点击）X-Spider；
2. 选择「**打开**」；
3. 弹窗里再点一次「**打开**」。

之后即可正常双击启动。

**方法二：命令行移除隔离标记**

若提示"**已损坏，无法打开。你应该将它移到废纸篓**"（下载器附加了 quarantine 标记），
在「终端」执行：

```bash
sudo xattr -dr com.apple.quarantine /Applications/XSpiderMac.app
```

**方法三：系统设置里放行**

「系统设置 → 隐私与安全性」，在底部找到被拦截的提示，点「**仍要打开**」。

> 为什么不签名：Apple 开发者账号需年费，本项目是免费开源项目。
> 源码完全公开，也可以按下方「构建」自行编译（自己编译的不会被拦截）。

## 功能

- **主页**
  - 搜索用户（`screen_name`）或直接粘贴推文链接，查看媒体时间线 / 推文时间线
  - 日期范围 + 媒体类型筛选；开启「加快搜索页加载」时走 X 搜索接口，加载更快（浏览可能有个别遗漏，下载仍由爬虫逐页兜底）
  - 主页时间线：推荐 / 关注，支持「推文卡片」与「媒体瀑布流」两种形态
  - 推文详情浮层：媒体查看、评论（层级 + 排序）、引用推文、翻译、点赞 / 书签、在浏览器打开
  - 独立媒体查看窗口：缩放、旋转、全屏、倍速播放、切换上下一个
- **下载管理**
  - 引擎由组件提供：默认 aria2Next（多连接、断点续传），可在设置里改为自动（按文件大小分流）或内置引擎
  - 「选择下载」支持全选 / 反选 / 多选。全选对应原项目全部下载。全选又取消几个媒体的选中，则视为下载时跳过这几个媒体。
  - 自动跳过已下载（判定依据三选一：文件名 / 记录文件·分布式 / 记录文件·集中式，默认集中式）
  - 进度、暂停 / 恢复、重试、批量操作、系统通知
- **同步**
  - 按关注清单批量补齐缺失媒体
  - 记录文件与同步窗口语义已规范化（见 [MEDIA_RECORDS.md](MEDIA_RECORDS.md)）：二次同步只检索锚点前后一天窗口内、尚未记录的时间线
- **其他**
  - Cookie 登录（多账户保存与切换）、代理（关闭 / 系统 / 手动）
  - 限流缓解由组件统一治理：请求闸门 + 429 熔断，X API 与媒体 CDN 分开
  - 文件名 / 目录模板引擎、液态玻璃外观（对不支持液态玻璃的系统，自动降级到普通材质）、三语界面（简中 / 繁中 / 英文）

## 组件（x-spider-core）

应用由两部分组成，职责分明：

| 部分 | 语言 | 职责 |
|---|---|---|
| 外壳（本仓库） | SwiftUI | 界面、产品逻辑：文件名 / 目录模板、内容校验（"这是不是真的图 / mp4"）、记录文件与同文件跳过、通知、图片缓存、翻译、代理设置解析 |
| 组件 `x-spider-core` | Rust（sidecar 可执行文件 `xspiderd`） | X 数据访问、写操作、爬取与下载；对外只暴露稳定契约 |

**走组件的功能**：

- **取数**：用户、媒体时间线、推文时间线、推文详情树、搜索、关注列表、主页时间线；
- **写操作**：点赞 / 转推 / 书签 / 关注（含取消）；
- **下载**：内置引擎 + aria2Next、断点续传、完整性校验、暂停 / 恢复 / 取消；
- **爬取调度**：翻页、游标推进，以及"到底 / 连续空页 / 游标未推进"等终止判据。

**刻意留在外壳里的**：界面、文件名 / 目录模板、内容校验、记录文件与同文件跳过、通知、图片缓存、翻译、代理设置解析。

**组件放哪儿**（查找顺序，**外部目录优先**，app bundle 内那份只作兜底）：

1. `~/Library/Application Support/moe.keli.xspider.mac/XSpiderCore/`（放 `xspiderd` 与 `aria2next` 两个文件）
2. `~/Library/Application Support/XSpiderMac/XSpiderCore/`
3. app bundle 内 `XSpiderMac.app/Contents/Resources/`（DMG 自带的兜底副本）
4. app bundle 内 `XSpiderMac.app/Contents/MacOS/`
5. `PATH`

**更新组件 = 换掉文件即可**，不必重新构建应用。把新的 `xspiderd`（与 `aria2next`）放进上面的外部目录，然后**两件事都要做**，否则内核会以退出码 137 静默杀掉它——应用只写一行日志，表现是"组件整个不工作"：

```bash
xattr -cr "<组件目录>"
codesign --force --sign - "<组件目录>"/xspiderd "<组件目录>"/aria2next
```

**组件从哪来**：新版二进制从组件仓库 [LeeDespo/x-spider-core](https://github.com/LeeDespo/x-spider-core) 的 [Releases](https://github.com/LeeDespo/x-spider-core/releases) 下载。

**核对版本**：`"<组件目录>"/xspiderd --version` 会打印组件版本与契约版本；运行时以 `system.version` 握手结果和实际使用的 Release 为准。
应用启动时按契约**主版本**握手，主版本不匹配会拒绝启动并提示更新组件或应用。

## 系统要求

**Apple Silicon（M 系列）Mac**，**macOS 15.0** 或更高。随包携带的组件二进制（`xspiderd` / `aria2next`）只有 arm64 版。

## 构建

需要 **Xcode 16 或更高**（工程用 Swift 6.0，目标 macOS 15.0）与 [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
# project.yml 变更后重新生成工程
cd XSpiderMac && xcodegen generate

# 构建 + 启动 Debug 版（arm64）
script/build_and_run.sh

# 单元测试
cd XSpiderMac && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
  -destination 'platform=macOS,arch=arm64' test

# 打包 dmg（Release）
script/package_dmg.sh
```

> `Resources/Binaries/` 里放的两个二进制（`aria2next`、`xspiderd`）是**随应用分发的兜底副本**，
> 会一起打进 app bundle。改了 `project.yml`（版本号、内置文件等）后必须重新 `xcodegen generate`。

## 仓库结构

| 路径 | 说明 |
|---|---|
| `XSpiderMac/` | **应用本体**（SwiftUI）；`project.yml` 由 xcodegen 生成 xcodeproj |
| `script/` | 构建、运行、打包脚本 |
| `docs/DEVELOPMENT.md` | 架构地图、组件边界、已知问题与设计取舍（**改代码前先读**） |
| `MEDIA_RECORDS.md` | 记录体系规范：下载 / 同步记录、判定三选一、命名（**改记录前先读**） |
| `SETTINGS_DEFAULTS.md` | 设置项默认值一览 |
| `AGENTS.md` | 面向 AI agent 的开发约束 |

> **X 数据访问与下载行为的真源在组件仓库 [LeeDespo/x-spider-core](https://github.com/LeeDespo/x-spider-core)**；本仓库只消费其契约，不维护 X 端点实现或行为盘点。

## 已知限制

- **评论的评论**：只做到显示贴主对评论的评论。显示非贴主对评论的评论这功能太麻烦了，日后很有可能不会做。

## 致谢与许可

项目早期开发参考了已停止维护的 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider) 的功能设计与实现，现已采用独立的 SwiftUI + x-spider-core 架构；该项目仅作为历史来源保留致谢。

为保留项目历史与许可证连续性，本项目继续采用 **GPL-3.0-only**，见 [LICENSE](LICENSE)。

## 参与贡献

欢迎提交 issue 与 PR，约定见 [CONTRIBUTING.md](CONTRIBUTING.md)；各版本的变更记录见 [GitHub Releases](../../releases)。
