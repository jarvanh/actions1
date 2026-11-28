#!/bin/bash
# 并行分发的写端必须把判死标志传给收集端并写台账
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }
if [ -z "${OL_DIR:-}" ]; then _here=$(cd "$(dirname "$0")" && pwd); OL_DIR="$_here/.."; fi
TE="$OL_DIR/task_engine.sh"

echo "=== 1: worker 写 dead 标志 ==="
sed -n '/_st=\$(_pair_status_from_flags)/,+12p' "$TE" | grep -q "dead=%s" && ok "worker 输出 dead=" || bad "worker 未输出"
sed -n '/_st=\$(_pair_status_from_flags)/,+12p' "$TE" | grep -q "dead_strong=%s" && ok "worker 输出 dead_strong=" || bad "未输出 strong"

echo "=== 2: 收集端读 dead 并调 _backend_dead_mark ==="
sed -n '/_st=\$(sed -n/,+14p' "$TE" | grep -q "_backend_dead_mark" && ok "收集端调台账" || bad "收集端未调"
sed -n '/_st=\$(sed -n/,+14p' "$TE" | grep -q "dead_f" && ok "读取 dead 标志" || bad "未读取"

echo "=== 3: 用 _pp_dst 取后端根（不是 _be 裸名）==="
sed -n '/_st=\$(sed -n/,+14p' "$TE" | grep -q "_task_backend_root_of" && ok "取后端根" || bad "未取根"

echo "=== 4: 仅 dead=1 时写（不误写健康后端）==="
sed -n '/_st=\$(sed -n/,+14p' "$TE" | grep -qF '[ "${_dead_f:-0}" = "1" ]' && ok "有 dead=1 门槛" || bad "无门槛"

echo "=== 5: 语义 —— dead=1 调用、dead=0 不调用 ==="
W=$(mktemp); rm -f "$W"
CALLS=0
_backend_dead_mark(){ CALLS=$((CALLS+1)); }
_task_backend_root_of(){ printf "openlist:%s" "$(printf "%s" "${1#openlist:}"|cut -d/ -f1)"; }
_pp_dst[3]="openlist:wopan176Crypt/1"
_be="openlist:wopan176Crypt"
_idx=3
for d in 1 0; do
  _f=$W; printf "dead=%s\n" "$d" > "$_f"
  _dead_f=$(sed -n 's/^dead=//p' "$_f" | head -1)
  if [ "${_dead_f:-0}" = "1" ] && [ -n "${_be:-}" ]; then
    _dead_root=$(_task_backend_root_of "${_pp_dst[$_idx]:-}" 2>/dev/null || true)
    [ -n "$_dead_root" ] && _backend_dead_mark "$_dead_root" || true
  fi
done
[ "$CALLS" -eq 1 ] && ok "只调用 1 次（dead=1）" || bad "调用 $CALLS 次"
rm -f "$W"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1