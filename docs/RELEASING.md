# 发布流程（DMG / GitHub Release）

> 版本号、打包、产物与发布的唯一流程。动手前先读本文；打包脚本本体是
> `script/package_dmg.sh`，组件升级见 `COMPONENTS.md` §4–§5。

## 0. 前置事实

- **未签名分发**：本项目不做 Apple 签名与公证（无开发者账号）。打包用
  `CODE_SIGN_IDENTITY="-"` ad-hoc 签名——不通过 Gatekeeper，但保证 app 内部二进制
  （含随包组件）在 Apple Silicon 上可执行。用户首次打开需按 README
  「解除系统拦截」放行。
- **版本号真源**：`XSpiderMac/project.yml` 的 `MARKETING_VERSION`。
  发版时它与 GitHub Release 的 tag 保持一致（如 tag `v1.2.3` ↔ 版本 `1.2.3`）。
  改 `project.yml` 后必须重跑 `(cd XSpiderMac && xcodegen generate)`，把生成的
  `XSpiderMac.xcodeproj` 一起提交——**不要手改 pbxproj**；CI 每次现生成工程跑测试，
  不依赖入库工程是否最新。
- **随包组件**：打包前脚本会自动跑 `verify_components.sh` 与
  `components.lock.json` 对账（见 `COMPONENTS.md` §5）；升级组件先走
  `COMPONENTS.md` §4，再回来发版。

## 1. 发布前检查

```bash
script/verify_components.sh    # 随包组件与账本对账（换过组件后必须）
script/check_boundaries.sh     # 生产源码零边界泄漏（涉组件/API 的改动收尾前）
cd XSpiderMac && xcodebuild -project XSpiderMac.xcodeproj -scheme XSpiderMac \
  -destination 'platform=macOS,arch=arm64' test   # 单测全绿（live 默认跳过）
```

## 2. 打包

```bash
script/package_dmg.sh           # 用 project.yml 的版本号
script/package_dmg.sh 1.2.3     # 或显式指定
```

脚本流程：先跑 `verify_components.sh`（组件校验不过就不进入构建）→ Release 构建
（arm64）→ ad-hoc 深签名（签名失败会中止脚本，不被吞掉）→ 组装 DMG（app + 指向
/Applications 的快捷方式，并把 `THIRD_PARTY_NOTICES.md` 与 `LICENSE.aria2`（GPL-2.0
全文）拷入 DMG 根，分别显示为「许可证与第三方声明.txt」「GPL-2.0 许可证（aria2next）.txt」）
→ 产物 `dist/XSpiderMac-<版本>.dmg`（`dist/` 不入库）。

## 3. 产物与 GitHub Release

1. 生成产物校验和并随 Release 上传：

   ```bash
   shasum -a 256 dist/XSpiderMac-<版本>.dmg > dist/XSpiderMac-<版本>.dmg.sha256
   ```

2. 打 tag（与 `MARKETING_VERSION` 一致）并创建 GitHub Release，上传
   **dmg + sha256**，Release 说明写变更记录（各版本变更记录集中在 Releases）。
3. **分发物必须携带许可证对应物**：DMG 根内的「许可证与第三方声明.txt」与
   「GPL-2.0 许可证（aria2next）.txt」（分别来自 `THIRD_PARTY_NOTICES.md` 与
   `LICENSE.aria2`）。仓库里有、分发包里也要有。
4. **不要重新引入 GitHub Pages 部署**：曾随上游官网一起删除过
   `gh-pages.yml`——它会把**上游**官网（含上游赞助入口）部署到本仓库的 Pages。

## 4. 用户首次放行（未签名分发的已知代价）

README「⚠️ 解除系统拦截」一节写了三种放行方式（右键打开 / 命令行移除隔离标记 /
系统设置放行）。发布说明或 issue 回复里直接指过去即可，不要在这里复述步骤
（避免两处维护）。

## 5. 组件升级联动

组件有新 Release 时的顺序（**先组件、后发版**）：

1. `script/update_components.sh xspiderd|aria2next [--tag vX.Y.Z]`
   （下载校验 → `xattr -cr` → ad-hoc 签名 → 原子替换 → 回写 lock → verify 收尾；
   详见 `COMPONENTS.md` §4）；
2. 同步 `THIRD_PARTY_NOTICES.md` 中对应条目的版本号；
3. 跑单测；需要真机验证时按 `TESTING.md` 的 live 门控跑；
4. 再走本文 §1–§3 发本仓库的新版本。
