#!/bin/bash
# 弱证据连续轮次升级为跨轮熔断（OPENLIST_BACKEND_DEAD_THRESHOLD）
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }

if [ -z "${OL_DIR:-}" ]; then _here=$(cd "$(dirname "$0")" && pwd); OL_DIR="$_here/.."; fi
TE="$OL_DIR/task_engine.sh"

echo "=== 1: 三个新函数存在 ==="
for f in _backend_dead_weak_path _backend_dead_weak_bump _backend_dead_weak_reset; do
  grep -q "^$f() {" "$TE" && ok "$f 已定义" || bad "$f 缺失"
done

echo "=== 2: 弱证据按阈值判定 ==="
seg=$(sed -n '/_backend_dead_mark() {/,/^}/p' "$TE")
echo "$seg" | grep -q "_backend_dead_weak_bump" && ok "调用 streak 累加" || bad "未累加"
echo "$seg" | grep -q "OPENLIST_BACKEND_DEAD_THRESHOLD" && ok "引用阈值" || bad "未引用阈值"
echo "$seg" | grep -q "升级为跨轮熔断" && ok "达阈值有升级日志" || bad "缺升级日志"
echo "$seg" | grep -q "未达阈值不写入" && ok "未达阈值有说明日志" || bad "缺说明日志"

echo "=== 3: 成功分支清零 streak ==="
n=$(grep -c "_backend_dead_weak_reset" "$TE")
[ "$n" -ge 2 ] && ok "定义+调用都在（${n} 次）" || bad "仅定义未调用"

echo "=== 4: bump 逐轮递增 ==="
W=$(mktemp -d)
(
  SYNC_STATE_DIR="$W"
  rclone() { if [ "$1" = "cat" ]; then cat "$2" 2>/dev/null; else return 0; fi; }
  _marker_write() { printf "%s" "$1" > "$2"; }
  _backend_dead_weak_path() { echo "${SYNC_STATE_DIR}/weak.json"; }
  eval "$(sed -n '/_backend_dead_weak_bump() {/,/^}/p' "$TE")"
  _backend_dead_weak_bump "openlist:wopan175"
  _backend_dead_weak_bump "openlist:wopan175"
  _backend_dead_weak_bump "openlist:wopan175"
) > "$W/o" 2>&1
tr -d "\n" < "$W/o" | grep -qx "123" && ok "1→2→3" || bad "$(cat "$W/o" | tr "\n" " ")"

echo "=== 5: reset 后重新从 1 开始 ==="
(
  SYNC_STATE_DIR="$W"
  rclone() { if [ "$1" = "cat" ]; then cat "$2" 2>/dev/null; else return 0; fi; }
  _marker_write() { printf "%s" "$1" > "$2"; }
  _backend_dead_weak_path() { echo "${SYNC_STATE_DIR}/weak.json"; }
  eval "$(sed -n '/_backend_dead_weak_bump() {/,/^}/p' "$TE")"
  eval "$(sed -n '/_backend_dead_weak_reset() {/,/^}/p' "$TE")"
  _backend_dead_weak_reset "openlist:wopan175" >/dev/null 2>&1
  _backend_dead_weak_bump "openlist:wopan175"
) > "$W/o2" 2>&1
tr -d "\n" < "$W/o2" | grep -qx "1" && ok "reset 后回到 1" || bad "$(cat "$W/o2" | tr "\n" " ")"
rm -rf "$W"

echo "=== 6: 阈值/持久化开关变量被正确引用 ==="
grep -q "OPENLIST_BACKEND_DEAD_THRESHOLD:-3" "$TE" && ok "阈值默认 3" || bad "阈值默认缺失"
grep -q "OPENLIST_BACKEND_DEAD_PERSIST" "$TE" && ok "保留 persist=all 排查开关" || bad "persist 开关丢失"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
