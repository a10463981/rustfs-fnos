#!/bin/bash
# stamp-manifest.sh —— 把「版本唯一真源」（git tag / CI 传入值）注入 fpk 项目的 manifest
#
# 只改三个键：version / platform / changelog。其余键、注释、空行、对齐风格、`"""多行值"""` 一律原样保留。
# 仓库里的 manifest 恒为 version = 0.0.0 占位，真值由本脚本在 CI 里注入。
#
# 用法：
#   scripts/stamp-manifest.sh <fpk 项目目录> --version 1.2.3 [--platform x86] [--changelog "一句话"]
#   scripts/stamp-manifest.sh <fpk 项目目录>                       # 从 GITHUB_REF_NAME 推导（v1.2.3 → 1.2.3）
#
# 退出码：0 成功（可能无改动）｜1 输入非法 ｜2 用法错误
#
# 为什么单独成脚本：manifest.version 是 tag 的下游，绝不能手改；
# 而 sed 在键不存在时会静默不替换——CI 里必须有「改完回读断言」这一步兜住。

set -uo pipefail

PROJECT=""
VERSION=""
PLATFORM=""
CHANGELOG=""
CHANGELOG_SET=0

die_usage() { echo "用法错误：$*" >&2; exit 2; }
die_input() { echo "输入非法：$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   VERSION="${2:-}"; shift 2 ;;
    --platform)  PLATFORM="${2:-}"; shift 2 ;;
    --changelog) CHANGELOG="${2:-}"; CHANGELOG_SET=1; shift 2 ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    -*)          die_usage "未知选项 $1" ;;
    *)           [ -z "${PROJECT}" ] && PROJECT="$1" || die_usage "多余参数 $1"; shift ;;
  esac
done

[ -n "${PROJECT}" ] || die_usage "必须给出 fpk 项目目录"
MANIFEST="${PROJECT}/manifest"
[ -f "${MANIFEST}" ] || die_input "找不到 manifest：${MANIFEST}"

# ---- version：优先参数，其次 GITHUB_REF_NAME（去掉 v 前缀）----
if [ -z "${VERSION}" ]; then
  REF="${GITHUB_REF_NAME:-}"
  [ -n "${REF}" ] || die_input "没有 --version，也没有 GITHUB_REF_NAME 可推导"
  VERSION="${REF#v}"
fi

# 只接受 x.y.z 或 x.y.z-<整数>（fnpack 1.2.3/1.2.4 都只认这个形态；1.0.0-beta 会被拒）
case "${VERSION}" in
  *[!0-9.-]*) die_input "版本号含非法字符：${VERSION}（只允许数字、点、连字符）" ;;
esac
if ! printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$'; then
  die_input "版本号形态非法：${VERSION}（只接受 x.y.z 或 x.y.z-<整数>，例如 1.2.3 / 1.2.3-1）"
fi

# ---- platform：只接受 fnpack 认的五个值 ----
if [ -n "${PLATFORM}" ]; then
  case "${PLATFORM}" in
    x86|arm|loongarch|risc-v|all) : ;;
    *) die_input "platform 非法：${PLATFORM}（允许 x86 / arm / loongarch / risc-v / all）" ;;
  esac
fi

# ---- 单键替换：保留「键 + 等号 + 对齐空白」，只换值；键不存在则追加 ----
# 显式跳过以 """ 开头的多行值（changelog 可能写成多行，硬替换会破坏格式）
set_key() {
  local key="$1" value="$2" file="$3" skip_multiline="$4"
  local tmp="${file}.stamp.$$"
  if ! awk -v k="${key}" -v v="${value}" -v skipml="${skip_multiline}" '
    BEGIN { done = 0 }
    {
      line = $0
      if (!done && line ~ ("^[ \t]*" k "[ \t]*=")) {
        if (skipml == "1" && line ~ /"""/) {
          print "  SKIP  " k "（多行值 \"\"\"…\"\"\"，本脚本不动它）" > "/dev/stderr"
          print line
          done = 1
          next
        }
        match(line, "^[ \t]*[A-Za-z0-9_]+[ \t]*=[ \t]*")
        printf "%s%s\n", substr(line, 1, RLENGTH), v
        done = 1
        next
      }
      print line
    }
    END { if (!done) printf "%s = %s\n", k, v }
  ' "${file}" > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  mv "${tmp}" "${file}"
  chmod 644 "${file}" 2>/dev/null || true
  return 0
}

BEFORE="$(mktemp 2>/dev/null || echo "/tmp/stamp-before.$$")"
cp "${MANIFEST}" "${BEFORE}"

set_key version  "${VERSION}"   "${MANIFEST}" 0 || die_input "写入 version 失败"
[ -n "${PLATFORM}" ]  && { set_key platform "${PLATFORM}" "${MANIFEST}" 0 || die_input "写入 platform 失败"; }
[ "${CHANGELOG_SET}" = "1" ] && { set_key changelog "${CHANGELOG}" "${MANIFEST}" 1 || die_input "写入 changelog 失败"; }

echo "== stamp =="
echo "  文件   : ${MANIFEST}"
echo "  version: ${VERSION}"
[ -n "${PLATFORM}" ] && echo "  platform: ${PLATFORM}"
[ "${CHANGELOG_SET}" = "1" ] && echo "  changelog: ${CHANGELOG}"

echo "== diff（stamp 前 → stamp 后）=="
if diff -u "${BEFORE}" "${MANIFEST}" > /tmp/stamp-diff.$$ 2>&1; then
  echo "  （无变化：本次注入的值与文件现值相同）"
else
  sed 's/^/  /' /tmp/stamp-diff.$$
fi
rm -f "${BEFORE}" /tmp/stamp-diff.$$ 2>/dev/null || true

# 回读断言：CI 里也要独立再做一次（防止脚本自身失效）
GOT="$(awk -F= '/^[[:space:]]*version[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${MANIFEST}")"
[ "${GOT}" = "${VERSION}" ] || die_input "回读断言失败：manifest.version=${GOT}，期望 ${VERSION}"
echo "== ok == manifest.version=${GOT}"
exit 0
