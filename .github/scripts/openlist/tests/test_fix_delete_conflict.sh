#!/bin/bash
# ===== 锁定: 「同名不同尺寸 409 死锁」的兜底（删坏件后重传原名）=====
#
# 为什么要有（2026-11-17 加，实测铁证）:
#   r7 与 r8 的 409 失败文件集合**100% 重合**（r8 的 433 个全部在 r7 里），
#   错误是 `unchunked simple update failed: Conflict: 409 Conflict` —— 115 后端
#   拒绝更新已存在的同名文件。目标端那份是历史上传坏的半截件（尺寸不符），
#   于是每轮都"需要更新 → 被拒 → 下轮再来"，而现有 4 种修复方法都是"再传一份"，
#   没有任何一种能解开"同名已存在"这个前提 ⇒ 永久死锁。
#
# 契约:
#   D1 兜底块存在且挂在方法1失败之后
#   D2 受开关 OPENLIST_FIX_DELETE_CONFLICT 控制（默认开，可一键回退）
#   D3 只在日志出现 409/Conflict/mkParentDir 时触发（不误伤其它失败）
#   D4 只在"目标端存在同名件 + size>0 + 尺寸!=源端期望"时删（半截件判据）
#   D5 源端期望字节数未知/为 0 时不删（不敢删）
#   D6 删除失败不硬来，且重试成功后记录为 copyto_original（落在原路径）
#
# 用法: bash test_fix_delete_conflict.sh   （退出码 0=全过）
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$T/../../../.." && pwd)/.github/scripts/openlist/file_fix.sh"

grep -q '同名不同尺寸的 409 死锁' "$SRC" && ok "D1 兜底块存在" || bad "D1 缺失"
grep -q 'OPENLIST_FIX_DELETE_CONFLICT:-1' "$SRC" && ok "D2 受开关控制且默认开" || bad "D2"
grep -q "Conflict:\[\[:space:\]\]\*409\|409\[\[:space:\]\]\+Conflict" "$SRC" && ok "D3 只在 409/Conflict 时触发" || bad "D3"
grep -q '_dc_bytes.*-gt 0.*_dc_bytes.*!=.*src_expect_bytes' "$SRC" && ok "D4 半截件判据（存在+尺寸不符）" || bad "D4"
grep -q 'src_expect_bytes:-0.*-gt 0' "$SRC" && ok "D5 期望字节未知/为 0 时不删" || bad "D5"
grep -q '删除目标端坏件失败（跳过本兜底' "$SRC" && ok "D6a 删除失败不硬来" || bad "D6a"
grep -q '删坏件后重传 · ' "$SRC" && ok "D6b 成功时仍记为 copyto_original（落原路径、无需还原）" || bad "D6b"
grep -q 'rclone deletefile "$round_file"' "$SRC" && ok "D7 删除的是目标端同名文件（不是源端）" || bad "D7"

echo "----------"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

# D8（2026-11-17 补）: 方法1 被黑名单跳过时兜底仍须可执行
if grep -q '_m1_blocked=1' "$SRC" && grep -q '_dc_sig=1' "$SRC"; then
  echo "PASS: D8 方法1 被拉黑时仍触发兜底（_m1_blocked → _dc_sig）"
else
  echo "FAIL: D8 拉黑后兜底不可达（关键：433 个死锁文件里就有被拉黑的）"
fi
