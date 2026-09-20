# X-Spider for macOS

> 上游 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)（Tauri + React，Windows 优先，
> 已停止维护）到 **macOS / SwiftUI** 的移植。

原生 macOS 应用，SwiftUI 重写界面，内置 aria2Next 下载引擎。
用于浏览与批量下载 X（Twitter）用户的媒体。

## 安装

1. 下载 `XSpiderMac-1.0.0.dmg`（见 [Releases](../../releases)）；
2. 打开 dmg，把 **X-Spider** 拖进「应用程序」；
3. 首次打开若提示 **"已损坏，无法打开"** 或 **"无法验证开发者"**，见下一节。

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
sudo xattr -dr com.apple.quarantine /Applications/X-Spider.app
```

**方法三：系统设置里放行**

「系统设置 → 隐私与安全性」，在底部找到被拦截的提示，点「**仍要打开**」。

> 为什么不签名：Apple 开发者账号需年费，本项目是免费开源移植。
> 源码完全公开，也可以按下方「构建」自行编译（自己编译的不会被拦截）。

## 功能

- **主页**
  - 搜索用户（`screen_name`）或直接粘贴推文链接，查看媒体时间线 / 推文时间线
  - 日期范围 + 媒体类型筛选；开启「加快搜索页加载」时走 X 搜索接口，加载更快
  - 主页时间线：推荐 / 关注，支持「推文卡片」与「媒体瀑布流」两种形态
  - 推文详情浮层：媒体查看、评论（层级 + 排序）、引用推文、翻译、点赞 / 书签、在浏览器打开
  - 独立媒体查看窗口：缩放、旋转、全屏、倍速播放、切换上下一个
- **下载管理**
  - 内置 aria2Next（多连接、断点续传），按文件大小自动选择引擎
  - 「选择下载」支持全选 / 反选 / 多选，未加载部分由爬虫补齐
  - 自动跳过已下载（判定依据可选：文件名 / 下载记录文件）
  - 进度、暂停 / 恢复、重试、批量操作、系统通知
- **同步**
  - 按关注清单批量补齐缺失媒体
  - 同步记录文件加速二次同步（只检索上次之后的时间线）
- **其他**
  - Cookie 登录（多账户保存与切换）、代理（关闭 / 系统 / 手动）
  - 限流缓解：请求闸门 + 429 熔断，X API 与媒体 CDN 分别治理
  - 文件名 / 目录模板引擎、液态玻璃外观、三语界面（简中 / 繁中 / 英文）

## 系统要求

**macOS 15.0** 或更高。

## 构建

需要 Xcode 与 [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

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

## 仓库结构

| 路径 | 说明 |
|---|---|
| `XSpiderMac/` | **应用本体**（SwiftUI）；`project.yml` 由 xcodegen 生成 xcodeproj |
| `script/` | 构建、运行、打包脚本 |
| `docs/DEVELOPMENT.md` | 架构地图、与上游的语义对照、已知问题与设计取舍（**改代码前先读**） |
| `AGENTS.md` | 面向 AI agent 的开发约束 |
| `src/`、`src-tauri/` | 上游源码，**只作行为参照**，不参与构建 |
| `homepage/`、`assets/`、`design/` | 上游官网与设计资源 |

> `src/` 与 `src-tauri/` 是上游实现的唯一权威参照：X 的 GraphQL 端点对
> queryId / features / variables 极其敏感，改动 API 或分页逻辑前应先对照上游实现。

## 已知限制

- **未签名**：首次打开需按上文解除拦截。
- **评论的评论**：X 服务端只返回贴主自己的嵌套回复，其他人的不返回
  （与 X 网页端一致，非本应用缺陷）。
- **X 的视频一般没有内嵌字幕**，因此查看窗口不提供字幕选择。
- 搜索结果可能有极个别遗漏；**下载**始终由内置爬虫逐页抓取，会把遗漏补上。

## 致谢与许可

界面与下载逻辑移植自 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)。

许可证沿用上游：**GPL-3.0-only**，见 [LICENSE](LICENSE)。
