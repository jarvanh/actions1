#!/bin/bash
# 后端级连通性失败缓存（轮内 + TTL）行为测试
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  OK $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  NG $1"; }

if [ -z "${OL_DRIVER:-}" ]; then
  _here=$(cd "$(dirname "$0")" && pwd)
  OL_DRIVER="$_here/../openlist_driver.sh"
fi
[ -f "$OL_DRIVER" ] || { echo "NG driver missing: $OL_DRIVER"; echo "PASS=0 FAIL=1"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
DRV="$WORK/driver.sh"
{
  echo "declare -A _BACKEND_CONN_FAIL_ROUND=()"
  echo "declare -A _BACKEND_CONN_FAIL_REASON=()"
  echo "declare -A _BACKEND_CONN_FAIL_TS=()"
  sed -n "/^_backend_root_of()/,/^}/p" "$OL_DRIVER"
  sed -n "/^_check_openlist_backend_connectivity()/,/^}/p" "$OL_DRIVER"
} > "$DRV"

cat > "$WORK/stubs.sh" <<'EOS'
_pre_webdav_health_check() {
  local p="$1"
  for badp in ${PROBE_FAIL_PREFIX:-}; do
    case "$p" in "$badp"*) return 1;; esac
  done
  return 0
}
_openlist_api_health_check() { return 0; }
_backend_write_probe() { return 0; }
EOS

# 运行一次探测，输出 "rc|cache"
probe() {
  local path="$1"
  ( . "$WORK/stubs.sh"; . "$DRV"; _check_openlist_backend_connectivity "$path" "" >/dev/null 2>&1; echo "rc=$?" ) 
}

echo "=== 1: 后端根失败 -> 标记该挂载 ==="
out=$(PROBE_FAIL_PREFIX="openlist:wopan175" probe "openlist:wopan175")
[ "$out" = "rc=1" ] && ok "后端根失败返回 1" || bad "got $out"

echo "=== 2: 子目录失败但后端根健康 -> 不缓存（路径特异性） ==="
out=$(
  PROBE_FAIL_PREFIX="openlist:wopan176Crypt/3/teacher-of-magic"
  . "$WORK/stubs.sh"; . "$DRV"
  _check_openlist_backend_connectivity "openlist:wopan176Crypt/3/teacher-of-magic" "" >/dev/null 2>&1
  echo "rc=$? cache=${_BACKEND_CONN_FAIL_ROUND["openlist:wopan176Crypt"]:-0}"
)
[ "$out" = "rc=1 cache=0" ] && ok "路径特异性不误杀整挂载" || bad "got $out"

echo "=== 3: 缓存命中后不再探测 ==="
(
  PROBE_FAIL_PREFIX="openlist:wopan175"
  . "$WORK/stubs.sh"; . "$DRV"
  _check_openlist_backend_connectivity "openlist:wopan175/1/a" "" >/dev/null 2>&1
  _pre_webdav_health_check() { echo PROBED >> "$WORK/probe.log"; return 1; }
  _check_openlist_backend_connectivity "openlist:wopan175/2/b" "" >/dev/null 2>&1
) >/dev/null 2>&1
n=$(grep -c PROBED "$WORK/probe.log" 2>/dev/null || true)
[ "${n:-0}" = "0" ] && ok "短路生效（0 次探测）" || bad "仍探测 ${n:-?} 次"

echo "=== 4: 不同挂载互不影响 ==="
out=$(
  PROBE_FAIL_PREFIX="openlist:wopan175"
  . "$WORK/stubs.sh"; . "$DRV"
  _check_openlist_backend_connectivity "openlist:wopan175" "" >/dev/null 2>&1
  _check_openlist_backend_connectivity "openlist:baidupanCrypt/0" "" >/dev/null 2>&1
  echo "rc=$? b175=${_BACKEND_CONN_FAIL_ROUND["openlist:wopan175"]:-0} bdu=${_BACKEND_CONN_FAIL_ROUND["openlist:baidupanCrypt"]:-0}"
)
[ "$out" = "rc=0 b175=1 bdu=0" ] && ok "wopan175 失效不影响 baidupanCrypt" || bad "got $out"

echo "=== 5: 健康后端正常放行 ==="
out=$(PROBE_FAIL_PREFIX="" probe "openlist:wopan175/5/x")
[ "$out" = "rc=0" ] && ok "健康后端正常放行" || bad "got $out"

echo "=== 6: TTL 过期后重探（后端恢复能被发现） ==="
out=$(
  PROBE_FAIL_PREFIX=""
  . "$WORK/stubs.sh"; . "$DRV"
  _BACKEND_CONN_FAIL_ROUND["openlist:wopan175"]=1
  _BACKEND_CONN_FAIL_TS["openlist:wopan175"]=$(( $(date +%s) - 99999 ))
  OPENLIST_CONN_FAIL_TTL=1800
  _check_openlist_backend_connectivity "openlist:wopan175/1/x" "" >/dev/null 2>&1
  echo "rc=$? cache=${_BACKEND_CONN_FAIL_ROUND["openlist:wopan175"]:-0}"
)
[ "$out" = "rc=0 cache=0" ] && ok "TTL 过期后重探并放行" || bad "got $out"

echo "=== 7: TTL 内仍短路 ==="
out=$(
  PROBE_FAIL_PREFIX=""
  . "$WORK/stubs.sh"; . "$DRV"
  _BACKEND_CONN_FAIL_ROUND["openlist:wopan175"]=1
  _BACKEND_CONN_FAIL_TS["openlist:wopan175"]=$(date +%s)
  OPENLIST_CONN_FAIL_TTL=1800
  _check_openlist_backend_connectivity "openlist:wopan175/1/x" "" >/dev/null 2>&1
  echo "rc=$?"
)
[ "$out" = "rc=1" ] && ok "TTL 内正常短路" || bad "got $out"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
