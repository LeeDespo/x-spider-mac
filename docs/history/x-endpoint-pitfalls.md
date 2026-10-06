# X 取数与解析的坑（历史归档）

> **归档说明**：本仓库存放的是外壳（映射 + UI + 记录 + 命名）。文中这些坑的**实现
> 自 2026-10-01 起全部在组件 `x-spider-core`**——出问题去组件仓库修，不要在
> 外壳映射层打补丁。X 端点行为的**现行权威**是组件仓库的
> `docs/02-X-DOMAIN-NOTES.md`、`docs/07-API-REFERENCE.md`、`docs/CONTRACT.md`
> 与 `fixtures/`。本文只保留"现象 → 根因"的**历史叙事**（证据与出处），
> 不再是规范；外壳侧仍然现役的对应纪律在 `../ARCHITECTURE.md`（视口节奏、
> 停止条件、日期边界等）。
>
> 上游出处与找回方法见 `UPSTREAM_REFERENCE.md`；下文提及的上游文件
> （`twitter/api.ts`、`stores/homepage.ts`、`components/InfiniteScroll.tsx` 等）
> 均相对上游前端源码树根，该源码已从本仓库移除。

## 1. 分页语义（组件实现；外壳只需保证传参正确）

1. **首页必须省略 `cursor` 键**（不是传 `null`）——上游 `JSON.stringify` 会丢弃
   `undefined` 键，把 `variables.cursor` 硬编码成 `null` 会让**每一页都请求第一页**，
   表现为"无限加载 / 创建任务重复检索同一页"，这是分页类故障的总根源。
   翻页才传真实 cursor。
2. **爬虫循环里 `continue` 前必须先推进 cursor**：上游语义是 fetch 返回后第一件事就是
   `nextCursor = cursor`，日期/类型过滤在推进**之后**。先过滤再推进会让同一页被无限重抓。
3. **空页必须终结**：上游 `getUserMedias` 解析出 0 条时返回 `cursor: null`（到底信号）。
   判据是**服务端原始条数**，不是客户端筛选后的条数。
4. **游标不推进即判到底**：X 偶发回吐相同 cursor，原地空转会刷爆配额（"翻页偶发卡死"）。
5. **把"翻到服务端尽头"当成无限滚动**是产品侧教训：上游 `components/InfiniteScroll.tsx`
   只补拉到视口填满（约两屏），剩余靠用户滚动逐页触发。无停止条件的连发循环
   触发过 **429 限流风暴**。（视口节奏作为外壳产品纪律保留，见 `../ARCHITECTURE.md` §3.1；
   令牌桶闸门、429 熔断与 X API / 媒体 CDN 分开治理在组件。）

## 2. 响应解析（组件实现）

- **focal 推文必须按 ID 精确取**，否则详情会弹成别人的推文。
- **引用推文在 `result.quoted_status_result.result`**，**不是**
  `legacy.quoted_status_result`——写错路径的症状是"引用卡永远空白"。
- **转推有两种包裹键**、**用户字段有新老两种结构**——两处都要兼容。
- **广告判据是 `item.itemContent.promotedMetadata` 非空**（实测每会话约 3 条），
  TweetDetail 的 `conversationthread-*` 会插广告，**所有解析入口都要过滤**，
  漏一个就会在对应界面露出广告。过滤在组件；外壳拿到的是已清数据
  （`../ARCHITECTURE.md` §4）。
- **评论树**：契约给 `parent_id` / `in_reply_to_screen_name`，层级构建与孤儿处理
  是外壳映射纪律（`../ARCHITECTURE.md` §4）；服务端返回结构的事实以 core
  `docs/02` 为准。

## 3. 搜索端点（组件实现）

- **SearchTimeline 必须 POST + JSON body，GET 一律 404**——且**这个 404 与 queryId
  无关**：实测新旧两个 queryId 用 POST 都返回 200，只有随机乱写的才 404。
  历史教训：曾用 GET 试、误判成"queryId 失效"，白做了一轮自愈。
- **queryId 自愈在组件**（外壳的 `SearchQueryIdProvider` 已删除）：自愈会抓 `/search`
  页面，且**必须带凭据**——匿名会被 307 到 onboarding。
- 外壳只传 `screen_name` / `since` / `until` / `media_only` / `count` / `cursor`
  （参数表见 `../COMPONENTS.md` §2）。
- **日期语义**：契约 `since` / `until` 是**用户本地日历日期、含当天**，组件内部按排他
  语义 **+1 天**——外壳不要再自己加一天。爬取侧按 **UTC 天**粗筛、外壳 `decide`
  按本地日历精判的分工见 `../ARCHITECTURE.md` §5.1（历史上外壳拼 UTC 日期串曾导致
  "范围整体偏移一天"）。

## 4. 爬取终止判据（组件实现，外壳同语义）

- 判定"到底"只看**服务端原始条数**；客户端筛选的终止判据是**时间轴推进**
  （`oldestSeenAt < since`，与爬虫 `now > since` 同义）。
- **不要用"连续空页计数"判停**：账号停更一两个月的空窗期会被误判成"没有内容"
  （用户实测反馈）。计数若取筛选后的页，同样不推进。
- 去重必须先于筛选（外壳侧现役表述见 `../ARCHITECTURE.md` §5.2）。

## 5. 评论与引用的边界（X 服务端行为，不是 bug）

- **评论的评论只有贴主的**：实测以评论为 focal 也只返回贴主那条，且无"更多回复"
  游标——别再为此改解析（README 已知限制同步此条）。
- **X 的视频一般没有内嵌字幕**，因此不提供字幕选择。
- **搜索结果可能有极个别遗漏**：浏览走搜索接口求快，而下载始终由爬虫逐页抓取，
  会把遗漏补上。

## 6. 取消与重试（组件实现）

**同一毫秒刷出 5400 行取消重试日志**：根因是取消被当成可重试错误 +
`try? await Task.sleep` 在取消时立即返回 → 重试循环空转。解法（组件里）：
取消抛取消错误、不重试；取消感知睡眠。外壳侧只需按结构化 `reason` / `status`
决定重试（`DownloadStore.isRetryable`），见 `../COMPONENTS.md` §2。

## 7. 视频字幕（功能已随 1.0.0 移除，纪律留作重做时用）

若将来重做"内嵌字幕选择"：用 **AVFoundation 媒体选择 API**（`select(_:in:)` 等，
均为 macOS 10.8+，远低于基线 15.0，**不要写版本判断**）；选的是视频**内嵌**字幕轨；
X 视频多数没有，此时按钮不显示属正常。它与"实时翻译字幕"（现行翻译能力用系统
`Translation` 框架，见 `../ARCHITECTURE.md` §7.7）不是一回事。
