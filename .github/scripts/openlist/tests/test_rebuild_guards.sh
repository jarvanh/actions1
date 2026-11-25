#!/bin/bash
# 破坏性镜像恢复的三道 fail-safe 护栏（2026-11-25 加）
#
# 背景: rebuild_source_from_target 是全库**唯一会删源端**的路径
#   （rclone sync 目标端→源端，删除源端多余文件）。用户红线是「绝对不能修改源端」。
#   两种已实证的事故形态:
#     ① 目标端列举**成功但为空**（OpenList 驱动重建索引时的「成功的空」）⇒ 删光源端整棵子树；
#     ② 排除清单不完整 ⇒ 修复条目的源端原文件被当「目标端没有」删掉。
#   本测只做**静态断言**（不执行任何 sync）: 护栏必须存在于代码里且不可被静默删除。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
FR="$_REPO_ROOT/.github/scripts/openlist/file_restore.sh"

# 只取 rebuild_source_from_target 函数体，避免把 restore_source_from_target（非破坏性）算进来
BODY=$(awk '/^rebuild_source_from_target\(\)/,/^}/' "$FR")

[ -n "$BODY" ] && ok "A1 取到 rebuild_source_from_target 函数体" || bad "A1 函数体为空"

# 护栏①: 空源拒绝
printf '%s' "$BODY" | grep -q '拒绝镜像该 marker: 目标端' \
  && ok "B1 护栏① 空源拒绝存在" || bad "B1 缺空源护栏（空列表会删光源端）"
printf '%s' "$BODY" | grep -q '_cnt_dst.*-eq 0.*&&.*_cnt_src.*-gt 0' \
  && ok "B2 护栏① 判据是「目标端 0 且源端 >0」" || bad "B2 护栏① 判据不对"

# 护栏②: 排除清单完整性
printf '%s' "$BODY" | grep -q 'need_excl=\$((need_excl + 2))' \
  && ok "C1 每条命中累计 2 行（替代形态 + 原路径）" || bad "C1 缺 need_excl 累计"
printf '%s' "$BODY" | grep -q 'got_excl.*-lt.*need_excl' \
  && ok "C2 护栏② 比对实际行数 vs 应有行数" || bad "C2 缺排除清单完整性校验"

# 护栏③: 大幅收缩需显式放行
printf '%s' "$BODY" | grep -q 'OPENLIST_REBUILD_ALLOW_SHRINK' \
  && ok "D1 护栏③ 有显式放行开关" || bad "D1 缺收缩护栏"

# 三道护栏都必须 continue（跳过该 marker），不能只告警后继续删
guards=$(printf '%s' "$BODY" | grep -c '拒绝镜像该 marker')
[ "$guards" = "3" ] && ok "E1 三道护栏齐备（3 处拒绝）" || bad "E1 拒绝处=$guards（期望 3）"
cont=$(printf '%s' "$BODY" | awk '/拒绝镜像该 marker/{c=1} c&&/continue/{n++; c=0} END{print n+0}')
[ "$cont" = "3" ] && ok "E2 三道护栏都 continue（真的跳过，不是告警后照删）" || bad "E2 continue 数=$cont（期望 3）"

# 计数失败时必须退回"不删"而不是把空串当 0 放行
printf '%s' "$BODY" | grep -qF '_cnt_src=0' \
  && ok "F1 非法计数被归一（不把空串当数字比）" || bad "F1 缺计数归一"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]