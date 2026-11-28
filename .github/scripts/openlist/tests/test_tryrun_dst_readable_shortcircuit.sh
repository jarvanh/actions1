#!/bin/bash
# 预演目标端可读性检查的后端级短路（容器不可达时不再逐路径各等 2min）
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }

if [ -z "${OL_DIR:-}" ]; then _here=$(cd "$(dirname "$0")" && pwd); OL_DIR="$_here/.."; fi
RT="$OL_DIR/restore_tryrun.sh"

echo "=== 1: 函数含后端根短路 ==="
body=$(sed -n '/^_tryr_dst_readable() {/,/^}/p' "$RT")
echo "$body" | grep -q "_root=" && ok "计算后端根" || bad "缺 _root"
echo "$body" | grep -q "_TRYR_DST_READABLE\[\"\$_root\"\]=\"\$rc\"" && ok "失败时记到后端根" || bad "未记到后端根"

echo "=== 2: 短路只复用失败结论（成功不复用） ==="
echo "$body" | grep -q '!= "0"' && ok "仅当根结论非 0 才短路" || bad "未限制失败才短路"

echo "=== 3: 语义 —— 同后端多路径只探测一次 ==="
W=$(mktemp -d)
(
  PROBES=0
  declare -gA _TRYR_DST_READABLE=()
  _tryr_rclone_read() { PROBES=$((PROBES+1)); return 1; }  # 模拟不可读
  eval "$(sed -n '/^_tryr_dst_readable() {/,/^}/p' "$RT")"
  _tryr_dst_readable "openlist:wopan175/4/a" >/dev/null 2>&1
  _tryr_dst_readable "openlist:wopan175/4/b" >/dev/null 2>&1
  _tryr_dst_readable "openlist:wopan175/4/c" >/dev/null 2>&1
  echo "probes=$PROBES"
) > "$W/o" 2>&1
grep -q "probes=1" "$W/o" && ok "同后端 3 条路径只探测 1 次" || bad "$(cat "$W/o")"

echo "=== 4: 不同后端互不影响 ==="
(
  PROBES=0
  declare -gA _TRYR_DST_READABLE=()
  _tryr_rclone_read() { PROBES=$((PROBES+1)); return 1; }
  eval "$(sed -n '/^_tryr_dst_readable() {/,/^}/p' "$RT")"
  _tryr_dst_readable "openlist:wopan175/4/a" >/dev/null 2>&1
  _tryr_dst_readable "openlist:baidupanCrypt/1/b" >/dev/null 2>&1
  echo "probes=$PROBES"
) > "$W/o2" 2>&1
grep -q "probes=2" "$W/o2" && ok "两个后端各探测一次" || bad "$(cat "$W/o2")"

echo "=== 5: 可读时不短路（必须真探每个路径） ==="
(
  PROBES=0
  declare -gA _TRYR_DST_READABLE=()
  _tryr_rclone_read() { PROBES=$((PROBES+1)); return 0; }  # 模拟可读
  eval "$(sed -n '/^_tryr_dst_readable() {/,/^}/p' "$RT")"
  _tryr_dst_readable "openlist:wopan175/4/a" >/dev/null 2>&1
  _tryr_dst_readable "openlist:wopan175/4/b" >/dev/null 2>&1
  echo "probes=$PROBES"
) > "$W/o3" 2>&1
grep -q "probes=2" "$W/o3" && ok "可读时每个路径都真探（不漏判）" || bad "$(cat "$W/o3")"

rm -rf "$W"
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
