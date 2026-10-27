#!/bin/bash
# backup-data.sh —— 升级 / 重装前，把 RustFS 的数据目录整份复制一份
#
# 为什么需要它：appcenter 在 install/upgrade task 内部失败时会执行 rollback
# （真机日志里是 msg=rollback），而我们观测到 rollback 之后 @appdata/<app> 与 @appconf/<app>
# 双双消失。也就是说 ——「安装/升级失败」有可能连带删掉数据目录。这条路径我们无法控制，
# 只能在上手之前先把数据复制一份到 @app* 之外。
#
# 设计原则（刻意的）：
#   1. 只复制，绝不移动、绝不删除原数据；
#   2. 备份落点默认在「同一个存储空间的卷根下」，但**必须在 @app* 之外**，
#      否则 rollback 连同备份一起删掉，等于没备；
#   3. 空间不足时提前失败，不做「写一半」的备份；
#   4. 目标已存在时**绝不覆盖**，自动加序号；
#   5. --prune 只删本脚本自己命名规则下的历史备份，且只在指定的备份根目录内。
#
# 用法：
#   sudo bash scripts/backup-data.sh
#   sudo bash scripts/backup-data.sh --prune 3
#   sudo bash scripts/backup-data.sh --dest /vol2/rustfs-backups
#   sudo bash scripts/backup-data.sh --dry-run
#   bash scripts/backup-data.sh --allow-nonroot --dest /tmp/bk      # 仅本地冒烟/CI
#
# 退出码：0 成功 ｜ 1 失败 ｜ 2 用法错误
#
# 注意：这份备份只防「误删 / 回滚」，不防磁盘损坏。要防硬件故障请另做快照或异地复制。
#
# 数据位置从哪来（v7 起数据可自定义）：
#   读 /var/apps/<app>/etc/settings.env 里的 DATA_DIR；读不到才回退到 /var/apps/<app>/var/data。
#   所以无论是默认位置还是用户自己的存储空间，本脚本都能找到它。
#   想临时指定：DATA_DIR_OVERRIDE=/vol2/rustfs-data sudo -E bash scripts/backup-data.sh

set -uo pipefail

APPNAME="${APPNAME:-rustfs-fnos}"
# 稳定锚点：安装后的 var 目录（软链到 /vol<N>/@appdata/<app>）。
# 不直接写物理路径，避免换卷/迁移后脚本失效。
ANCHOR="/var/apps/${APPNAME}/var"

DEST=""
PRUNE=0
DRY_RUN=0
ALLOW_NONROOT=0

die_usage() { echo "用法错误：$*" >&2; exit 2; }
die() { echo "失败：$*" >&2; exit 1; }
say() { echo "  $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)          DEST="${2:-}"; shift 2 ;;
    --prune)         PRUNE="${2:-0}"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --allow-nonroot) ALLOW_NONROOT=1; shift ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *)               die_usage "未知参数 $1" ;;
  esac
done

case "${PRUNE}" in ''|*[!0-9]*) die_usage "--prune 需要一个非负整数：${PRUNE}" ;; esac

if [ "$(id -u)" != "0" ]; then
  if [ "${ALLOW_NONROOT}" = "1" ]; then
    say "警告：以非 root 身份运行（--allow-nonroot）。复制出的文件属主/权限可能与原数据不一致，仅可用于冒烟。"
  else
    die "本脚本必须以 root 运行（要保留属主与权限）：sudo bash $0"
  fi
fi

# ---- 数据目录：优先读应用写入的 settings.env（v7 起数据可指向用户存储空间）----
SETTINGS_FILE="/var/apps/${APPNAME}/etc/settings.env"
SETTINGS_DATA_DIR=""
if [ -r "${SETTINGS_FILE}" ]; then
  SETTINGS_DATA_DIR="$(awk -F= '/^[[:space:]]*DATA_DIR[[:space:]]*=/{sub(/^[[:space:]]*DATA_DIR[[:space:]]*=[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "${SETTINGS_FILE}" 2>/dev/null)"
fi
[ -n "${DATA_DIR_OVERRIDE:-}" ] && SETTINGS_DATA_DIR="${DATA_DIR_OVERRIDE}"

if [ -n "${SETTINGS_DATA_DIR}" ]; then
  SRC="${SETTINGS_DATA_DIR}"
  SRC_SOURCE="settings.env 的 DATA_DIR"
else
  SRC="${ANCHOR}/data"
  SRC_SOURCE="默认位置（settings.env 里没有 DATA_DIR）"
fi

[ -e "${SRC}" ] || die "找不到数据目录：${SRC}
  可能原因：应用未安装 / 已被卸载 / settings.env 里的 DATA_DIR 指向了不存在的路径。
  排查：
    ls -l /var/apps/${APPNAME}/ 2>/dev/null
    sudo cat ${SETTINGS_FILE} 2>/dev/null | grep DATA_DIR
    ls -ld /var/apps/${APPNAME}/var/data 2>/dev/null"
[ -d "${SRC}" ] || die "数据路径不是目录：${SRC}"

SRC_REAL="$(readlink -f "${SRC}" 2>/dev/null || echo "${SRC}")"
VOL="$(printf '%s' "${SRC_REAL}" | cut -d/ -f2)"          # 形如 vol1
[ -n "${VOL}" ] || die "无法从路径推导存储空间：${SRC_REAL}"
VOL_ROOT="/${VOL}"
[ -d "${VOL_ROOT}" ] || die "存储空间根目录不存在：${VOL_ROOT}"

[ -n "${DEST}" ] || DEST="${VOL_ROOT}/rustfs-fnos-backups"

# ---- 关键护栏：备份绝不能落在会被 rollback 清掉的目录里 ----
case "${DEST}" in
  */@appdata/*|*/@apptemp/*|*/@appconf/*|*/@apphome/*|*/@appmeta/*|*/@appcenter/*)
    die "拒绝执行：备份目录不能放在 @app* 应用目录内（${DEST}）。
  原因：安装/升级失败时 appcenter 的 rollback 可能连 @appdata / @appconf 一起删掉，
        备份放里面等于白做。请改到卷根下的普通目录，例如：--dest ${VOL_ROOT}/rustfs-fnos-backups" ;;
esac
SRC_ABS="$(readlink -f "${SRC}" 2>/dev/null || echo "${SRC}")"
case "${DEST}/" in
  "${SRC_ABS}"/*) die "拒绝执行：备份目录不能位于数据目录之内（${DEST} 在 ${SRC_ABS} 下）" ;;
esac

TS="$(date '+%Y%m%d-%H%M%S')"
TARGET="${DEST}/data.bak-${TS}"
if [ -e "${TARGET}" ]; then
  for i in $(seq 2 99); do
    [ -e "${TARGET}-${i}" ] || { TARGET="${TARGET}-${i}"; break; }
  done
  [ -e "${TARGET}" ] && die "同名备份已存在且序号用尽：${TARGET}（不覆盖任何已有备份）"
fi

# ---- 体积与空间 ----
SRC_BYTES="$(du -sb "${SRC}" 2>/dev/null | cut -f1)"
[ -n "${SRC_BYTES}" ] || die "无法统计数据目录体积：${SRC}"
SRC_HUMAN="$(du -sh "${SRC}" 2>/dev/null | cut -f1)"

mkdir -p "${DEST}" 2>/dev/null || die "无法创建备份根目录：${DEST}"
AVAIL_KB="$(df -Pk "${DEST}" 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "${AVAIL_KB}" ] || die "无法读取 ${DEST} 的可用空间"
NEED_KB=$(( SRC_BYTES / 1024 ))
NEED_KB=$(( NEED_KB + NEED_KB / 10 + 10240 ))     # +10% 余量 + 10MB
if [ "${AVAIL_KB}" -lt "${NEED_KB}" ]; then
  die "空间不足：需要约 $(( NEED_KB / 1024 )) MiB（含 10% 余量），${DEST} 只剩 $(( AVAIL_KB / 1024 )) MiB。
  可选：换一个 --dest（同一存储空间内换目录不解决空间问题）；或先清理旧备份（--prune）；或改用快照。"
fi

echo "== 计划 =="
say "应用      : ${APPNAME}"
say "源目录    : ${SRC}  →  ${SRC_REAL}"
say "来源      : ${SRC_SOURCE}"
say "数据体积  : ${SRC_HUMAN:-?}（${SRC_BYTES} 字节）"
say "备份根目录: ${DEST}（可用 $(( AVAIL_KB / 1024 )) MiB）"
say "备份目标  : ${TARGET}"
[ "${PRUNE}" -gt 0 ] && say "备份后保留: 最近 ${PRUNE} 份"
say "只复制，不移动、不删除原数据"

if [ "${DRY_RUN}" = "1" ]; then
  echo "== dry-run：不做任何写入 =="
  exit 0
fi

# ---- 复制（cp -a 保留权限/属主/时间） ----
echo "== 复制中 =="
if ! cp -a "${SRC}" "${TARGET}" 2>/tmp/backup-data.err.$$; then
  echo "cp 报错：" >&2; sed 's/^/    /' /tmp/backup-data.err.$$ >&2
  rm -rf "${TARGET}" 2>/dev/null || true
  rm -f /tmp/backup-data.err.$$ 2>/dev/null || true
  die "复制失败，已清理半成品 ${TARGET}（原数据未受影响）"
fi
rm -f /tmp/backup-data.err.$$ 2>/dev/null || true

# ---- 校验：文件数一致 ----
SRC_N="$(find "${SRC}" 2>/dev/null | wc -l)"
DST_N="$(find "${TARGET}" 2>/dev/null | wc -l)"
DST_BYTES="$(du -sb "${TARGET}" 2>/dev/null | cut -f1)"
if [ "${SRC_N}" != "${DST_N}" ]; then
  die "校验失败：条目数不一致（源 ${SRC_N} / 备份 ${DST_N}）。备份保留在 ${TARGET}，请人工核对后再决定是否删。"
fi

echo "== 完成 =="
say "备份目录: ${TARGET}"
say "条目数  : ${DST_N}（与源一致）"
say "体积    : $(du -sh "${TARGET}" 2>/dev/null | cut -f1)（源 ${SRC_HUMAN}）"
say "现在可以升级/重装了"

# ---- 需要回退时 ----
cat <<EOF

== 如果需要回退 ==
  1) 先在应用中心把应用「停止」（不要卸载）；
  2) 把当前数据挪开（不要直接删）：
       sudo mv "${SRC}" "${SRC}.broken-\$(date +%Y%m%d-%H%M%S)"
  3) 把备份放回去：
       sudo cp -a "${TARGET}" "${SRC}"
  4) 在应用中心「启动」，确认控制台能打开、桶与对象都在。
  注意：备份是「复制」出来的，原数据在 2) 之后仍保留在 *.broken-* 里，确认无误再自行清理。
EOF

# ---- 可选的清理 ----
if [ "${PRUNE}" -gt 0 ]; then
  echo "== 清理旧备份（保留最近 ${PRUNE} 份）=="
  KEEP="${PRUNE}"
  # 只匹配本脚本的命名规则，且只在备份根目录内，按名字倒序（时间戳前缀可按字典序比较）
  mapfile -t ALL < <(find "${DEST}" -maxdepth 1 -mindepth 1 -type d -name 'data.bak-*' -printf '%f\n' 2>/dev/null | sort -r)
  if [ "${#ALL[@]}" -le "${KEEP}" ]; then
    say "现有 ${#ALL[@]} 份，无需清理"
  else
    for name in "${ALL[@]:${KEEP}}"; do
      case "${name}" in
        data.bak-*) rm -rf -- "${DEST:?}/${name}" && say "已删除 ${DEST}/${name}" ;;
        *) say "跳过非本脚本命名的条目：${name}" ;;
      esac
    done
  fi
fi

exit 0
