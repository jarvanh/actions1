#!/bin/bash
# 收尾统计口径：沿用上轮计数必须按文件名去重（2026-11-25 加）
#
# 生产实证（actions1 run 45284470201）:
#   本轮修复成效: 成功 1189（新落盘 0 · 沿用上轮 1225）
#   同轮 `✅ 修复成功 ·` 实际 8 行、`♻ 沿用上轮修复` 1226 行。
#   「沿用 1225 > 成功 1189」在 fix_list = 新落盘 ∪ 沿用 的口径下**逻辑不可能** ——
#   ROUND_FIXED_OK 来自 fix_list 且已 unique_by(.original) 去重，而 REUSED 原先
#   用 `grep -c` 未去重；同一文件被多个子目录/重试路径重复记 REUSED ⇒ 虚高 ⇒
#   相减为负被钳成 0 ⇒「新落盘 0」恒成立，真实产出被吞掉。
#
# 本测锁住: workflow 里 REUSED 计数必须走 `cut -d'|' -f2 | sort -u` 去重。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WF="$_REPO_ROOT/.github/workflows/openlist.yml"

grep -q "grep '\^REUSED|' /tmp/ol_fix_events.log" "$WF" \
  && ok "T1 REUSED 取自事件日志" || bad "T1 未从事件日志取 REUSED"
grep -q "cut -d'|' -f2 | sort -u" "$WF" \
  && ok "T2 REUSED 计数按文件名去重（cut -f2 | sort -u）" || bad "T2 缺去重（沿用会虚高超过成功）"
# T3: 只查**代码行**（注释里保留旧写法作为对照，不算违规）
grep -vE '^\s*#' "$WF" | grep -q "grep -c '\^REUSED|'" \
  && bad "T3 代码里仍存在未去重的 grep -c REUSED" || ok "T3 代码中未去重的计数已移除（注释对照不算）"
grep -q 'ROUND_FIXED_NEW=$(( ROUND_FIXED_OK - ROUND_REUSED ))' "$WF" \
  && ok "T4 新落盘 = 成功 - 沿用（同口径相减）" || bad "T4 新落盘公式缺失"

# T5: 行为——去重后沿用数不得大于成功数（构造 3 文件、其中 2 个重复记 REUSED）
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
: > "$W/ev"
printf 'REUSED|a.mp4|x\nREUSED|a.mp4|x\nREUSED|b.mp4|x\nREUSED|b.mp4|x\nREUSED|c.mp4|x\n' > "$W/ev"
reused=$(grep '^REUSED|' "$W/ev" | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')
[ "$reused" = "3" ] && ok "T5 5 行重复事件 → 去重后 3 个文件" || bad "T5 去重结果=$reused（期望 3）"
raw=$(grep -c '^REUSED|' "$W/ev")
[ "$raw" = "5" ] && ok "T6 未去重口径确为 5（正是会虚高的旧行为）" || bad "T6 raw=$raw"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
