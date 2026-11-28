#!/bin/bash
# 弱证据 streak 清零钩子：_succ_root 必须是命令替换的结果（后端根名），
# 不能是字面串 \$(...)。历史 bug: 转义写进脚本 ⇒ streak 永不清零 ⇒ 健康后端被误判熔断。
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }
HERE=$(cd "$(dirname "$0")" && pwd)
TE="$HERE/../task_engine.sh"

echo "=== 1: 源码不含转义的 \$( 形式 ==="
n=$(grep -cF '\$(' "$TE" 2>/dev/null || true)
[ "${n:-0}" = "0" ] && ok "无反斜杠\$( 转义" || bad "仍有 $n 处反斜杠\$( 转义"

echo "=== 2: _succ_root 用真命令替换 ==="
line=$(grep -n '_succ_root=' "$TE" | head -1)
echo "$line" | grep -qF '_succ_root="$(_task_backend_root_of "$_hb_dst"' && ok "是真命令替换" || bad "形式不符: $line"

echo "=== 3: 语义 —— 命令替换真的执行（不是字面串）==="
W=$(mktemp)
(
  _task_backend_root_of() { printf "openlist:%s" "$(printf "%s" "${1#openlist:}" | cut -d/ -f1)"; }
  _hb_dst="openlist:wopan175/4/1024j-视频-pornhub-channel"
  local_ok=0
  _succ_root="$(_task_backend_root_of "$_hb_dst" 2>/dev/null || true)"
  echo "root=$_succ_root"
) > "$W" 2>&1
grep -q "root=openlist:wopan175" "$W" && ok "替换得到后端根 openlist:wopan175" || bad "$(cat "$W")"
! grep -q "root=\$(" "$W" && ok "结果不是字面串" || bad "仍是字面串"
rm -f "$W"

echo "=== 4: 清零钩子接到 _backend_dead_weak_reset ==="
grep -q '_backend_dead_weak_reset "$_succ_root"' "$TE" && ok "用 _succ_root 作参数" || bad "参数不对"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
