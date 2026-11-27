#!/bin/bash
# 陈旧 gateway state lock 自愈的静态回归（2026-11-27）。
# 只断言关键安全条件仍在：bash -n 由 tests.yml 全库静态检查覆盖，这里补语义锚点。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SRC="$ROOT/.github/scripts/openclaw/run-openclaw.sh"
fail=0
chk() {
  if grep -Fq "$1" "$SRC"; then
    echo "ok - $2"
  else
    echo "not ok - $2"
    fail=1
  fi
}

chk 'heal_stale_gateway_lock()' "存在锁自愈函数"
chk 'openclaw_port_listening || openclaw_health_http_ok' "活网关在听时不动锁"
chk 'last renewed [0-9]+ s ago' "解析 holder 心跳年龄"
chk '[ "$max_age" -lt 300 ]' "心跳不足 300s 不回收"
chk 'openclaw gateway recover-lock --json' "先检查取本轮指纹"
chk 'openclaw gateway recover-lock --confirm "$confirm_fp"' "用本轮指纹显式恢复"
chk 'systemctl --user restart openclaw-gateway.service' "恢复后重启以立即重走准入"
chk 'heal_stale_gateway_lock "$label"' "接入健康等待循环"

bash -n "$SRC"
echo "ok - bash -n $SRC"
exit "$fail"