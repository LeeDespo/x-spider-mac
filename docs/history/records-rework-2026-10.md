# 记录体系重做 —— 当轮实施状态与决定（2026-10-02）

> **历史归档。** 记录体系换代（`MEDIA_RECORDS.md` 的 §3–§9）落地当轮的快照。
> 当前事实以 `MEDIA_RECORDS.md` 为准；本文件只保留「当时落到哪个文件」与
> 「当时决定不做什么」，用于追溯。**不要把这里的状态表当成"还没做"的待办。**

## 实施状态

| 项 | 状态 | 落点 |
|---|---|---|
| §3 两类记录 · 四个文件的路径与形状 | ✅ | `Services/MediaRecords.swift` |
| §4 数据形状 v1（kind/version 校验、原子写、键序与空集合的精确字节） | ✅ | `Services/MediaRecords.swift`（`RecordJSONWriter`） |
| §5 命名（账号文件夹复用 / 文件名唯一标识 / 模板变量） | ✅ | `Support/AccountFolder.swift`、`Services/FileNameTemplate.swift`、`Services/MediaJudgement.swift` |
| §6.1–6.2 下载判定三选一 + 开关联动 | ✅ | `Stores/DownloadStore.swift` |
| §6.3 同步窗口语义 | ✅ | `Stores/SyncStore.swift` |
| §7 导入导出（形态由 `recordsForm` 决定 + 无法定位报告） | ✅ | `Services/RecordsIO.swift` |
| §8 按文件名重建记录 | ✅ | `Services/RecordsIO.swift` |
| §9 设置字段与一次性覆盖（`settingsSchemaVersion = 2`） | ✅ | `Models/Settings.swift`、`Stores/SettingsStore.swift` |
| §9 设置界面（记录形态 / 三个按钮） | ✅ | `Views/SettingsView.swift` |

## 当轮不做的事

| 不做 | 理由 |
|---|---|
| **旧数据迁移**：读旧 `.downloaded.json` / 旧 `.synced.json` 形状、补齐旧记录缺失的字段 | 记录体系换代（`MEDIA_RECORDS.md` §2）；缺字段即整份丢弃，按"没有记录"处理 |
| **迁移 / 改名 / 删除旧账号文件夹**（`昵称-@用户名`） | 不兼容旧命名；旧文件夹原地不动，用户自己决定怎么处理 |
| **把旧设置值映射成新值**（`recordFile` / `syncRecordFile` 等） | 由一次性覆盖顶掉（`MEDIA_RECORDS.md` §9.2）；映射留下会让用户每次重启被改回兜底值 |
| **联网深度修复**：按推文 id 反查老文件、重建旧记录 | 需要大量请求、收益不确定；重建入口是离线的「按文件名重建」 |

## 给后续维护的提醒

上面这些不是"还没做"，是**当轮的决定**。看到老配置里是
`recordFile` / `syncRecordFile` / 分布式、看到旧文件夹与旧记录文件还在原地，
都不要去"修"——覆盖已经把新默认值写进持久化，旧值失联是预期结果。
