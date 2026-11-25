#!/bin/bash
# 拒写时的缺口归因（2026-11-25 加）
#
# 背景: 顶层 marker 的判据是「目标端文件数 ≥ 源端」的**精确**校验 —— 只要还有 1 个
#   修不好的文件，顶层 marker 就永远不写 ⇒ last_success 恒空 ⇒ --1d-skip 永不生效
#   ⇒ 每轮全量重列+重传这棵大树。实测 478 个 marker 里 419 个有 last_success（子目录级），
#   而 16 个顶层对里 13 个没有（run 45473411880 / 45541260698 两轮一致）。
#   复盘第一个要回答的问题是「这棵树卡在已知永久失败，还是有新缺口」，日志此前只有两个
#   数字（目标端/源端文件数），回答不了。
#
# 本测锁住:
#   A. 拒写分支读 EXHAUSTED 台账并按 task 分组计数
#   B. 台账读不到时写「未知」而不是猜 0（写 0 会把「没读到」伪装成「没有永久失败」）
#   C. 两种归因文案（⊆ 台账内 / 台账外还有 N 个）都存在且互斥
#   D. 台账只读一次（进程内缓存），不在每个拒写点重复拉远端
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SM="$_REPO_ROOT/.github/scripts/openlist/sync_marker.sh"

grep -q '缺口归因' "$SM" && ok "A1 拒写分支有缺口归因" || bad "A1 缺缺口归因"
grep -q 'exhausted_ledger.json' "$SM" && ok "A2 读 EXHAUSTED 台账" || bad "A2 未读台账"
grep -q "select(.value.task == \$t)" "$SM" && ok "A3 按 task 分组计数" || bad "A3 分组口径不对"

# B: 读不到必须是「未知」而不是 0
grep -q '_ex_n="未知"' "$SM" && ok "B1 默认值是「未知」" || bad "B1 默认值不是未知"
grep -q '不猜 0' "$SM" && ok "B2 注释写明不猜 0 的理由" || bad "B2 缺理由"
if grep -q '_ex_n=0$' "$SM"; then bad "B3 出现把未知硬置 0"; else ok "B3 未把未知硬置 0"; fi

# C: 两种归因文案
grep -q '没有台账外的新缺口' "$SM" && ok "C1 有「⊆ 台账内」分支" || bad "C1 缺该分支"
grep -q '台账外还有' "$SM" && ok "C2 有「台账外还有 N 个」分支" || bad "C2 缺该分支"

# D: 缓存只读一次
grep -q '_ex_cache=' "$SM" && ok "D1 有进程内缓存" || bad "D1 缺缓存"
# rclone cat 台账必须包在 [ ! -f cache ] 内（否则每个拒写点都拉远端）
awk '/_ex_cache/{c=1} c&&/rclone cat/{found=1} END{exit !found}' "$SM" \
  && ok "D2 台账读取点存在" || bad "D2 找不到台账读取"
if python3 - "$SM" <<'PY'; then
import sys,re
src=open(sys.argv[1],encoding="utf-8").read().split(chr(10))
ok=False
for j,l in enumerate(src):
    if "_ex_cache" in l and l.strip().startswith("if ["):
        nxt=chr(10).join(src[j+1:j+4])
        ok = "rclone cat" in nxt
        break
sys.exit(0 if ok else 1)
PY
  ok "D3 rclone cat 只在缓存缺失时执行"
else
  bad "D3 台账读取未被缓存条件包住"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]