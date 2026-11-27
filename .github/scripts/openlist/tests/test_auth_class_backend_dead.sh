#!/bin/bash
# auth 类预检失败应作为强证据跨轮熔断（写 backend_dead.json）
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }

if [ -z "${OL_DIR:-}" ]; then _here=$(cd "$(dirname "$0")" && pwd); OL_DIR="$_here/.."; fi

echo "=== 1: driver 导出 _PRE_WEBDAV_FAIL_KIND ==="
grep -q '_PRE_WEBDAV_FAIL_KIND="$kind"' "$OL_DIR/openlist_driver.sh" && ok "导出失败类别" || bad "未导出"

echo "=== 2: sync_engine 对 auth 类置 STRONG ==="
seg=$(sed -n '/elif \[ "${_PRE_WEBDAV_FAIL_KIND:-}" = "auth" \]/,/^    fi/p' "$OL_DIR/sync_engine.sh")
echo "$seg" | grep -q "SYNC_BACKEND_DEAD_STRONG=1" && ok "auth 类置 STRONG=1" || bad "auth 类未置 STRONG"
echo "$seg" | grep -q "SYNC_BACKEND_DEAD=1" && ok "auth 类置 DEAD=1" || bad "auth 类未置 DEAD"

echo "=== 3: 只在 auth 分支，不含 backend/unknown ==="
if echo "$seg" | grep -qE '= "backend"|= "unknown"'; then bad "误把 backend/unknown 纳入强证据"; else ok "backend/unknown 仍走弱证据"; fi

echo "=== 4: _backend_dead_mark 弱证据不持久化（原设计保留） ==="
grep -q 'SYNC_BACKEND_DEAD_STRONG:-0}" != "1"' "$OL_DIR/task_engine.sh" && ok "弱证据不写 backend_dead.json" || bad "强证据闸缺失"

echo "=== 5: 语义 —— auth 命中、backend/unknown 不命中 ==="
W=$(mktemp)
(
  declare -A _BACKEND_WRITE_PROBE_CACHE=()   # 关联数组: 否则 set -u 下索引 none 会被当变量求值
  for kind in auth backend unknown; do
    SYNC_BACKEND_DEAD=0; SYNC_BACKEND_DEAD_STRONG=0
    _PRE_WEBDAV_FAIL_KIND="$kind"
    _K="no-such-key"
    if [ "${_BACKEND_WRITE_PROBE_CACHE[$_K]:-}" = "0" ]; then
      SYNC_BACKEND_DEAD=1; SYNC_BACKEND_DEAD_STRONG=1
    elif [ "${_PRE_WEBDAV_FAIL_KIND:-}" = "auth" ]; then
      SYNC_BACKEND_DEAD=1; SYNC_BACKEND_DEAD_STRONG=1
    fi
    echo "$kind: dead=$SYNC_BACKEND_DEAD strong=$SYNC_BACKEND_DEAD_STRONG"
  done
) > "$W" 2>&1
grep -q "auth: dead=1 strong=1" "$W" && ok "auth → 强证据" || bad "auth 未命中: $(head -2 "$W")"
grep -q "backend: dead=0 strong=0" "$W" && ok "backend → 弱（不持久化）" || bad "backend 误命中"
grep -q "unknown: dead=0 strong=0" "$W" && ok "unknown → 弱" || bad "unknown 误命中"
rm -f "$W"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
