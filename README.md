# X-Spider for macOS

> 上游 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)（Tauri + React，Windows 优先，
> 已停止维护）到 **macOS ARM / SwiftUI** 的移植。

原生 macOS 应用，SwiftUI 重写界面，内置 aria2Next 下载引擎。用于浏览与批量下载 X（Twitter）
用户的媒体时间线。

## 功能

- **搜索用户**：按 `screen_name` 拉取媒体时间线 / 推文时间线，无限滚动分页
- **主页时间线**：推荐 / 关注，推文卡片与纯媒体瀑布流两种形态
- **筛选**：日期范围 + 媒体类型（图片 / 视频 / GIF）+ 数据源
- **下载**：aria2Next（多连接、断点续传）与系统 URLSession 双引擎，按文件大小自动分流
- **下载管理**：进度、暂停 / 恢复、重试、批量操作、系统通知
- **同步**：按关注清单批量补齐缺失媒体，支持按日期锚点加速重复同步
- **账户**：Cookie 登录（多账户保存与切换）、代理（关闭 / 系统 / 手动三态）
- **限流缓解**：请求闸门（令牌桶 + 同类串行）+ 429 熔断，X API 与媒体 CDN 分别治理
- 文件名 / 目录模板引擎、跳过已下载、液态玻璃外观、三语界面

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
```

最低系统要求 macOS 15.0（翻译功能依赖系统 Translation 框架）。下载引擎二进制（`XSpiderMac/Resources/Binaries/aria2next`）随仓库提供。

## 仓库结构

| 路径 | 说明 |
|---|---|
| `XSpiderMac/` | **应用本体**（SwiftUI）；`project.yml` 由 xcodegen 生成 xcodeproj |
| `script/` | 构建与运行脚本 |
| `docs/DEVELOPMENT.md` | 架构地图、与上游的语义对照、已知问题与判定依据取舍（**改代码前先读**） |
| `AGENTS.md` | 面向 AI agent 的开发约束 |
| `src/`、`src-tauri/` | 上游源码，**只作行为参照**，不参与构建 |
| `homepage/`、`assets/`、`design/` | 上游官网与设计资源 |

> `src/` 与 `src-tauri/` 是上游实现的唯一权威参照：X 的 GraphQL 端点对
> queryId / features / variables 极其敏感，改动 API 或分页逻辑前应先对照上游实现。

## 致谢与许可

界面与下载逻辑移植自 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)。

许可证沿用上游：**GPL-3.0-only**，见 [LICENSE](LICENSE)。
