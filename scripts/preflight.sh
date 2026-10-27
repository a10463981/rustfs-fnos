#!/usr/bin/env bash
# fnpack 打包前预检 —— 补齐 fnpack build 不校验的项
# 用法: bash fnpack-preflight.sh <应用包目录>
# 退出: 0=全通过(可有 WARN), 1=有 FAIL
# 约定: 只读检查 + 最后调用 fnpack build 并由输出关键字判定成败(fnpack 失败时退出码仍为 0)

set -uo pipefail
APP_DIR="${1:-.}"
cd "$APP_DIR" || { echo "FAIL  目录不存在: $APP_DIR"; exit 1; }

FAIL=0
WARN=0
ok()   { printf '  OK    %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
section() { printf '\n== %s ==\n' "$1"; }

# ---------- 1. 必需文件 ----------
section "1 必需文件与目录"
for f in manifest config/privilege config/resource ICON.PNG ICON_256.PNG; do
  [ -f "$f" ] && ok "$f" || bad "缺少 $f"
done
for d in app cmd; do
  [ -d "$d" ] && ok "$d/" || bad "缺少目录 $d/"
done
# 实测: main/install_*/upgrade_*/uninstall_* 是强校验项, config_* 可缺
for s in main install_init install_callback upgrade_init upgrade_callback uninstall_init uninstall_callback; do
  [ -f "cmd/$s" ] && ok "cmd/$s" || bad "缺少 cmd/$s (fnpack 强校验项)"
done
for s in config_init config_callback; do
  [ -f "cmd/$s" ] || warn "缺少 cmd/$s (fnpack 不校验, 但 wizard/config 提交后需靠它生效)"
done
[ -d wizard ] || warn "缺少 wizard/ (fnpack 1.2.4 不校验, 但文档要求)"

# ---------- 2. manifest ----------
section "2 manifest 字段"
mval() { awk -F'=' -v k="$1" '$1 ~ "^[ \t]*"k"[ \t]*$" {sub(/^[^=]*=[ \t]*/,""); sub(/[ \t]+$/,""); print; exit}' manifest 2>/dev/null; }
APPNAME=$(mval appname); VERSION=$(mval version); PLATFORM=$(mval platform)
UIDIR=$(mval desktop_uidir); LAUNCH=$(mval desktop_applaunchname); PORT=$(mval service_port)

[ -n "$APPNAME" ] || bad "manifest 缺 appname"
if [ -n "$APPNAME" ]; then
  case "$APPNAME" in
    [A-Za-z0-9]*[A-Za-z0-9]) : ;;
    ?) : ;;
    *) bad "appname 必须以字母/数字开头且结尾: $APPNAME" ;;
  esac
  [[ "$APPNAME" =~ ^[A-Za-z0-9._-]+$ ]] || bad "appname 只允许字母数字 . _ - : $APPNAME"
  n=${#APPNAME}
  [ "$n" -ge 3 ] && [ "$n" -le 32 ] || bad "appname 长度需 3..32 (当前 $n); fnpack build 不校验下限, fnpack create 校验"
  ok "appname=$APPNAME"
fi
if [ -n "$VERSION" ]; then
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]] \
    || bad "version 必须是 x.y.z 或 x.y.z-r (实测 1.0.0-beta 会被拒): $VERSION"
  ok "version=$VERSION"
else bad "manifest 缺 version"; fi
for k in display_name source; do
  [ -n "$(mval $k)" ] && ok "$k=$(mval $k)" || bad "manifest 缺 $k (fnpack 强校验项)"
done
case "$PLATFORM" in
  x86|arm|loongarch|risc-v|all) ok "platform=$PLATFORM" ;;
  "") warn "未声明 platform, 默认 x86" ;;
  *) bad "platform 非法: $PLATFORM (允许 x86/arm/loongarch/risc-v/all)" ;;
esac
# 重复 key: 后者覆盖前者, 静默生效
dup=$(awk -F'=' '/^[ \t]*[A-Za-z_]/{gsub(/[ \t]/,"",$1); print $1}' manifest | sort | uniq -d)
[ -z "$dup" ] && ok "manifest 无重复 key" || bad "manifest 有重复 key(后者静默覆盖): $dup"
# 不被 fnpack 校验、但填错只在设备端爆发的字段
for k in ctl_stop os_min_version os_max_version install_type changeLog changelog; do
  v=$(mval $k); [ -n "$v" ] && printf '  ----  %s=%s (fnpack 不校验, 需人工确认语义)\n' "$k" "$v"
done
if [ -n "$PORT" ]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] && ok "service_port=$PORT" || bad "service_port 非数字: $PORT"
fi

# ---------- 3. JSON 合法性 + 语义 ----------
section "3 config / ui 配置"
PY=python3; command -v $PY >/dev/null || PY=""
jvalid() { if [ -n "$PY" ]; then $PY -c "import json,sys;json.load(open('$1'))" 2>/dev/null; else return 0; fi; }
for f in config/privilege config/resource "app/${UIDIR:-ui}/config"; do
  [ -f "$f" ] || { bad "缺少 $f"; continue; }
  jvalid "$f" && ok "$f JSON 合法" || bad "$f JSON 非法"
done

# 入口 ID: 必须 "{appname}." 前缀, <=32 字符, 且 desktop_applaunchname 必须命中其一
UICFG="app/${UIDIR:-ui}/config"
if [ -f "$UICFG" ] && [ -n "$PY" ]; then
  ids=$($PY - "$UICFG" <<'EOF' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
for k in (d.get(".url") or {}): print(k)
EOF
)
  [ -n "$ids" ] || warn "$UICFG 中 .url 为空"
  for id in $ids; do
    case "$id" in
      "$APPNAME".*) : ;;
      *) bad "入口 ID 必须以 \"$APPNAME.\" 开头: $id" ;;
    esac
    [ ${#id} -le 32 ] || bad "入口 ID 超过 32 字符: $id"
  done
  if [ -n "$LAUNCH" ]; then
    echo "$ids" | grep -qx "$LAUNCH" && ok "desktop_applaunchname=$LAUNCH 命中入口" \
      || bad "desktop_applaunchname=$LAUNCH 未在 $UICFG 中定义"
  fi
  # 端口三处一致性: manifest.service_port / ui-config port / compose ports
  uiport=$($PY - "$UICFG" <<'EOF' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
for v in (d.get(".url") or {}).values():
    p=v.get("port")
    if isinstance(p,(str,int)) and str(p).strip(): print(p); break
EOF
)
  [ -n "${uiport:-}" ] && printf '  ----  ui/config port=%s (需与 service_port=%s 及 compose 映射一致)\n' "$uiport" "${PORT:-未声明}"
fi

# ---------- 4. 图标 ----------
section "4 图标"
if [ -n "$PY" ]; then
$PY - <<'EOF'
import struct,sys
def dim(p):
    with open(p,"rb") as f:
        h=f.read(26)
    if h[:8]!=b"\x89PNG\r\n\x1a\n": return None
    return struct.unpack(">II",h[16:24])
for p,exp in (("ICON.PNG",64),("ICON_256.PNG",256)):
    try:
        d=dim(p)
    except FileNotFoundError:
        continue
    if d is None: print("  FAIL  %s 不是 PNG"%p); continue
    w,hh=d
    tag="OK   " if (w==hh==exp) else "WARN "
    print("  %s %s = %dx%d (建议 %dx%d; fnpack 不校验尺寸)"%(tag,p,w,hh,exp,exp))
    import os
    if os.path.getsize(p)>1024*1024: print("  FAIL  %s 超过 1024KB"%p)
EOF
fi
for i in app/*/images/icon_64.png app/*/images/icon_256.png; do
  [ -e "$i" ] || warn "缺少入口图标 $i (若 ui/config 用 images/icon_{0}.png 则必需)"
done

# ---------- 5. 硬编码 / 反模式 ----------
section "5 硬编码与反模式"
hits=$(grep -rn "/var/apps" cmd app 2>/dev/null | grep -v "^app/ui/config" || true)
[ -z "$hits" ] && ok "cmd/ 与 app/ 无 /var/apps 硬编码" || bad "发现 /var/apps 硬编码:"$'\n'"$hits"
if [ -f app/docker/docker-compose.yaml ]; then
  grep -q ':latest' app/docker/docker-compose.yaml && warn "compose 使用 :latest, 版本不可复现" || ok "compose 未使用 :latest"
  grep -q 'TRIM_APPDEST\|TRIM_PKGVAR\|TRIM_DATA_SHARE_PATHS' app/docker/docker-compose.yaml \
    && ok "compose 使用了 TRIM_* 变量" || warn "compose 未使用 TRIM_* 变量, 确认卷/端口未硬编码"
  grep -q 'privileged:[[:space:]]*true' app/docker/docker-compose.yaml && bad "compose 使用 privileged: true" || ok "compose 未开 privileged"
fi
if [ -f config/privilege ]; then
  grep -q '"run-as"[[:space:]]*:[[:space:]]*"root"' config/privilege && warn "config/privilege 使用 run-as=root, 需说明理由" || ok "config/privilege 非 root"
fi
for s in cmd/*; do
  if [ -f "$s" ] && ! grep -q "TRIM_TEMP_LOGFILE" "$s"; then warn "$s 未写 TRIM_TEMP_LOGFILE (失败原因用户看不到)"; fi
done
[ -x cmd/main ] && ok "cmd/main 有执行位" || warn "cmd/main 无执行位 (fnpack 不校验, 但真机可能直接 exec)"
strays=$(find . -maxdepth 1 -type f ! -name manifest ! -name 'ICON*.PNG' ! -name '*.fpk' ! -name 'app.tgz' -print 2>/dev/null)
[ -z "$strays" ] && ok "根目录无多余文件" || warn "根目录文件不会进包(fpk 顶层是白名单): "$strays
ds=$(find . -name '.DS_Store' -o -name 'Thumbs.db' | head -5)
[ -z "$ds" ] && ok "无 .DS_Store/Thumbs.db" || warn "噪音文件会被打进包: "$ds

# ---------- 5b. 权限（决定 install-local / 包用户能否执行） ----------
section "5b 权限（install-local 与包用户执行）"
# git 只记录「可执行位」，不记录目录权限；clone 出来的目录权限由 umask 决定。
# appcenter 用 install-local 时会把源目录原样复制到 /tmp/appcenter.pack.<id>/ 再 exec，
# 目录若是 700，包用户既进不去也执行不了 → 真机实测 code 10237 fork/exec permission denied。
perm_fail=0
bad_dirs="$(find . -type d ! -perm -005 2>/dev/null)"
if [ -z "${bad_dirs}" ]; then
  ok "目录对 others 可读可执行（-perm -005）"
else
  bad "以下目录 others 无 r+x（install-local 必失败）："
  printf '%s\n' "${bad_dirs}" | head -20 | sed 's/^/          /'
  perm_fail=1
fi
bad_files="$(find . -type f ! -perm -004 2>/dev/null | grep -v '^./cmd/' || true)"
if [ -z "${bad_files}" ]; then
  ok "普通文件对 others 可读（-perm -004）"
else
  bad "以下文件 others 无读权限："
  printf '%s\n' "${bad_files}" | head -20 | sed 's/^/          /'
  perm_fail=1
fi
bad_exec="$(find ./cmd -type f ! -perm -001 2>/dev/null || true)"
if [ -z "${bad_exec}" ]; then
  ok "cmd/* 对 others 可执行（-perm -001）"
else
  bad "以下生命周期脚本缺少 others 可执行位："
  printf '%s\n' "${bad_exec}" | head -20 | sed 's/^/          /'
  perm_fail=1
fi
if [ "${perm_fail}" = "1" ]; then
  printf '  ----  修复（在本目录下执行）：chmod -R a+rX . && chmod 755 ./cmd/*\n'
  printf '  ----  为什么：git 只记录可执行位，不记录目录权限，clone/解压后的目录权限取决于 umask\n'
fi

# ---------- 5c. 两份 *_init 的共享段一致性 ----------
section "5c 共享段一致性（data-dir-check）"
extract_block() { sed -n '/^# >>> BEGIN: data-dir-check/,/^# <<< END: data-dir-check/p' "$1" 2>/dev/null; }
extract_probe() { sed -n '/^# >>> BEGIN: writable-probe/,/^# <<< END: writable-probe/p' "$1" 2>/dev/null; }
if [ -f cmd/install_init ] && [ -f cmd/config_init ]; then
  a="$(extract_block cmd/install_init | sha256sum | awk '{print $1}')"
  b="$(extract_block cmd/config_init | sha256sum | awk '{print $1}')"
  if [ -z "$(extract_block cmd/install_init)" ]; then
    bad "cmd/install_init 里找不到 data-dir-check 段标记（# >>> BEGIN: data-dir-check）"
  elif [ -z "$(extract_block cmd/config_init)" ]; then
    bad "cmd/config_init 里找不到 data-dir-check 段标记"
  elif [ "${a}" != "${b}" ]; then
    bad "两份 data-dir-check 不一致（install_init=${a:0:12} config_init=${b:0:12}）：数据目录校验逻辑必须逐字相同"
  else
    ok "data-dir-check 段在 install_init / config_init 中逐字一致（${a:0:12}）"
  fi
else
  warn "缺少 cmd/install_init 或 cmd/config_init，跳过共享段一致性检查"
fi
# writable-probe 段必须在四个脚本里逐字相同（写探测逻辑四处都用，最容易走偏）
probe_sums=""
probe_missing=0
for f in cmd/install_init cmd/config_init cmd/install_callback cmd/config_callback; do
  if [ -f "$f" ] && [ -n "$(extract_probe "$f")" ]; then
    probe_sums="${probe_sums}$(extract_probe "$f" | sha256sum | awk '{print $1}') "
  else
    probe_missing=1
    printf '          %s 缺少 writable-probe 段标记\n' "$f"
  fi
done
if [ "${probe_missing}" = "1" ]; then
  bad "writable-probe 段在部分脚本中缺失（四处必须都有且逐字相同）"
else
  uniq_n="$(printf '%s\n' ${probe_sums} | sort -u | wc -l | tr -d ' ')"
  if [ "${uniq_n}" != "1" ]; then
    bad "writable-probe 段在四个脚本中不一致（出现 ${uniq_n} 个不同版本）：写探测逻辑必须逐字相同"
  else
    ok "writable-probe 段在 4 个脚本中逐字一致（$(printf '%s' "${probe_sums}" | cut -c1-12)）"
  fi
fi

# ---------- 6. 真实打包(退出码不可信, 按输出判定) ----------
section "6 fnpack build"
if command -v fnpack >/dev/null; then
  out=$(fnpack build 2>&1); rc=$?
  fpk=$(printf '%s' "$out" | sed -n 's/.*output file \(.*\.fpk\) can be found.*/\1/p')
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -q "Packing successfully"; then
    bad "build 失败 (注意: fnpack 失败时退出码可能仍为 0, rc=$rc)"
  else
    [ -n "$fpk" ] && [ -f "$fpk" ] && printf '  OK    %s (%s bytes)\n' "$fpk" "$(stat -c%s "$fpk" 2>/dev/null || echo '?')" || bad "未找到产物"
  fi
else warn "未安装 fnpack, 跳过 build"; fi

printf '\n== 汇总 ==\n  FAIL=%d  WARN=%d\n' "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] || exit 1
