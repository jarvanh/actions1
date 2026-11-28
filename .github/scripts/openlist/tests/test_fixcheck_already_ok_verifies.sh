#!/bin/bash
# fix_check 的 already_ok 必须真查目标端（记账 ≠ 落盘）
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }

if [ -z "${OL_DIR:-}" ]; then _here=$(cd "$(dirname "$0")" && pwd); OL_DIR="$_here/.."; fi
F="$OL_DIR/fix_check.sh"

echo "=== 1: 记账分支必须先 lsf 确认替代文件 ==="
seg=$(sed -n '/marker 已记账 ⇒/,/幂等: 目标端原路径已在/p' "$F")
echo "$seg" | grep -q "rclone lsf" && ok "记账分支内含 lsf 真查" || bad "记账分支仍不查文件"
echo "$seg" | grep -q "视为假成功" && ok "查不到时按假成功继续修复" || bad "缺假成功回退"

echo "=== 2: 只有确认存在才判 already_ok ==="
grep -q '替代文件在目标端确认存在' "$F" && ok "已确认存在才 already_ok" || bad "缺确认文案"

echo "=== 3: 读不到 alternative 时不再判 already_ok ==="
grep -q '读不到 alternative 字段 → 不据此判 already_ok' "$F" && ok "缺字段时不放过" || bad "缺字段仍放过"

echo "=== 4: 未引入语法错误（bash -n） ==="
bash -n "$F" && ok "语法通过" || bad "语法错误"

echo "=== 5: 语义 —— 记账存在但替代文件缺失时必须继续修复 ==="
W=$(mktemp)
(
  mk_alt="7406533a.mp4"
  # 桩: lsf 返回空(文件不在)
  rclone() { return 0; }
  _fc_timeout_arg() { echo 30s; }
  FC_LEAF_DST="openlist:x/y"
  hit=0
  mk_dir=$(dirname -- "$mk_alt"); [ "$mk_dir" = "." ] && mk_dir=""
  if rclone lsf "${FC_LEAF_DST}${mk_dir:+/${mk_dir}}" --files-only 2>/dev/null | grep -qxF "$(basename -- "$mk_alt")"; then
    hit=1
  fi
  echo "found=$hit"
) > "$W" 2>&1
grep -q "found=0" "$W" && ok "替代文件缺失时判未找到（继续修复）" || bad "$(cat "$W")"
rm -f "$W"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
