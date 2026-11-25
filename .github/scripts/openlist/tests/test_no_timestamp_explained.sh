#!/bin/bash
# 「标记无时间戳」必须说清为何继续同步（2026-11-25 加）
#
# 背景: 顶层同步对的 marker 判据是「目标端文件数 ≥ 源端」的精确校验 —— 只要还有 1 个
#   修不好的文件就永远不写 last_success ⇒ 该分支恒走 ⇒ --1d-skip 永不生效 ⇒ 每轮全量
#   重列+重传。实测 478 个 marker 里 419 个有 last_success（子目录级），而 16 个顶层对里
#   13 个没有（run 45473411880 / 45541260698 一致）。
#   原日志只有「标记无时间戳，继续同步」一句，读的人无法区分:
#     ① 从未同步过（新对）② 上轮被拒写（有缺口）③ skip 依据被作废过
#
# 本测锁住:
#   A. 该分支带判据来源提示（last_refusal / skip_basis_invalidated / fixed_count 三选一）
#   B. 仍必须 return 0（继续同步）—— 提示不得改变控制流
#   C. 提示文案含「精确校验口径」，把「为什么不跳过」的依据写在日志里
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SM="$_REPO_ROOT/.github/scripts/openlist/sync_marker.sh"

grep -q 'last_success 为空' "$SM" && ok "A1 有明确的空时间戳说明" || bad "A1 缺说明"
grep -q 'last_refusal.sig' "$SM" && ok "A2 带拒写缺口签名" || bad "A2 缺口签名缺失"
grep -q 'skip_basis_invalidated_reason' "$SM" && ok "A3 带作废原因" || bad "A3 作废原因缺失"
grep -q '有修复条目' "$SM" && ok "A4 带修复条目提示" || bad "A4 修复条目提示缺失"
grep -q '精确校验口径' "$SM" && ok "C1 说明精确校验口径" || bad "C1 缺口径说明"

# B: 必须仍然 continue 同步（return 0）
if awk '/last_success 为空/{f=1} f&&/return 0/{r=1} f&&/^  fi$/{exit} END{exit !r}' "$SM"; then
  ok "B1 该分支仍 return 0（继续同步，行为不变）"
else
  bad "B1 控制流被改动（不再继续同步）"
fi

# D: 1d-skip 判定本身未被改坏
grep -q '检查是否在跳过时间窗口内' "$SM" && ok "D1 1d-skip 判定仍在" || bad "D1 1d-skip 判定丢失"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]