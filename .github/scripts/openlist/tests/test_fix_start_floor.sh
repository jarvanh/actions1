#!/bin/bash
# ===== 锁定: 修复管线"开工门槛"是单文件起步阈值，不是 600s 工作片 =====
#
# 为什么要有（2026-11-18，run 44207166413/44189409327/44118727444/44090571897 四轮实证）:
#   修复管线被调用在**同步对尾部**（日志「尾部 120s 留给修复管线」×16），
#   而开工判据原是 `now + OPENLIST_FIX_MIN_SLICE_SECONDS(600) >= deadline`
#   ⇒ 剩余恒 < 600s ⇒ **恒收摊**。现场: 每轮 21 个「缺失文件修复 · 共 N 个」
#   批次（400/324/227/52/1…）每批紧跟「预算将尽，优雅收摊」⇒ 本轮处理 0 个；
#   FIX_ATTEMPT 仅 4~6，且「方法1·原名直传」尝试次数恒为 0 —— 连方法1 都没
#   跑到，所以 57365f0 的「删坏件重传」兜底根本不可达。
#
# 契约:
#   F1 脚本里只设 _fix_start_floor（≥1 处），不再用 _fix_slice 做开工判据
#   F2 默认值 90s，且可用 OPENLIST_FIX_START_FLOOR_SECONDS 覆盖
#   F3 非数字输入回落到 90（set -u 下不能炸）
#   F4 workflow 显式注入 OPENLIST_FIX_START_FLOOR_SECONDS
#   F5 到点停仍由**逐文件**检查承担（循环内每次 check，不是只在批次头）
#   F6 收摊文案带上阈值，便于日志一眼看出用的是哪个门槛
#
# 用法: bash test_fix_start_floor.sh   （退出码 0=全过）
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$T/../../../.." && pwd)"
SRC="$R/.github/scripts/openlist/file_fix_pipeline.sh"
WF="$R/.github/workflows/openlist.yml"

grep -q '_fix_start_floor=' "$SRC" && ok "F1 逐文件闸用 _fix_start_floor" || bad "F1"
grep -q 'now + _fix_slice\|+ _fix_slice )) -ge' "$SRC" && bad "F1b 仍在用 _fix_slice 做开工判据" || ok "F1b 已无 _fix_slice 开工判据"
grep -q 'OPENLIST_FIX_START_FLOOR_SECONDS:-90' "$SRC" && ok "F2 默认 90s 且可覆盖" || bad "F2"
grep -q '=~ \^\[0-9\]+\$ \]\] || _fix_start_floor=90' "$SRC" && ok "F3 非数字回落到 90" || bad "F3"
grep -q 'OPENLIST_FIX_START_FLOOR_SECONDS: "90"' "$WF" && ok "F4 workflow 已注入阈值" || bad "F4"
n=$(grep -c '\$(( \$(date +%s) + _fix_start_floor )) -ge "\$_fix_dl"' "$SRC")
[ "$n" -ge 1 ] && ok "F5 到点停由循环内逐文件检查（命中 $n 处）" || bad "F5"
grep -q '剩余不足起步阈值 \${_fix_start_floor}s' "$SRC" && ok "F6 收摊文案带阈值" || bad "F6"
# F7: 折叠支路同修（同一病理）
grep -q 'local _fold_slice="${OPENLIST_FIX_START_FLOOR_SECONDS:-90}"' "$SRC" && ok "F7 折叠支路同用起步阈值" || bad "F7"

# ============================================================
# F8..F11（2026-11-19 加）: 修复路径的**终点**必须含过份额宽限窗口
#   为什么: bd724a9 把开工门槛降到 90s 后仍恒收摊（19~20 次/轮、方法1 尝试 0）
#   —— 因为修复被调用在份额到点**之后**，旧终点（=份额终点）已过期 ⇒ 剩余为负。
#   契约: task_engine 导出 OPENLIST_PAIR_REPAIR_DEADLINE_EPOCH（=份额终点+宽限，
#   并夹平台硬顶）；提供 repair_deadline_epoch()（与全局取小）；
#   修复/折叠两个闸优先用它，且旧函数链仍在（向后兼容）。
# ============================================================
TE="$R/.github/scripts/openlist/task_engine.sh"
grep -q 'export OPENLIST_PAIR_REPAIR_DEADLINE_EPOCH=' "$TE" && ok "F8 task_engine 导出修复专用终点" || bad "F8 未导出"
grep -q '+ ${OPENLIST_PAIR_OVERRUN_GRACE_SECONDS:-600}' "$TE" && ok "F9 终点 = 份额终点 + 宽限（默认 600s）" || bad "F9 未叠加宽限"
grep -q '^repair_deadline_epoch()' "$TE" && ok "F10 repair_deadline_epoch 已定义" || bad "F10 缺函数"
n_repair=$(grep -c 'declare -F repair_deadline_epoch' "$SRC")
[ "$n_repair" -ge 2 ] && ok "F11 修复与折叠两个闸都优先用它（命中 $n_repair 处）" || bad "F11 仅 $n_repair 处"
grep -q 'elif declare -F budget_deadline_epoch' "$SRC" && ok "F12 保留旧函数回退链（单测/调试环境兼容）" || bad "F12 缺回退链"

echo "----------"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
