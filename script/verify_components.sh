#!/usr/bin/env bash
# 组件账本校验（只读，不改动任何文件）。
#
# 校验随包二进制（XSpiderMac/Resources/Binaries/ 下的 xspiderd 与 aria2next）
# 与账本 components.lock.json 的一致性，依序检查：
#   1. components.lock.json 存在且是合法 JSON；
#   2. xspiderd / aria2next 两个二进制存在；
#   3. 两个二进制均为 arm64 Mach-O；
#   4. 两个二进制均有可执行位；
#   5. 两个二进制的 SHA256 与 lock 记录一致；
#   6. xspiderd --version 可运行，且契约主版本 == lock 的 contractMajor；
#   7. lock 的 contractMajor == 外壳握手常量（XSpiderComponent.swift 的
#      supportedContractMajor 字面值）。
#
# 任一项失败：打印 ✗ 与具体原因后 exit 1（首个失败即退出，前面各项的 ✓ 已逐项打印）。
# 调用方：script/package_dmg.sh（打包前置）、CI、人工更换组件之后。
#
# 口径说明：lock 的 sha256 记录的是**随包二进制自身**的哈希（shasum -a 256 该文件），
# 不是 Release tar.gz 的——bundled 与 Release 资产字节互异；lock 的 tag / asset
# 只是升级对账锚，不参与本机校验。运行时兼容的真源仍是 system.version 握手，
# lock 里的 contractMajor 只作部署对账。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/XSpiderMac/Resources/Binaries"
LOCK="${BIN_DIR}/components.lock.json"
SWIFT_CLIENT="${REPO_ROOT}/XSpiderMac/Sources/XSpiderMac/Services/XSpiderComponent.swift"

ok()   { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; exit 1; }

# 从 lock 取字段：read_lock <节> <字段>（节：xspiderCore / aria2next）
read_lock() {
  python3 - "$LOCK" "$1" "$2" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print(data[sys.argv[2]][sys.argv[3]])
PY
}

echo "==> 校验随包组件（账本：components.lock.json）"

# 1. lock 存在且可解析
[[ -f "${LOCK}" ]] || fail "components.lock.json 不存在：${LOCK}"
python3 -m json.tool "${LOCK}" >/dev/null 2>&1 || fail "components.lock.json 不是合法 JSON"
ok "components.lock.json 存在且可解析"

# 2. 两个二进制存在
for name in xspiderd aria2next; do
  [[ -f "${BIN_DIR}/${name}" ]] || fail "缺少随包二进制：${BIN_DIR}/${name}"
done
ok "xspiderd / aria2next 两个二进制都存在"

# 3. arm64 Mach-O（两文件各自检查）
for name in xspiderd aria2next; do
  if ! file "${BIN_DIR}/${name}" | grep -q "Mach-O 64-bit executable arm64"; then
    fail "${name} 不是 arm64 Mach-O（file 输出：$(file -b "${BIN_DIR}/${name}")）"
  fi
done
ok "两个二进制均为 Mach-O 64-bit executable arm64"

# 4. 可执行位
for name in xspiderd aria2next; do
  [[ -x "${BIN_DIR}/${name}" ]] || fail "${name} 没有可执行位"
done
ok "两个二进制都有可执行位"

# 5. SHA256 与 lock 一致（xspiderd 对应 lock 的 xspiderCore 节）
for name in xspiderd aria2next; do
  section="aria2next"
  [[ "${name}" == "xspiderd" ]] && section="xspiderCore"
  expected="$(read_lock "${section}" sha256)" || fail "lock 里读不到 ${section}.sha256"
  actual="$(shasum -a 256 "${BIN_DIR}/${name}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${name} 的 SHA256 与 lock 不一致：实际 ${actual}，lock 记录 ${expected}"
done
ok "两个二进制的 SHA256 与 lock 一致"

# 6. xspiderd --version 可运行，契约主版本 == lock 的 contractMajor
expected_major="$(read_lock xspiderCore contractMajor)" || fail "lock 里读不到 xspiderCore.contractMajor"
version_output="$("${BIN_DIR}/xspiderd" --version)" || fail "xspiderd --version 运行失败（exit $?）"
# 输出形如「xspiderd 0.1.0 (契约版本 1.5.1)」，契约版本锚定「契约版本」标签提取
contract_version="$(printf '%s\n' "${version_output}" \
  | grep -oE '契约版本[[:space:]]*[0-9]+(\.[0-9]+){2}' \
  | grep -oE '[0-9]+(\.[0-9]+){2}' | tail -1 || true)"
[[ -n "${contract_version}" ]] \
  || fail "无法从 xspiderd --version 输出解析契约版本（输出：${version_output}）"
actual_major="${contract_version%%.*}"
[[ "${actual_major}" == "${expected_major}" ]] \
  || fail "契约主版本不一致：xspiderd 自报 ${contract_version}（主版本 ${actual_major}），lock 的 contractMajor 是 ${expected_major}"
ok "xspiderd --version 可运行，契约主版本（${contract_version}）主段 == lock 的 contractMajor（${expected_major}）"

# 7. lock 的 contractMajor == 外壳握手常量 supportedContractMajor
swift_major="$(grep -oE 'supportedContractMajor[[:space:]]*=[[:space:]]*"[^"]+"' "${SWIFT_CLIENT}" \
  | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[[ -n "${swift_major}" ]] || fail "无法从 XSpiderComponent.swift 提取 supportedContractMajor 的字面值"
[[ "${swift_major}" == "${expected_major}" ]] \
  || fail "lock 的 contractMajor（${expected_major}）与外壳握手常量 supportedContractMajor（${swift_major}）不一致"
ok "lock 的 contractMajor == 外壳握手常量 supportedContractMajor（${swift_major}）"

echo "==> 组件账本校验全部通过"
