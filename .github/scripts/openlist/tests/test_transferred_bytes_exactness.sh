#!/usr/bin/env bash
# 锁定: 传输量口径判定（精确 vs 进度上界）
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$R/.github/scripts/openlist/utils.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

printf 'Transferred:   	  1.5 GiB / 3 GiB, 50%%, 10 MiB/s, ETA 5m\n' > "$W/e.log"
printf '1.234 GiB / 5.678 GiB, 22%%, 10 MiB/s, ETA 5m\n' > "$W/p.log"
: > "$W/z.log"

transferred_bytes_is_exact "$W/e.log" && ok "T1 有 Transferred: 行 → 判为精确" || bad "T1"
transferred_bytes_is_exact "$W/p.log" && bad "T2 只有进度行 → 竟判为精确" || ok "T2 只有进度行 → 判为上界（本函数存在的理由）"
transferred_bytes_is_exact "$W/z.log" && bad "T3 空日志 → 竟判为精确" || ok "T3 空日志 → 非精确"

[ "$(get_transferred_bytes_from_log "$W/e.log")" = "1610612736" ] && ok "T4 精确口径取 Transferred 值（1.5 GiB）" || bad "T4: $(get_transferred_bytes_from_log "$W/e.log")"
p=$(get_transferred_bytes_from_log "$W/p.log"); [ "$p" -gt 0 ] 2>/dev/null && ok "T5 退化路径仍能取到进度值（$p）" || bad "T5"

# T6: 调用点契约（拒写分支/通知层必须按精确性打口径说明）
grep -q 'transferred_bytes_is_exact "$log_filename"' "$R/.github/scripts/openlist/sync_notify.sh" \
  && ok "T6 sync_notify 调用点已接口径判定" || bad "T6"
grep -q '是\*\*上界\*\*，含失败/回滚字节' "$R/.github/scripts/openlist/sync_notify.sh" \
  && ok "T7 说明文案写明上界语义" || bad "T7"

echo "----------"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
