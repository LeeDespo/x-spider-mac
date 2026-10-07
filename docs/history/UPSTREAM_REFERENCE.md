# 历史来源

XSpiderMac 早期开发曾参考 [MiningCattiva/x-spider](https://github.com/MiningCattiva/x-spider)。
当前项目的 SwiftUI 应用、架构与构建链均独立维护；该项目只作为历史来源与致谢保留，
**不是现行实现、契约或 X 行为的真源**。

## 来源记录

- 历史参考仓库：<https://github.com/MiningCattiva/x-spider>
- 最后已知上游 commit：`252a9001215105593a3851d8b1eb0d8b185049af`
- 本仓库保留完整 Git 提交历史；如需做许可证、来源或演进考据，应直接查 Git 历史，
  不把旧 `src/`、`src-tauri/` 重新恢复到当前工作树。

## 当前职责归属

X 请求构造、GraphQL、端点、queryId/features、原始响应解析、分页、限流、爬取与下载引擎
全部由 [x-spider-core](https://github.com/LeeDespo/x-spider-core) 负责。

需要核对 X 行为或契约时，直接查看 core 仓库的 `docs/CONTRACT.md`、
`docs/07-API-REFERENCE.md`、实现、fixture 与测试。

本仓库只记录 **macOS 应用如何消费 core 契约**，不再保存 X 端点行为盘点或历史解析规则。
