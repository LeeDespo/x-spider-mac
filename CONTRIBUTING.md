# 贡献指南

XSpiderMac 是面向 macOS 的原生 SwiftUI X（Twitter）媒体客户端。应用只负责界面、产品逻辑和本地数据；X 数据访问、写操作、爬取与下载由独立组件 [x-spider-core](https://github.com/LeeDespo/x-spider-core) 提供。
项目早期参考过已停止维护的 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)，当前开发不把它作为实现或行为真源。
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
- **外壳不维护 X 端点行为**：请求、分页、原始响应解析、限流、爬取与下载都在组件 `x-spider-core` 里；本仓库只消费契约并实现应用侧产品逻辑。职责边界见 [AGENTS.md](AGENTS.md)。
- 更换组件二进制（`xspiderd` / `aria2next`）后要 `xattr -cr` + `codesign --force --sign -`，
  漏了会以退出码 137 静默被杀（见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) §2.7）。

## 反馈问题

- 提 Issue 请使用模板（「问题反馈」/「功能建议」），空白 Issue 入口已关闭。
- 报障请附**应用版本**与**组件版本**两个版本号，写法见模板的「环境信息」一节。
