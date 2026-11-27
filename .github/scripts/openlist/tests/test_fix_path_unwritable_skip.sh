#!/bin/bash
# 修复管线的「路径已判不可写」快跳过 —— 静态+语义断言
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }

if [ -z "${OL_PIPELINE:-}" ]; then
  _here=$(cd "$(dirname "$0")" && pwd)
  OL_PIPELINE="$_here/../file_fix_pipeline.sh"
fi
[ -f "$OL_PIPELINE" ] || { echo "NG pipeline missing"; echo "PASS=0 FAIL=1"; exit 1; }
WORK_OUT=$(mktemp); trap 'rm -f "$WORK_OUT"' EXIT

echo "=== 1: 快跳过块存在于 try_fix_failed_file 之前 ==="
g_line=$(grep -n "路径级不可写快跳过" "$OL_PIPELINE" | head -1 | cut -d: -f1)
c_line=$(grep -n 'try_fix_failed_file "$source_path" "$dest_path" "$task_name" "$failed_line"' "$OL_PIPELINE" | head -1 | cut -d: -f1)
if [ -n "$g_line" ] && [ -n "$c_line" ] && [ "$g_line" -lt "$c_line" ]; then
  ok "守卫(第${g_line}行)在修复调用(第${c_line}行)之前"
else
  bad "顺序不对 g=$g_line c=$c_line"
fi

echo "=== 2: 守卫用 _path_unwritable_hit 判定 ==="
if sed -n "${g_line},$((g_line+20))p" "$OL_PIPELINE" | grep -q "_path_unwritable_hit"; then ok "使用路径级不可写判据"; else bad "缺判据"; fi

echo "=== 3: 跳过时不写黑名单（只本轮跳过） ==="
blk=$(sed -n "${g_line},$((g_line+20))p" "$OL_PIPELINE" | grep -c "_blacklist_add" || true)
[ "${blk:-0}" = "0" ] && ok "未写黑名单（后端恢复后仍会重试）" || bad "不应写黑名单，实际 $blk 处"

echo "=== 4: 跳过时记录 DEFERRED 事件 ==="
if sed -n "${g_line},$((g_line+20))p" "$OL_PIPELINE" | grep -q "_fix_event DEFERRED"; then ok "记录 DEFERRED，可观测"; else bad "缺 DEFERRED 事件"; fi

echo "=== 5: 语义验证 —— 标记后命中、邻居不误伤 ==="
(
  declare -A _PATH_UNWRITABLE_ROUND=()
  _path_unwritable_mark() { _PATH_UNWRITABLE_ROUND["$1"]=1; }
  _path_unwritable_hit() { [ "${_PATH_UNWRITABLE_ROUND[$1]:-0}" = "1" ]; }
  _path_unwritable_mark "openlist:wopan176Crypt/3/teacher-of-magic"
  a=1; _path_unwritable_hit "openlist:wopan176Crypt/3/teacher-of-magic" || a=0
  b=0; _path_unwritable_hit "openlist:wopan176Crypt/3/foot-fetish-center" && b=1
  echo "hit_marked=$a hit_other=$b"
) > "$WORK_OUT" 2>&1
grep -q "hit_marked=1 hit_other=0" "$WORK_OUT" && ok "标记命中/邻居不误伤" || bad "$(cat "$WORK_OUT")"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
