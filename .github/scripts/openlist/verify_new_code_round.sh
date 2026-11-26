#!/bin/bash
# 新代码轮的生产验证清单（2026-11-25 加）
#
# 用途: 每一轮新代码跑完后，跑本脚本核对『改动是否真的在生产生效』。
#   只读（gh run view 下载日志 + grep），不改任何远端数据。
#
# 用法: bash .github/scripts/openlist/verify_new_code_round.sh <run_id>
#   例: bash .github/scripts/openlist/verify_new_code_round.sh 45623471576
set -u
RUN_ID="${1:-}"
if [ -z "$RUN_ID" ]; then
  echo "用法: $0 <run_id>" >&2
  exit 2
fi

LOG="/tmp/verify_round_${RUN_ID}.log"
echo "=== 下载 run ${RUN_ID} 日志 ==="
if ! gh run view "$RUN_ID" --log > "$LOG" 2>/dev/null || [ ! -s "$LOG" ]; then
  echo "❌ 取不到日志（run 未结束或已过期）" >&2
  exit 1
fi
sed -E 's/\x1B\[[0-9;]*m//g' "$LOG" > "$LOG.clean"
LOG="$LOG.clean"
echo "日志行数: $(wc -l < "$LOG")"

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); echo "  ✅ $1"; }
bad()  { fail=$((fail+1)); echo "  ❌ $1"; }
na()   { skip=$((skip+1)); echo "  ⏭  $1（本轮未出现，非失败）"; }

echo ""
echo "=== 1. 持久化复核三分口径（90afa38）==="
n_un=$(grep -c '⏸ 复核未定' "$LOG" || true)
n_bad=$(grep -c '❌ 未持久化' "$LOG" || true)
n_ok=$(grep -c '✅ 通过 ·' "$LOG" || true)
echo "  复核未定 $n_un · 未持久化 $n_bad · 通过 $n_ok"
if grep -q '复核不可信' "$LOG"; then
  ok "出现「复核不可信」提示（未定条目被单列，未拉黑）"
elif [ "$n_un" -eq 0 ] && [ "$n_bad" -eq 0 ]; then
  na "本轮无修复复核记录"
else
  ok "复核已执行（无全灭误判迹象）"
fi
  # 空值假失败的**确定判据**（2026-11-25 加）: 旧代码在列举失败时把 after_sz 写成空串，
  #   日志呈现为「期望<N> 实际 ·」（「实际」后紧跟空格+间隔号，没有数字）。
  #   实测旧轮 45542724284 有 172 条，全部集中在容器重启后那一个小时内。
  #   新代码走三分口径后这类行应为 0；非 0 即说明改动未生效或回归。
  n_empty=$(grep -cE '未持久化 · .* 期望[0-9]+ 实际 ?·' "$LOG" || true)
  if [ "${n_empty:-0}" -eq 0 ]; then
    ok "无空值假失败（期望N 实际· 形态 0 条）"
  else
    bad "仍有 ${n_empty} 条空值假失败（期望N 实际·）—— 三分口径未生效或回归"
  fi

echo ""
echo "=== 2. 公平份额按并行度折算（a76a5c9）==="
share_line=$(grep -o '份额 [0-9]*min（需服务 [0-9]* 个）' "$LOG" | head -3)
if [ -n "$share_line" ]; then
  echo "  前几处份额: $(echo "$share_line" | tr '\n' ' ')"
  # 16 对 / 并行 2 时折算后应 ≥29min（1792s）；旧代码恒 25min
  if echo "$share_line" | grep -qE '份额 (29|3[0-9]|[4-9][0-9])min'; then
    ok "份额已按并行度折算（≥29min，旧代码恒 25min）"
  else
    bad "份额仍是旧口径（25min 或更低）"
  fi
else
  na "本轮无『份额 Nmin（需服务 N 个）』行"
fi

echo ""
echo "=== 3. 缺失/沿用/成功 三口径一致（996d15e + 62d764b + 二次扣减修正）==="
eff=$(grep -o '本轮修复成效: 成功 [0-9]*（新落盘 [0-9]* · 沿用上轮 [0-9]*） · 缺失 [0-9]*' "$LOG" | tail -1)
if [ -n "$eff" ]; then
  echo "  $eff"
  succ=$(echo "$eff" | sed -n 's/.*成功 \([0-9]*\)（.*/\1/p')
  fresh=$(echo "$eff" | sed -n 's/.*新落盘 \([0-9]*\) ·.*/\1/p')
  res=$(echo "$eff" | sed -n 's/.*沿用上轮 \([0-9]*\)）.*/\1/p')
  miss=$(echo "$eff" | sed -n 's/.*缺失 \([0-9]*\)$/\1/p')
  # 口径（2026-11-25 run 45623471576 实证后修正）:
  #   _sync_accumulate_fixed_results 已在入账前按 original 剔除沿用条目 ⇒
  #   ROUND_FIXED_OK 现在本身就是「新落盘」口径；沿用是**独立**计数，与成功不可加。
  #   旧实现还执行 NEW = OK − REUSED，13−568 钳成 0，于是输出「成功 13（新落盘 0 · 沿用 568）」
  #   看似自相矛盾。正确判据: 新落盘 == 成功；不再要求沿用 ≤ 成功。
  if [ -n "$succ" ] && [ -n "$fresh" ]; then
    if [ "$fresh" = "$succ" ]; then
      ok "新落盘($fresh) == 成功($succ) —— 无二次扣减（新口径正确）"
    else
      bad "新落盘($fresh) ≠ 成功($succ) —— 二次扣减未修好（旧: 13−568→0）"
    fi
  else
    bad "解析不出成功/新落盘字段"
  fi
  if [ -n "$res" ]; then ok "沿用数独立输出（$res 个，不与成功相加）"; fi
  # 缺失数（2026-11-25）: 以事件日志 MISSING 行数去重为真源，变量残值兜底。
  if [ -z "$miss" ]; then bad "解析不出缺失数";
  elif [ "$miss" -eq 0 ]; then na "本轮缺失数为 0（无缺口）";
  else ok "缺失数已产出（$miss 个）"; fi
else
  na "本轮无『本轮修复成效』行（预算内未跑到收尾修复统计）"
fi

echo ""
echo "=== 4. 强杀对已结算字节（dcd1db5）==="
if grep -q '被强杀对已结算' "$LOG"; then
  ok "出现『被强杀对已结算 X』（不再是『传输 0 B』的无解释）"
elif grep -q '另有 [0-9]* 对被强杀' "$LOG"; then
  na "有强杀但已结算为 0（本轮强杀对确实未结算任何字节）"
else
  na "本轮无强杀"
fi

echo ""
echo "=== 5. 同步对完成度（e96cee2）==="
if grep -q '同步对完成度:' "$LOG"; then
  ok "本轮日志含『同步对完成度: N/M』"
else
  bad "缺『同步对完成度』行（说明新代码未生效或走的是串行路径）"
fi

echo ""
echo "=== 6. 缺口归因（81680b5）==="
if grep -q '缺口归因' "$LOG"; then
  cnt=$(grep -c '缺口归因' "$LOG" || true)
  ok "出现缺口归因 $cnt 处"
  grep '缺口归因' "$LOG" | head -2 | sed 's/^/     /'
  grep -q '缺口归因: EXHAUSTED 台账未读到' "$LOG" && echo "     ⚠️ 有『台账未读到』（不猜 0 的保守分支被触发）"
else
  na "本轮无拒写（所有对被接受）"
fi

echo ""
echo "=== 7. 镜像计数截断标注（112b0aa）==="
if grep -q 'sync_state 镜像完成' "$LOG"; then
  grep 'sync_state 镜像完成' "$LOG" | tail -1 | sed 's/^/  /'
  ok "镜像计数行存在"
else
  na "无镜像计数行"
fi

echo ""
echo "=== 8. 无用快照不得复活（dab9739）==="
if grep -q '重启前大小检查' "$LOG"; then bad "又出现『重启前大小检查』（无用快照段复活）"; else ok "无『重启前大小检查』（无用列举已消除）"; fi

echo ""
echo "=== 汇总: PASS=$pass FAIL=$fail SKIP=$skip ==="
[ "$fail" -eq 0 ]