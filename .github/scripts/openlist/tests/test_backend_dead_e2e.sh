#!/bin/bash
# 端到端: _backend_dead_mark 连续调用 3 次，第 3 次才写 backend_dead.json
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }

if [ -z "${OL_DIR:-}" ]; then _here=$(cd "$(dirname "$0")" && pwd); OL_DIR="$_here/.."; fi
TE="$OL_DIR/task_engine.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

run_round() {
  (
    SYNC_STATE_DIR="$W"
    OPENLIST_BACKEND_DEAD_TTL=14400
    OPENLIST_BACKEND_DEAD_THRESHOLD=3
    SYNC_BACKEND_DEAD_STRONG="${1:-0}"
    declare -A _BACKEND_DEAD_ROUND=()
    rclone() { case "$1" in cat) cat "$2" 2>/dev/null;; *) return 0;; esac; }
    _marker_write() { printf "%s" "$1" > "$2"; }
    eval "$(sed -n '/_backend_dead_state_path() {/,/^}/p' "$TE")"
    eval "$(sed -n '/_backend_dead_weak_path() {/,/^}/p' "$TE")"
    eval "$(sed -n '/_backend_dead_weak_bump() {/,/^}/p' "$TE")"
    eval "$(sed -n '/_backend_dead_mark() {/,/^}/p' "$TE")"
    _backend_dead_mark "openlist:wopan176Crypt" >/dev/null 2>&1
  )
}

echo "=== 端到端: 弱证据连续 3 轮 ==="
rm -f "$W/backend_dead.json" "$W/backend_dead_weak.json"
run_round 0; a=0; [ -s "$W/backend_dead.json" ] && a=1
run_round 0; b=0; [ -s "$W/backend_dead.json" ] && b=1
run_round 0; c=0; [ -s "$W/backend_dead.json" ] && c=1
echo "  第1轮写=$a 第2轮写=$b 第3轮写=$c"
[ "$a" = "0" ] && [ "$b" = "0" ] && [ "$c" = "1" ] && ok "前两轮不写、第三轮升级写入" || bad "期望 0/0/1，实际 $a/$b/$c"

echo "=== 弱证据台账结构 ==="
if [ -s "$W/backend_dead_weak.json" ]; then
  st=$(jq -r ".[\"openlist:wopan176Crypt\"].streak // empty" "$W/backend_dead_weak.json" 2>/dev/null)
  [[ "$st" =~ ^[0-9]+$ ]] && ok "streak 为数字($st)" || bad "streak=$st"
else
  bad "弱证据台账未生成"
fi

echo "=== 强证据首轮即写 ==="
rm -f "$W/backend_dead.json" "$W/backend_dead_weak.json"
run_round 1; s=0; [ -s "$W/backend_dead.json" ] && s=1
[ "$s" = "1" ] && ok "强证据第一轮写入" || bad "强证据未写入"

echo "=== 写出的 backend_dead.json 结构合法 ==="
if [ -s "$W/backend_dead.json" ]; then
  key=$(jq -r "keys[0]" "$W/backend_dead.json" 2>/dev/null)
  da=$(jq -r ".[\"$key\"].dead_at // empty" "$W/backend_dead.json" 2>/dev/null)
  [ "$key" = "openlist:wopan176Crypt" ] && ok "键为后端根" || bad "键=$key"
  [[ "$da" =~ ^[0-9]+$ ]] && ok "dead_at 为数字时间戳" || bad "dead_at=$da"
else
  bad "文件未生成，无法校验结构"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
