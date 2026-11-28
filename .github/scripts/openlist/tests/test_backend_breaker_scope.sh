#!/bin/bash
# 写探针判死 ⇒ 后端级熔断（同后端后续路径不再重复探测）
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }

if [ -z "${OL_DIR:-}" ]; then _here=$(cd "$(dirname "$0")" && pwd); OL_DIR="$_here/.."; fi
DRV="$OL_DIR/openlist_driver.sh"

echo "=== 1: 写探针判死时标记后端根 ==="
seg=$(sed -n '/判定本轮不可用 → 熔断该后端全部同步对/,/^}/p' "$DRV")
echo "$seg" | grep -q '_path_unwritable_mark "$root"' && ok "标记后端根" || bad "未标记后端根"

echo "=== 2: 预检入口先查后端根是否已判死 ==="
body=$(sed -n '/^_check_openlist_backend_connectivity() {/,/^}/p' "$DRV")
echo "$body" | grep -q '_path_unwritable_hit "$_broot"' && ok "入口检查后端根" || bad "入口未检查后端根"
echo "$body" | grep -q "后端级熔断" && ok "有明确日志文案" || bad "缺文案"

echo "=== 3: 顺序正确（根检查在任何探测之前） ==="
gl=$(echo "$body" | grep -n '_path_unwritable_hit "$_broot"' | head -1 | cut -d: -f1)
pl=$(echo "$body" | grep -n '_pre_webdav_health_check "$dest_path"' | head -1 | cut -d: -f1)
[ -n "$gl" ] && [ -n "$pl" ] && [ "$gl" -lt "$pl" ] && ok "根检查($gl) 先于 WebDAV 探测($pl)" || bad "顺序不对 g=$gl p=$pl"

echo "=== 4: 语义 —— 标记后端根后同后端其它路径被拦住 ==="
W=$(mktemp)
(
  declare -A _PATH_UNWRITABLE_ROUND=()
  _path_unwritable_mark() { _PATH_UNWRITABLE_ROUND["$1"]=1; }
  _path_unwritable_hit() { [ "${_PATH_UNWRITABLE_ROUND[$1]:-0}" = "1" ]; }
  _backend_root_of() { printf "openlist:%s" "$(printf "%s" "${1#openlist:}" | cut -d/ -f1)"; }
  # 判死后端根
  _path_unwritable_mark "$(_backend_root_of "openlist:wopan176Crypt/1/1024j/视频/91/CAT3500")"
  # 同后端另一个子目录应被拦住
  a=0; _path_unwritable_hit "$(_backend_root_of "openlist:wopan176Crypt/1/1024j/视频/91/xh98hx")" && a=1
  # 别的后端不受影响
  b=0; _path_unwritable_hit "$(_backend_root_of "openlist:baidupanCrypt/1/x")" && b=1
  echo "same_backend_blocked=$a other_backend_blocked=$b"
) > "$W" 2>&1
grep -q "same_backend_blocked=1 other_backend_blocked=0" "$W" && ok "同后端被拦、他后端不受影响" || bad "$(cat "$W")"
rm -f "$W"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
