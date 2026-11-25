#!/bin/bash
# 收尾缺失数口径：必须来自事件日志并按文件名去重（2026-11-25 加）
#
# 生产实证（actions1 run 45473411880）:
#   本轮修复成效: 成功 1053（新落盘 0 · 沿用上轮 1065） · 缺失 9 · 未修复 0
#   同轮实际缺失远超 9 个 —— 「缺失」取自 SYNC_MISSING_TOTAL_RUN，而它是**进程内**
#   累计；每个并行同步对跑在 worker 子 shell 里，自增回不到收尾，只能读到最后一个
#   worker 的残值。成功口径来自 fix_list（本轮累计）⇒ 两者不对称，「未修复 = 缺失
#   − 成功」被钳成 0，「零新增落盘」告警的 N 也随之失真。
#
# 本测锁住三条不变量:
#   A. 缺失清单确定时逐条写 MISSING 事件（与 REUSED/ATTEMPT 同源，父子进程共见）
#   B. 收尾按第二列（文件名/相对路径）去重后计数，重复事件不虚高
#   C. 工作流里的 ROUND_MISSING 赋值确实来自 MISSING 事件日志，不再只信变量
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PIPE="$_REPO_ROOT/.github/scripts/openlist/file_fix_pipeline.sh"
WF="$_REPO_ROOT/.github/workflows/openlist.yml"

# ===== A. 生产端写入 MISSING 事件 =====
grep -q "printf 'MISSING|%s|'" "$PIPE" \
  && ok "A1 缺失清单确定时逐条写 MISSING 事件" \
  || bad "A1 未找到 MISSING 事件写入"
# 写入必须发生在 missing_list 非空的判据内（不能对空清单刷事件）
grep -A12 'if \[ -s "$missing_list" \]; then' "$PIPE" | grep -q 'MISSING|' \
  && ok "A2 MISSING 事件写在「清单非空」分支内" \
  || bad "A2 MISSING 事件位置不对（可能对空清单也写）"

# ===== B. 去重口径（行为验证） =====
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf 'MISSING|a/x.mp4|\nMISSING|a/x.mp4|\nMISSING|b/y.jpg|\nMISSING|b/y.jpg|\nMISSING|c/z.nfo|\n' > "$W/ev"
uniq_n=$(grep '^MISSING|' "$W/ev" | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')
[ "$uniq_n" = "3" ] && ok "B1 5 行重复 MISSING → 去重后 3 个文件" || bad "B1 去重结果=${uniq_n}（期望 3）"
raw_n=$(grep -c '^MISSING|' "$W/ev")
[ "$raw_n" = "5" ] && ok "B2 未去重口径确为 5（正是会虚高的旧行为）" || bad "B2 raw=${raw_n}"

# ===== C. 工作流消费端 =====
grep -vE '^\s*#' "$WF" | grep -q "grep '\^MISSING|'" \
  && ok "C1 收尾从事件日志读 MISSING" || bad "C1 收尾未读 MISSING 事件"
grep -vE '^\s*#' "$WF" | grep -q "MISSING|' /tmp/ol_fix_events.log" \
  && ok "C2 真源是 /tmp/ol_fix_events.log（与 REUSED 同源）" || bad "C2 真源路径不对"
grep -vE '^\s*#' "$WF" | grep -q 'ROUND_MISSING=$_round_missing_ev' \
  && ok "C3 去重结果确实赋给 ROUND_MISSING" || bad "C3 赋值缺失"
# 变量残值只能作兜底：赋值必须在 if 内、且条件是事件数 >0
grep -B3 'ROUND_MISSING=$_round_missing_ev' "$WF" | grep -q '_round_missing_ev" -gt 0' \
  && ok "C4 事件数为 0 时保留变量兜底（不把缺失清零）" || bad "C4 兜底条件缺失"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]