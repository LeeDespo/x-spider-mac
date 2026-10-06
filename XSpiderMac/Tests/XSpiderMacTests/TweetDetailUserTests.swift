// 本文件的原用例是 raw upstream 用户结构（legacy/core 双结构回退），
// 已随 legacy 解析清理删除：结构归一化是组件 `x-spider-core` 的职责，
// 契约里作者只有一种紧凑形状。契约形状的 user/post → 应用模型覆盖
// 见 `XSpiderMappingTests`。
//
// （整理方案 plan-v2 原计划整文件删除；本轮执行约束不增删文件，
// 待下次重跑 `xcodegen generate` 时一并移除。）
