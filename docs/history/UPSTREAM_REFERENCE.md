# 历史来源

> 2026-10-07：本仓库工作区删除了上游 vendor 源码 `src/`（前端，85 个文件）与
> `src-tauri/`（Rust 侧，24 个文件）。X 的**端点行为**参照自即日起由组件仓库
> **x-spider-core** 承担；本文记录上游出处、删除前标记与找回方法。

## 上游出处

- 上游仓库：<https://github.com/MiningCattiva/x-spider>
  （Tauri + React + zustand，Windows 优先，**已停止维护**）。
- 上游最后已知 commit：`252a9001215105593a3851d8b1eb0d8b185049af`
  （2024-11-08 15:40:42 +0800「Update README.md」；2026-10-07 经
  `git ls-remote upstream HEAD` 实测，与本地 remote-tracking `upstream/master` 一致）。
- 本仓库 `upstream` remote 即指向上游，仅为历史出处记录保留；
  **不要再把这里的实现当作外壳取数的答案**。

## 删除前的标记

- **tag `pre-component-integration`**（annotated tag，2026-10-01 19:16:25 +0800 创建）
  → 指向提交 `3bc5e53`（2026-09-28「prepare 1.0.1」）。
  该 tag 中的 `src/`、`src-tauri/` 内容与删除时 HEAD `0a5fa72` **逐字节一致**
  （`git diff --name-only 3bc5e53 HEAD -- src src-tauri` 结果为 0 个文件；
  这两棵目录的最后一次变更分别是 2024-05-18 / 2024-04-16，远早于 tag 创建）。
- 配套分支 `backup/pre-component-integration`（本地与 origin 均有）同样保留上游源码，
  也是组件仓库 `docs/02-X-DOMAIN-NOTES.md` §A4 所指向的找回入口。
- 删除动作只发生在工作区（`rm -rf`，未 `git rm`），删除前 `git status` 对这两棵目录
  无未提交修改；暂存的删除由归档提交员统一提交，**提交之后历史仍可达**。

## x-spider-core（现行端点行为参照）

- 仓库：<https://github.com/LeeDespo/x-spider-core>（开发机上一般是本仓库的并列目录
  `/Users/mac/Documents/x-spider-core`）。
- 抽取时间：**2026-10-01**。core 首个提交 `c896d75`（2026-10-01 19:15:47 +0800
  「初始提交：M0–M4 全部完成的可复用组件」）；本仓库 tag `pre-component-integration`
  于同日 19:16 创建，即"抽取完成、上游只留参照"的时间点。
- 核实时的 core HEAD：`660b918`（2026-10-07）。
- 当前契约版本：**1.5.2**（`docs/CONTRACT.md` §0 与 `xspider_version()`；
  bundled 二进制仍为 1.5.1，PATCH 兼容，运行时以握手为准）。
- 外壳 AGENTS.md 原引为参照的 8 条端点行为——搜索端点 POST+JSON body（GET 404 与
  queryId 无关）、cursor 首页省略/翻页推进、空页终结、promotedMetadata 三入口广告过滤、
  评论树 parent_id 与孤儿不丢、queryId 自愈、`since`/`until` 本地日历含当天（组件内 +1 天）、
  爬取终止判据（去重先于筛选、时间轴推进主判据、UTC 天粗筛）——已于 2026-10-07 逐条
  核实，在 core 的 `docs/02-X-DOMAIN-NOTES.md`（§A–§D）、`docs/07-API-REFERENCE.md`、
  crates 实现与测试、`fixtures/` 全部有权威出处。

## 如何从历史找回

```bash
# 单个文件（路径与删除前一致）
git show pre-component-integration:src/twitter/api.ts
git show pre-component-integration:src-tauri/Cargo.toml

# 浏览整个目录清单
git ls-tree -r pre-component-integration --name-only -- src/ src-tauri/

# 或用删除时的 HEAD（归档提交之后仍长期可达）
git show 0a5fa72:src/twitter/api.ts

# 需要整目录恢复到工作区时（确认真的需要再用）
git checkout pre-component-integration -- src/ src-tauri/
```

> 行为问题先查组件仓库：`docs/02-X-DOMAIN-NOTES.md`（X 域实测事实）、
> `docs/07-API-REFERENCE.md`（契约方法）、`docs/CONTRACT.md`（契约与错误码）、
> `fixtures/`（脱敏真实响应）。上游源码只作历史考据与对照用。
