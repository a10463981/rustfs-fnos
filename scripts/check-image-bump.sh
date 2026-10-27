#!/bin/bash
# check-image-bump.sh —— 发布前断言：manifest.version 与 compose 的 image 必须同步变化
#
# 背景（真机第四轮实测）：manifest.version 从 1.0.8 涨到 1.0.9、compose 的 image: 完全没变时，
# 应用会照 compose 声明执行，容器 id == 目标 id，于是报「升级完成」——运行时无法分辨
# 「本来该换镜像但没换」。这个判断只能在打包前做，所以单独成脚本。
#
# 用法：
#   scripts/check-image-bump.sh <当前 fpk 项目目录> --baseline <上一版项目目录 | 上一版 compose 文件>
#   scripts/check-image-bump.sh <当前 fpk 项目目录> --baseline-git <git ref> [--project-prefix deploy/fnos]
#   scripts/check-image-bump.sh <当前 fpk 项目目录> --allow-no-baseline      # 无基线时只 WARN
#
# 退出码：0 通过（可能带 WARN）｜1 断言失败｜2 用法错误
#
# 除“同步变化”外还检查：镜像引用不得用 :latest、必须带 tag 或 @sha256 digest。

set -uo pipefail

PROJECT=""
BASELINE=""
BASELINE_GIT=""
PREFIX="deploy/fnos"
ALLOW_NO_BASELINE=0

die_usage() { echo "用法错误：$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --baseline)        BASELINE="${2:-}"; shift 2 ;;
    --baseline-git)    BASELINE_GIT="${2:-}"; shift 2 ;;
    --project-prefix)  PREFIX="${2:-}"; shift 2 ;;
    --allow-no-baseline) ALLOW_NO_BASELINE=1; shift ;;
    -h|--help)         sed -n '2,20p' "$0"; exit 0 ;;
    -*)                die_usage "未知选项 $1" ;;
    *)                 [ -z "${PROJECT}" ] && PROJECT="$1" || die_usage "多余参数 $1"; shift ;;
  esac
done

[ -n "${PROJECT}" ] || die_usage "必须给出当前 fpk 项目目录"
[ -d "${PROJECT}" ] || die_usage "项目目录不存在：${PROJECT}"
[ -n "${BASELINE}" ] && [ -n "${BASELINE_GIT}" ] && die_usage "--baseline 与 --baseline-git 只能给一个"

WARN=0
FAIL=0
ok()   { printf '  OK    %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# 从「项目目录」或「compose 文件」里取 image
image_of() {
  local p="$1"
  if [ -f "${p}" ]; then
    awk -F'image:' '/^[[:space:]]*image:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${p}" 2>/dev/null
    return
  fi
  for c in "${p}/app/docker/docker-compose.yaml" "${p}/app/docker/docker-compose.yml"; do
    [ -f "${c}" ] && { awk -F'image:' '/^[[:space:]]*image:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${c}"; return; }
  done
}

version_of() {
  local p="$1"
  [ -d "${p}" ] || return 0
  awk -F= '/^[[:space:]]*version[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${p}/manifest" 2>/dev/null
}

TMPBASE=""
cleanup() { [ -n "${TMPBASE}" ] && rm -rf "${TMPBASE}" 2>/dev/null || true; }
trap cleanup EXIT

read_baseline_from_git() {
  local ref="$1"
  command -v git >/dev/null 2>&1 || { warn "没有 git，无法从 ${ref} 取基线"; return 1; }
  TMPBASE="$(mktemp -d 2>/dev/null || echo "/tmp/cib.$$")"
  mkdir -p "${TMPBASE}/app/docker" 2>/dev/null || true
  if git show "${ref}:${PREFIX}/manifest" >"${TMPBASE}/manifest" 2>/dev/null \
     && git show "${ref}:${PREFIX}/app/docker/docker-compose.yaml" >"${TMPBASE}/app/docker/docker-compose.yaml" 2>/dev/null; then
    echo "${TMPBASE}"
    return 0
  fi
  rm -rf "${TMPBASE}" 2>/dev/null || true
  TMPBASE=""
  warn "无法从 git ${ref} 读取 ${PREFIX}/manifest 或 compose（路径前缀对吗？可用 --project-prefix 指定）"
  return 1
}

echo "== 当前项目 =="
CUR_VERSION="$(version_of "${PROJECT}")"
CUR_IMAGE="$(image_of "${PROJECT}")"
[ -n "${CUR_VERSION}" ] || bad "读不到 manifest.version"
[ -n "${CUR_IMAGE}" ]   || bad "读不到 compose 的 image"
printf '  ----  version=%s\n' "${CUR_VERSION:-<空>}"
printf '  ----  image  =%s\n' "${CUR_IMAGE:-<空>}"

echo "== 镜像引用格式 =="
case "${CUR_IMAGE}" in
  *:latest) bad "image 使用 :latest（不可复现，且升级时无法表达“换没换”）" ;;
  *@sha256:*) ok "image 用 digest 固定" ;;
  *:*) ok "image 带明确 tag" ;;
  "") : ;;
  *) bad "image 既没有 tag 也没有 digest：${CUR_IMAGE}" ;;
esac

echo "== 基线 =="
BASE_SRC=""
if [ -n "${BASELINE_GIT}" ]; then
  BASE_SRC="$(read_baseline_from_git "${BASELINE_GIT}")" || BASE_SRC=""
elif [ -n "${BASELINE}" ]; then
  [ -e "${BASELINE}" ] && BASE_SRC="${BASELINE}" || warn "--baseline 路径不存在：${BASELINE}"
fi

if [ -z "${BASE_SRC}" ]; then
  if [ "${ALLOW_NO_BASELINE}" = "1" ]; then
    warn "没有可用基线：跳过「版本↔镜像同步变化」断言（--allow-no-baseline）。发布前应在有 git 历史的环境再跑一次。"
  else
    bad "没有可用基线：无法断言「版本涨了镜像是否也换了」。请用 --baseline <上一版项目目录> 或 --baseline-git <ref>；确实没有历史时用 --allow-no-baseline（只 WARN）。"
  fi
else
  BASE_VERSION="$(version_of "${BASE_SRC}")"
  BASE_IMAGE="$(image_of "${BASE_SRC}")"
  printf '  ----  基线 version=%s  image=%s\n' "${BASE_VERSION:-<读不到>}" "${BASE_IMAGE:-<读不到>}"

  if [ -z "${BASE_VERSION}" ] || [ -z "${BASE_IMAGE}" ]; then
    warn "基线缺 version 或 image，跳过同步变化断言"
  else
    echo "== 版本与镜像是否同步变化 =="
    VCHANGED=0; ICHANGED=0
    [ "${CUR_VERSION}" != "${BASE_VERSION}" ] && VCHANGED=1
    [ "${CUR_IMAGE}"   != "${BASE_IMAGE}" ]   && ICHANGED=1

    if [ "${VCHANGED}" = "1" ] && [ "${ICHANGED}" = "0" ]; then
      bad "版本号涨了（${BASE_VERSION} → ${CUR_VERSION}）但 image 没变（仍是 ${CUR_IMAGE}）：用户会以为升级成功，实际跑的是同一个镜像。请换一个新的 tag（或 digest）。"
    elif [ "${VCHANGED}" = "0" ] && [ "${ICHANGED}" = "1" ]; then
      bad "image 变了（${BASE_IMAGE} → ${CUR_IMAGE}）但 manifest.version 没变（仍是 ${CUR_VERSION}）：应用中心不会认为有更新。请同步升 version。"
    elif [ "${VCHANGED}" = "1" ] && [ "${ICHANGED}" = "1" ]; then
      ok "版本与镜像同步变化：${BASE_VERSION}/${BASE_IMAGE} → ${CUR_VERSION}/${CUR_IMAGE}"
    else
      warn "版本与镜像都没变（重打包同一内容）。仅在“改脚本/改向导/改图标”时允许。"
    fi

    # 复用同一个 tag 但内容可能变了：我们无法检测，只能提示纪律
    if [ "${VCHANGED}" = "1" ] && [ "${ICHANGED}" = "0" ] && [ "${CUR_IMAGE}" != *"@sha256:"* ]; then
      warn "提醒：即便你确信用的是“同一个 tag 的新 digest”，本脚本也只能看到字符串没变——这种情形没有任何自动检测手段（无权限比对 registry）。发布纪律：每次发版换新 tag，不复用。"
    fi
  fi
fi

echo
printf '== 汇总 ==  FAIL=%d  WARN=%d\n' "${FAIL}" "${WARN}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
