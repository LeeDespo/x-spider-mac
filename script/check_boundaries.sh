#!/usr/bin/env bash
#
# check_boundaries.sh — 外壳边界护栏
#
# x-spider-mac 是纯产品外壳：X 协议细节（端点路径、queryId、features flag、
# 请求签名头、广告/回复流标记）与下载引擎实现（aria2 RPC）只属于组件
# x-spider-core，外壳只做契约 JSON ↔ 应用模型的映射。本脚本扫描生产源码
# （XSpiderMac/Sources/ 下全部 .swift，不含 Tests），一旦出现下列
# 「明显协议泄漏」级别的 token，打印 文件:行: token 并以非零码退出，
# 阻止这类实现特征重新溜进外壳。
#
# 豁免边界（合法用法不会被命中，无需行级豁免）：
# - XSpiderComponent 的本地 JSON-RPC（http://127.0.0.1:<port>/、
#   X-XSpider-Token、POST /）是外壳↔组件的唯一合法接口，这些字符串不
#   含任何禁止 token，天然不在命中面；
# - 一般 URLSession 使用（ImageCache 等图片/媒体加载）不受限——本脚本
#   只拦协议特征，不拦网络 API 本身。
#
# token 清单依据 .agents/organize/plan-v2.md §3.4，其中 plan 初稿的
# `aria2.` 整体前缀已按「命中面校准」缩窄为真正的 RPC 特征：`aria2.`
# 会误伤现役合法标识符（AppDirectories.swift 的 aria2 会话目录、
# XSpiderComponent.swift 传给 sidecar 的 XSPIDER_ARIA2_PATH），而组件化
# 之前的 Aria2RPCClient 实际形状是 aria2.addUri / aria2.tellStatus /
# --enable-rpc / --rpc-secret，缩窄后恰好覆盖回归、不误伤现役代码。
#
# 注释剥离（行级近似）：// 行注释与 /* */ 块注释中的内容不参与匹配，
# 文档注释里提及 token（如解释设计时写到 queryId）不算泄漏。唯一的例外
# 是 "scheme://" 形态（如 https://）——它出现在字符串字面量里，若当注释
# 剥掉会漏掉藏在 URL 中的泄漏，因此仅当斜杠紧跟「非空格字符+冒号」之后
# 才不作注释处理。行级近似不解析 Swift 字符串字面量边界：多行字符串中
# 形似注释的内容可能被误剥（方向是宁漏勿误伤），块注释跨行按状态机处理。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${REPO_ROOT}/XSpiderMac/Sources"

if [ ! -d "${SRC_DIR}" ]; then
  echo "✗ 找不到生产源码目录：${SRC_DIR}" >&2
  exit 2
fi

# 禁止 token 清单（大小写敏感，grep -F 逐行精确匹配）。
TOKENS=(
  'api.x.com/graphql'        # X API GraphQL 端点根
  'x.com/i/api'              # X 私有 REST 路径
  '/graphql'                 # GraphQL 路径片段（兜住拼接出来的端点路径）
  'responsive_web_'          # 上游 features flag 值的前缀
  'x-client-transaction-id'  # X 请求签名头
  'queryId'                  # X GraphQL 操作 ID（自愈逻辑在组件里）
  'features'                 # features 请求体 JSON 键 / 常量名
  'promotedMetadata'         # X 广告标记（广告过滤在组件里）
  'conversationthread'       # X 回复流 entryId 前缀（解析在组件里）
  'aria2.addUri'             # aria2 RPC：创建下载
  'aria2.tellStatus'         # aria2 RPC：轮询进度
  'aria2.getGlobalStat'      # aria2 RPC：全局统计
  'enable-rpc'               # aria2 RPC 服务端启动旗标（--enable-rpc）
  'rpc-secret'               # aria2 RPC 鉴权旗标（--rpc-secret=…）
)

# 注释剥离：对每个输入行输出一行（保持行号不变），剥离规则见文件头注释。
strip_comments() {
  awk '
    BEGIN { inblock = 0 }
    {
      line = $0; out = ""; n = length(line)
      prev = ""; prev2 = ""
      i = 1
      while (i <= n) {
        two = substr(line, i, 2)
        if (inblock) {
          if (two == "*/") { inblock = 0; i += 2; prev = "*"; prev2 = "*" }
          else { i += 1 }
          continue
        }
        if (two == "/*") { inblock = 1; i += 2; continue }
        if (two == "//") {
          # "scheme://"（如 https://）是字符串字面量里的协议头，不当注释
          if (!(prev == ":" && prev2 ~ /[A-Za-z0-9]/)) break
        }
        out = out substr(line, i, 1)
        prev2 = prev; prev = substr(line, i, 1)
        i += 1
      }
      print out
    }
  '
}

hits_file="$(mktemp)"
stripped_file="$(mktemp)"
trap 'rm -f "${hits_file}" "${stripped_file}"' EXIT

file_count=0
while IFS= read -r -d '' f; do
  file_count=$((file_count + 1))
  rel="${f#"${REPO_ROOT}"/}"
  LC_ALL=C strip_comments < "${f}" > "${stripped_file}"
  for token in "${TOKENS[@]}"; do
    # grep -n 输出 "行号:剥离后内容"，取行号拼成 文件:行: token
    grep -n -F -- "${token}" "${stripped_file}" \
      | awk -v t="${token}" -v file="${rel}" -F: '{print file ":" $1 ": " t}' \
      >> "${hits_file}" || true
  done
done < <(find "${SRC_DIR}" -type f -name '*.swift' -print0 | LC_ALL=C sort -z)

if [ "${file_count}" -eq 0 ]; then
  echo "✗ 未扫描到任何 .swift 文件，护栏失效，请检查源码目录" >&2
  exit 2
fi

if [ -s "${hits_file}" ]; then
  echo "✗ 边界护栏命中——以下文件出现 X 协议 / 下载引擎实现特征（外壳只做契约映射）："
  LC_ALL=C sort "${hits_file}"
  echo ""
  echo "共 $(wc -l < "${hits_file}" | tr -d ' ') 处命中。处理办法：删掉或迁移该实现"
  echo "（X 取数与下载归组件 x-spider-core），不要在脚本里加豁免注释放宽。"
  exit 1
fi

echo "✓ 边界护栏通过：扫描 ${file_count} 个 .swift（XSpiderMac/Sources/），未命中禁止 token"
exit 0
