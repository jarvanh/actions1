#!/bin/bash
# F5 反证探针应尊重「后端已判死」结论，不再重复探测
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }
if [ -z "${OL_DIR:-}" ]; then _here=$(cd "$(dirname "$0")" && pwd); OL_DIR="$_here/.."; fi
TE="$OL_DIR/task_engine.sh"

echo "=== 1: 有 _f5_skip_probe 守卫 ==="
grep -q "_f5_skip_probe=1" "$TE" && ok "设置跳过标志" || bad "缺标志"
grep -q 'if \[ "$_f5_skip_probe" -eq 1 \]; then' "$TE" && ok "标志接入分支" || bad "标志未接入"

echo "=== 2: 守卫在 _backend_write_probe 调用之前 ==="
g=$(grep -n "_f5_skip_probe=1" "$TE" | head -1 | cut -d: -f1)
p=$(grep -n "_F5_PROBE_LENIENT=1 _backend_write_probe" "$TE" | head -1 | cut -d: -f1)
[ -n "$g" ] && [ -n "$p" ] && [ "$g" -lt "$p" ] && ok "守卫($g) 先于探针($p)" || bad "顺序不对 g=$g p=$p"

echo "=== 3: 用 _path_unwritable_hit 判据（查守卫块上文） ==="
seg=$(sed -n "$((g-12)),$((g+2))p" "$TE")
echo "$seg" | grep -q "_path_unwritable_hit" && ok "用路径级不可写判据" || bad "缺判据"
echo "$seg" | grep -q "_task_backend_root_of" && ok "取后端根比对" || bad "未取后端根"

echo "=== 4: 跳过时按可写放行（不重复判死） ==="
sed -n "$((g)),$((g+16))p" "$TE" | grep -q "_f5_probe_ok=1" && ok "跳过时置可写" || bad "未置可写"

echo "=== 5: 语义 —— 后端已判死时不调探针 ==="
W=$(mktemp)
(
  declare -A _PATH_UNWRITABLE_ROUND=()
  _path_unwritable_hit() { [ "${_PATH_UNWRITABLE_ROUND[$1]:-0}" = "1" ]; }
  _task_backend_root_of() { printf "openlist:%s" "$(printf "%s" "${1#openlist:}" | cut -d/ -f1)"; }
  PROBES=0
  _backend_write_probe() { PROBES=$((PROBES+1)); return 1; }
  run_case() {
    local dest_path="openlist:wopan176Crypt/1/1024j/视频/x"
    local _f5_probe_ok=0 _f5_skip_probe=0
    if declare -F _path_unwritable_hit >/dev/null 2>&1; then
      local _f5_broot; _f5_broot="$(_task_backend_root_of "$dest_path" 2>/dev/null || true)"
      if [ -n "$_f5_broot" ] && _path_unwritable_hit "$_f5_broot"; then _f5_skip_probe=1; fi
    fi
    if [ "$_f5_skip_probe" -eq 1 ]; then
      _f5_probe_ok=1
    elif declare -F _backend_write_probe >/dev/null 2>&1; then
      _backend_write_probe "$dest_path" /dev/null || true
    fi
    echo "probes=$PROBES ok=$_f5_probe_ok"
  }
  echo "--- 后端已判死:"; _PATH_UNWRITABLE_ROUND["openlist:wopan176Crypt"]=1; PROBES=0; run_case
  echo "--- 后端健康:"; _PATH_UNWRITABLE_ROUND=(); PROBES=0; run_case
) > "$W" 2>&1
grep -q "probes=0 ok=1" "$W" && ok "判死后 0 次探针且按可写放行" || bad "$(head -3 "$W")"
grep -q "probes=1 ok=0" "$W" && ok "健康时正常探测" || bad "健康时未探测"
rm -f "$W"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
