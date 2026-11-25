#!/bin/bash
# 同步对完成度：trend 必须回答「同步完没完」（2026-11-25 加）
#
# 病灶: trend.jsonl 一直只有 transferred_bytes / remaining_bytes，而 skip_preview=true
#   轮 remaining_bytes 恒 null ⇒ 「传了多少」有了，「还剩多少 / 16 个同步对里几个真正
#   同步完成」都没有。后者才是「同步是否完成」的直接答案：写成 marker = 目标端文件数
#   已达源端（判据见 sync_marker.sh 拒写分支）。
#
# 本测锁住:
#   A. 并行汇总把 PAIRS_TOTAL / PAIRS_SYNCED 落 /tmp/ol_pair_stats.env
#   B. skipped 单独计数（配额已满不是「完成」）
#   C. trend.jsonl 写入 pairs_total / pairs_synced 两字段，缺失时写 null（不写 0 冒充）
#   D. 通知只在数据有效时加「同步对完成度」行（旧样本/串行不出现占位噪声）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TE="$_REPO_ROOT/.github/scripts/openlist/task_engine.sh"
TR="$_REPO_ROOT/.github/scripts/openlist/sync_trend.sh"

# ===== A. 生产端落盘 =====
grep -q 'PAIRS_TOTAL=%s' "$TE" && ok "A1 并行汇总写 PAIRS_TOTAL" || bad "A1 缺 PAIRS_TOTAL"
grep -q 'PAIRS_SYNCED=%s' "$TE" && ok "A2 并行汇总写 PAIRS_SYNCED" || bad "A2 缺 PAIRS_SYNCED"
grep -q '/tmp/ol_pair_stats.env' "$TE" && ok "A3 落在 /tmp/ol_pair_stats.env（跨 step 传递）" || bad "A3 路径不对"
grep -q '_sync_pairs=$(( _done_n - _failed_n - _trunc_n - _skipped_n ))' "$TE" \
  && ok "A4 完成数 = 总数 − 失败 − 交棒 − 跳过" || bad "A4 完成数公式缺失"

# ===== B. skipped 单独计数 =====  
grep -q 'skipped) _skipped_n=$((_skipped_n + 1))' "$TE" \
  && ok "B1 skipped 单独计数（配额已满不算完成）" || bad "B1 未单独计 skipped"
grep -q '_skipped_n=0' "$TE" && ok "B2 计数器已初始化" || bad "B2 未初始化"

# ===== C. trend 字段与 null 语义 =====
grep -q 'pairs_total":%s,"pairs_synced":%s' "$TR" \
  && ok "C1 trend.jsonl 含两个新字段" || bad "C1 字段缺失"
grep -q '"${_pairs_total:-null}" "${_pairs_synced:-null}"' "$TR" \
  && ok "C2 无数据时写 null（不写 0 冒充已同步）" || bad "C2 null 兜底缺失"
grep -q 'sed -n .s/^PAIRS_SYNCED=//p.' "$TR" \
  && ok "C3 读侧从 /tmp/ol_pair_stats.env 取值" || bad "C3 未读取统计文件"

# ===== D. 通知行条件渲染 =====
grep -q 'tg_add_kv msg "同步对完成度"' "$TR" \
  && ok "D1 通知有完成度行" || bad "D1 通知缺完成度行"
# 必须包在数字校验 if 内（否则旧样本会打印空占位）
grep -B3 'tg_add_kv msg "同步对完成度"' "$TR" | grep -q 'pairs_tot.*=~' \
  && ok "D2 完成度行包在数字校验内（旧样本不出现）" || bad "D2 缺数字校验，旧样本会打印空值"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]