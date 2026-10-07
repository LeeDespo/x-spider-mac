#!/usr/bin/env bash
# 组件升级：从 GitHub Release 下载新的组件二进制，校验后原子替换随包文件，
# 并回写 components.lock.json。
#
# 本脚本是 components.lock.json 的**唯一写手**（不许手改 lock 后与二进制不一致地提交）：
# 换二进制后重算 SHA256，并按目标 Release 回写 version / tag / asset。
#
# 用法：
#   script/update_components.sh xspiderd                    # 用 lock 里记录的 tag/asset
#   script/update_components.sh aria2next --tag v2.8.6      # 指定目标 tag（资产名按既有命名规则推导）
#
# 流程：
#   1) 前置检查：git 工作区干净（二进制与 lock 必须同一个 commit 提交）；
#      lock 里出现 TODO 字段直接报错退出（不许猜下载地址）；
#   2) 读 lock 得 repository / tag / asset；
#   3) 下载 Release 资产 + 官方校验文件，校验 SHA256（下载期完整性，与 lock 无关）；
#   4) staging：取二进制本体写入 <name>.tmp → 确认 arm64 Mach-O → chmod +x →
#      xattr -cr（漏了会被 Gatekeeper 以退出码 137 静默杀死）→ codesign ad-hoc；
#   5) 原子替换 XSpiderMac/Resources/Binaries/<name>（同目录 mv -f）；
#   6) 重算 SHA256 回写 lock（xspiderd 的 version/contractMajor 取新二进制自报值）；
#   7) 同步 THIRD_PARTY_NOTICES.md 里 aria2next 的版本号（如有变化）；
#   8) 收尾跑 script/verify_components.sh 作总闸。
#
# 资产形态（按两个仓库现行 Release 的实际资产）：
#   xspiderd  → tar.gz（内含 xspiderd / libxspider.dylib / schema / LICENSE /
#               NOTICE / CHANGELOG），本脚本**只取 xspiderd 本体**（外壳走 sidecar
#               模式，不需要 dylib）；
#   aria2next → 裸二进制；校验文件是上游汇总的 aria2-next-<版本>-checksums.sha256。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/XSpiderMac/Resources/Binaries"
LOCK="${BIN_DIR}/components.lock.json"
NOTICES="${REPO_ROOT}/THIRD_PARTY_NOTICES.md"

usage() {
  echo "用法：script/update_components.sh xspiderd|aria2next [--tag vX.Y.Z]" >&2
  exit 2
}

fail() { echo "✗ $1" >&2; exit 1; }

COMPONENT="${1:-}"
[[ "${COMPONENT}" == "xspiderd" || "${COMPONENT}" == "aria2next" ]] || usage
shift

TARGET_TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || usage
      TARGET_TAG="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

# lock 节名：xspiderd 对应 lock 的 xspiderCore 节
SECTION="xspiderCore"
[[ "${COMPONENT}" == "aria2next" ]] && SECTION="aria2next"

# 从 lock 取字段：read_lock <字段>
read_lock() {
  python3 - "$LOCK" "${SECTION}" "$1" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print(data[sys.argv[2]][sys.argv[3]])
PY
}

echo "==> 组件升级：${COMPONENT}"

# ── 前置 1：lock 不得含 TODO（有 TODO 说明账本没建齐，不许猜 URL）──────────────
if grep -q "TODO" "${LOCK}"; then
  fail "components.lock.json 含 TODO 字段：先补齐账本再升级（不许猜下载地址）"
fi

# ── 前置 2：git 工作区干净（二进制与 lock 必须同一个 commit 提交）───────────────
if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]]; then
  fail "git 工作区不干净：组件二进制与 lock 必须同一个 commit 提交（git status --porcelain 有输出），请先提交或暂存"
fi

REPOSITORY="$(read_lock repository)" || fail "lock 里读不到 ${SECTION}.repository"
ASSET="$(read_lock asset)"           || fail "lock 里读不到 ${SECTION}.asset"
OLD_VERSION="$(read_lock version)"   || fail "lock 里读不到 ${SECTION}.version"

# 目标 tag：命令行 > lock 的 tag 字段 > lock 的 version 加 v 前缀（aria2next 节无 tag 字段）
LOCK_TAG="$(read_lock tag || true)"
if [[ -n "${TARGET_TAG}" ]]; then
  TAG="${TARGET_TAG}"
elif [[ -n "${LOCK_TAG}" ]]; then
  TAG="${LOCK_TAG}"
else
  TAG="v${OLD_VERSION}"
fi
VERSION="${TAG#v}"

# 指定 --tag 时按既有命名规则推导资产名（与两个仓库现行 Release 资产命名一致）
if [[ -n "${TARGET_TAG}" ]]; then
  case "${COMPONENT}" in
    xspiderd)  ASSET="xspiderd-${VERSION}-macos-arm64.tar.gz" ;;
    aria2next) ASSET="aria2-next-${VERSION}-macos-arm64" ;;
  esac
fi

BASE_URL="https://github.com/${REPOSITORY}/releases/download/${TAG}"
ASSET_URL="${BASE_URL}/${ASSET}"
case "${COMPONENT}" in
  xspiderd)  CHECKSUM_URL="${ASSET_URL}.sha256" ;;  # Release 自带的 .sha256 sidecar
  aria2next) CHECKSUM_URL="${BASE_URL}/aria2-next-${VERSION}-checksums.sha256" ;;
esac

echo "==> 下载：${ASSET_URL}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
curl -fSL --retry 3 -o "${WORK}/${ASSET}" "${ASSET_URL}" \
  || fail "下载失败：${ASSET_URL}"
curl -fSL --retry 3 -o "${WORK}/CHECKSUMS" "${CHECKSUM_URL}" \
  || fail "下载校验文件失败：${CHECKSUM_URL}"

# 从官方校验文件提取本资产的 SHA256
# （sidecar 可能是「哈希  文件名」，也可能只有裸哈希；汇总文件则按资产名取行）
if grep -q "${ASSET}" "${WORK}/CHECKSUMS"; then
  EXPECTED_SHA="$(grep "${ASSET}" "${WORK}/CHECKSUMS" | grep -oE '[0-9a-fA-F]{64}' | head -1)"
else
  EXPECTED_SHA="$(grep -oE '[0-9a-fA-F]{64}' "${WORK}/CHECKSUMS" | head -1)"
fi
[[ -n "${EXPECTED_SHA}" ]] || fail "校验文件里找不到 ${ASSET} 的 SHA256：${CHECKSUM_URL}"
ACTUAL_SHA="$(shasum -a 256 "${WORK}/${ASSET}" | awk '{print $1}')"
[[ "${ACTUAL_SHA}" == "$(printf '%s' "${EXPECTED_SHA}" | tr 'A-Z' 'a-z')" ]] \
  || fail "下载物 SHA256 与官方校验文件不一致：实际 ${ACTUAL_SHA}，校验文件记录 ${EXPECTED_SHA}"
echo "==> 下载物 SHA256 与官方校验文件一致"

# ── staging：取二进制本体 → tmp → arm64 确认 → chmod → xattr → ad-hoc 签名 ────
if [[ "${COMPONENT}" == "xspiderd" ]]; then
  mkdir -p "${WORK}/extract"
  # 资产内布局不保证扁平（v0.1.0 是 <name>-<version>-macos-arm64/ 子目录），
  # 按 basename 定位 xspiderd 本体
  MEMBER="$(tar -tzf "${WORK}/${ASSET}" | grep -E '(^|/)xspiderd$' | head -1)" \
    || fail "tar 里找不到 xspiderd 本体：${ASSET}"
  [[ -n "${MEMBER}" ]] || fail "tar 里找不到 xspiderd 本体：${ASSET}"
  tar -xzf "${WORK}/${ASSET}" -C "${WORK}/extract" "${MEMBER}" \
    || fail "解包失败：${ASSET}"
  SOURCE_BIN="${WORK}/extract/${MEMBER}"
else
  SOURCE_BIN="${WORK}/${ASSET}"
fi

STAGE="${BIN_DIR}/${COMPONENT}.tmp"
cp "${SOURCE_BIN}" "${STAGE}"
chmod +x "${STAGE}"

file "${STAGE}" | grep -q "Mach-O 64-bit executable arm64" \
  || fail "新二进制不是 arm64 Mach-O：$(file -b "${STAGE}")"

# xattr 必须在签名**之前**：带着 quarantine 属性的未签名二进制会被 Gatekeeper
# 以退出码 137 静默杀死（见仓库 AGENTS.md 的部署事故纪律）
xattr -cr "${STAGE}"
codesign --force --sign - "${STAGE}"

# ── 原子替换（同目录 mv，原子生效）────────────────────────────────────────────
mv -f "${STAGE}" "${BIN_DIR}/${COMPONENT}"
echo "==> 已替换：${BIN_DIR}/${COMPONENT}"

# ── 回写 lock（本脚本是唯一写手）─────────────────────────────────────────────
NEW_SHA="$(shasum -a 256 "${BIN_DIR}/${COMPONENT}" | awk '{print $1}')"

if [[ "${COMPONENT}" == "xspiderd" ]]; then
  # xspiderd 的 version / contractMajor 以**新二进制自报**为准
  VERSION_OUTPUT="$("${BIN_DIR}/${COMPONENT}" --version)" \
    || fail "新 xspiderd --version 运行失败"
  BUILD_VERSION="$(printf '%s\n' "${VERSION_OUTPUT}" | sed -E 's/^xspiderd ([0-9.]+) .*/\1/')"
  [[ "${BUILD_VERSION}" =~ ^[0-9.]+$ ]] \
    || fail "无法从 --version 解析 build 版本（输出：${VERSION_OUTPUT}）"
  CONTRACT_MAJOR="$(printf '%s\n' "${VERSION_OUTPUT}" \
    | grep -oE '契约版本[[:space:]]*[0-9]+(\.[0-9]+){2}' \
    | grep -oE '^[0-9]+' | tail -1)"
  [[ -n "${CONTRACT_MAJOR}" ]] \
    || fail "无法从 --version 解析契约主版本（输出：${VERSION_OUTPUT}）"
  python3 - "$LOCK" "$NEW_SHA" "$BUILD_VERSION" "$TAG" "$ASSET" "$CONTRACT_MAJOR" <<'PY'
import json, sys
path, sha, version, tag, asset, major = sys.argv[1:7]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["xspiderCore"].update(sha256=sha, version=version, tag=tag, asset=asset, contractMajor=major)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
else
  python3 - "$LOCK" "$NEW_SHA" "$VERSION" "$ASSET" <<'PY'
import json, sys
path, sha, version, asset = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["aria2next"].update(sha256=sha, version=version, asset=asset)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
fi
echo "==> 已回写 lock（sha256 / version / tag / asset）"

# ── 同步 THIRD_PARTY_NOTICES.md 里 aria2next 的版本号（如有变化）──────────────
# 该文件里的裸版本号 token 全部属于 aria2next 条目（xspiderd 条目不写死版本，指向 lock）
if [[ "${COMPONENT}" == "aria2next" && "${OLD_VERSION}" != "${VERSION}" ]] \
   && [[ -f "${NOTICES}" ]] && grep -q "${OLD_VERSION}" "${NOTICES}"; then
  OLD_ESC="${OLD_VERSION//./\\.}"
  sed -i '' "s/${OLD_ESC}/${VERSION}/g" "${NOTICES}"
  echo "==> 已同步 THIRD_PARTY_NOTICES.md 的版本号：${OLD_VERSION} → ${VERSION}"
fi

# ── 收尾总闸：账本与二进制必须完全一致 ────────────────────────────────────────
"${REPO_ROOT}/script/verify_components.sh"
echo "==> 组件升级完成：${COMPONENT} ${OLD_VERSION} → ${VERSION}"
