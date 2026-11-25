#!/bin/bash
# 护栏**判据**行为测试: 三条拒绝条件在各种输入下的真假，与 sync 是否被跳过一致
#
# 与 test_rebuild_guards.sh 的分工: 那个是静态断言（护栏代码在不在），本测是判据行为。
#
# 为什么不去 eval 整段护栏代码: 护栏里用 `continue` 依赖外层 `for m in $markers`，
#   且后面紧跟 rclone sync 调用；用 awk 抽片段极易截断在 if 中间（本测第一版就踩了），
#   测出来的红是抽取错误而非代码问题。改为**逐条复刻判据表达式**并断言其真假 ——
#   表达式与源码保持同形（下方有断言锁住两者不漂移）。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
FR="$_REPO_ROOT/.github/scripts/openlist/file_restore.sh"

# ===== 防漂移: 源码里必须存在这三个判据原文 =====
grep -qF '[ "$_cnt_dst" -eq 0 ] && [ "$_cnt_src" -gt 0 ]' "$FR" \
  && ok "G1 护栏① 判据原文在源码中" || bad "G1 护栏① 判据已变（本测需同步更新）"
grep -qF '[ "$need_excl" -gt 0 ] && [ "$got_excl" -lt "$need_excl" ]' "$FR" \
  && ok "G2 护栏② 判据原文在源码中" || bad "G2 护栏② 判据已变"
grep -qF '[ "$_cnt_src" -ge 100 ] && [ "$_cnt_dst" -lt $(( _cnt_src / 2 )) ]' "$FR" \
  && ok "G3 护栏③ 判据原文在源码中" || bad "G3 护栏③ 判据已变"

# ===== 判据行为（与源码同形）=====
g1() { _cnt_dst=$1; _cnt_src=$2; [ "$_cnt_dst" -eq 0 ] && [ "$_cnt_src" -gt 0 ] && echo REJECT || echo PASS; }
g2() { need_excl=$1; got_excl=$2; [ "$need_excl" -gt 0 ] && [ "$got_excl" -lt "$need_excl" ] && echo REJECT || echo PASS; }
g3() { _cnt_dst=$1; _cnt_src=$2; allow=${3:-0}; [ "$allow" != "1" ] && [ "$_cnt_src" -ge 100 ] && [ "$_cnt_dst" -lt $(( _cnt_src / 2 )) ] && echo REJECT || echo PASS; }

# 护栏①
[ "$(g1 0 100)" = REJECT ] && ok "①空源(0/100) → 拒绝" || bad "①空源未拒绝"
[ "$(g1 0 0)" = PASS ]   && ok "①双空(0/0) → 放行（没有可删的）" || bad "①双空被误拦"
[ "$(g1 50 100)" = PASS ] && ok "①正常(50/100) → 放行" || bad "①正常被误拦"

# 护栏②
[ "$(g2 100 3)" = REJECT ] && ok "②清单不全(100应有/3实得) → 拒绝" || bad "②清单不全未拒绝"
[ "$(g2 100 100)" = PASS ] && ok "②清单完整(100/100) → 放行" || bad "②清单完整被误拦"
[ "$(g2 0 0)" = PASS ]     && ok "②无排除条目(0/0) → 放行" || bad "②无条目被误拦"

# 护栏③
[ "$(g3 10 100 0)" = REJECT ] && ok "③大幅收缩(10/100,未放行) → 拒绝" || bad "③大幅收缩未拒绝"
[ "$(g3 10 100 1)" = PASS ]   && ok "③大幅收缩+显式放行 → 放行" || bad "③放行开关无效"
[ "$(g3 100 100 0)" = PASS ]  && ok "③等比(100/100) → 放行" || bad "③等比被误拦"
[ "$(g3 60 100 0)" = PASS ]   && ok "③小幅收缩(60/100 > 一半) → 放行" || bad "③小幅收缩被误拦"
[ "$(g3 10 100 0)" = REJECT ] && ok "③小规模(源端=100 边界) → 拒绝" || bad "③边界不对"
[ "$(g3 0 50 0)" = PASS ]     && ok "③源端≤100 不触发（阈值保护，避免小库误拦）" || bad "③小库被误拦"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]