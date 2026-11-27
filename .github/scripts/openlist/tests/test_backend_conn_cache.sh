#!/bin/bash
# 后端级连通性失败缓存（轮内）行为测试
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }

if [ -z "${OL_DRIVER:-}" ]; then
  _here=$(cd "$(dirname "$0")" && pwd)
  OL_DRIVER="$_here/../openlist_driver.sh"
fi
[ -f "$OL_DRIVER" ] || { echo "NG openlist_driver.sh missing: $OL_DRIVER"; echo "PASS=0 FAIL=1"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
DRV="$WORK/driver.sh"
{
  echo "declare -A _BACKEND_CONN_FAIL_ROUND=()"
  echo "declare -A _BACKEND_CONN_FAIL_REASON=()"
  sed -n "/^_backend_root_of()/,/^}/p" "$OL_DRIVER"
  sed -n "/^_check_openlist_backend_connectivity()/,/^}/p" "$OL_DRIVER"
} > "$DRV"

# 桩: 前缀匹配失败（更贴近真实——整个后端不可用时其下所有路径都失败）
cat > "$WORK/stubs.sh" <<'EOS'
_pre_webdav_health_check() {
  local p="$1"
  for bad in $PROBE_FAIL_PREFIX; do
    case "$p" in "$bad"*) return 1;; esac
  done
  return 0
}
_openlist_api_health_check() { return 0; }
_backend_write_probe() { return 0; }
EOS

echo "=== 1: 后端根失败 -> 标记该挂载 ==="
(
  PROBE_FAIL_PREFIX="openlist:wopan175"
  . "$WORK/stubs.sh"; . "$DRV"
  _check_openlist_backend_connectivity "openlist:wopan175" "" >/dev/null 2>&1; rc=$?
  echo "rc=$rc cache=${_BACKEND_CONN_FAIL_ROUND[openlist:wopan175]:-0}"
) > "$WORK/c1" 2>&1
grep -q "rc=1 cache=1" "$WORK/c1" && ok "后端根失败被缓存" || bad "$(cat "$WORK/c1")"

echo "=== 2: 子目录失败但后端根健康 -> 不缓存（路径特异性） ==="
(
  PROBE_FAIL_PREFIX="openlist:wopan176Crypt/3/teacher-of-magic"
  . "$WORK/stubs.sh"; . "$DRV"
  _check_openlist_backend_connectivity "openlist:wopan176Crypt/3/teacher-of-magic" "" >/dev/null 2>&1; rc=$?
  echo "rc=$rc cache=${_BACKEND_CONN_FAIL_ROUND[openlist:wopan176Crypt]:-0}"
) > "$WORK/c2" 2>&1
grep -q "rc=1 cache=0" "$WORK/c2" && ok "路径特异性不误杀整挂载" || bad "$(cat "$WORK/c2")"

echo "=== 3: 缓存命中后不再探测 ==="
(
  PROBE_FAIL_PREFIX="openlist:wopan175"
  . "$WORK/stubs.sh"; . "$DRV"
  _check_openlist_backend_connectivity "openlist:wopan175/1/a" "" >/dev/null 2>&1
  _pre_webdav_health_check() { echo PROBED >> "$WORK/probe.log"; return 1; }
  _check_openlist_backend_connectivity "openlist:wopan175/2/b" "" >/dev/null 2>&1
) > /dev/null 2>&1
n=$(grep -c PROBED "$WORK/probe.log" 2>/dev/null || echo 0)
[ "$n" = "0" ] && ok "短路生效（0 次探测）" || bad "仍探测 $n 次"

echo "=== 4: 不同挂载互不影响 ==="
(
  PROBE_FAIL_PREFIX="openlist:wopan175"
  . "$WORK/stubs.sh"; . "$DRV"
  _check_openlist_backend_connectivity "openlist:wopan175" "" >/dev/null 2>&1
  _check_openlist_backend_connectivity "openlist:baidupanCrypt/0" "" >/dev/null 2>&1; rc=$?
  echo "rc=$rc b175=${_BACKEND_CONN_FAIL_ROUND[openlist:wopan175]:-0} bdu=${_BACKEND_CONN_FAIL_ROUND[openlist:baidupanCrypt]:-0}"
) > "$WORK/c4" 2>&1
grep -q "rc=0 b175=1 bdu=0" "$WORK/c4" && ok "wopan175 失效不影响 baidupanCrypt" || bad "$(cat "$WORK/c4")"

echo "=== 5: 未失效时正常放行 ==="
(
  PROBE_FAIL_PREFIX=""
  . "$WORK/stubs.sh"; . "$DRV"
  _check_openlist_backend_connectivity "openlist:wopan175/5/x" "" >/dev/null 2>&1; rc=$?
  echo "rc=$rc cache=${_BACKEND_CONN_FAIL_ROUND[openlist:wopan175]:-0}"
) > "$WORK/c5" 2>&1
grep -q "rc=0 cache=0" "$WORK/c5" && ok "健康后端正常放行" || bad "$(cat "$WORK/c5")"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
