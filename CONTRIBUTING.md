# 贡献指南

XSpiderMac 是上游 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)（Tauri + React，已停止维护）
到 macOS / SwiftUI 的移植，用于浏览与批量下载 X（Twitter）用户的媒体。
项目介绍、安装与使用见 [README.md](README.md)。

## 环境要求

- macOS + Xcode 16+（本仓库按 arm64 构建与测试）
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

## 构建与运行

```bash
# 生成工程（改了 XSpiderMac/project.yml 后必做）
(cd XSpiderMac && xcodegen generate)

# 构建 + 启动 Debug 版（arm64）
script/build_and_run.sh

# 单元测试
cd XSpiderMac && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
  -destination 'platform=macOS,arch=arm64' test
```

## 动手前必读

- `XSpiderMac/project.yml` 是工程的唯一真源，**改了它必须重跑 `xcodegen generate`**，
  否则新文件不进工程。
- **外壳不做取数与下载**：请求签名、限流、下载引擎与爬取都在组件 `x-spider-core` 里，
  本仓库只做契约映射与 UI。职责边界见 [AGENTS.md](AGENTS.md) 的「黄金法则」。
- 更换组件二进制（`xspiderd` / `aria2next`）后要 `xattr -cr` + `codesign --force --sign -`，
  漏了会以退出码 137 静默被杀（见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) §2.7）。

## 反馈问题

- 提 Issue 请使用模板（「问题反馈」/「功能建议」），空白 Issue 入口已关闭。
- 报障请附**应用版本**与**组件版本**两个版本号，写法见模板的「环境信息」一节。
