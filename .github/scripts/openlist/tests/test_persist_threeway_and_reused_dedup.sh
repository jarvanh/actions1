#!/bin/bash
# 持久化复核三分口径 + 沿用剔除入账（2026-11-25 加）
#
# 生产实证（actions1 run 45455001510，21:07–21:12）:
#   容器重启后后端驱动未重建索引，`rclone size <file>` 对真实已落盘文件全部失败
#   （rc≠0、无输出）⇒ 旧代码把空输出当 0 字节 ⇒ 445 个文件被判「未持久化」并被
#   _blacklist_add 拉黑「方法2·短名直传」⇒ 同批文件此后「方法耗尽」永久失败。
#   同轮收尾还打出「成功 870（沿用 968）」——沿用比成功还大，逻辑不可能。
#
# 本测锁住两条不变量:
#   A. 列举失败（U）⇒ 计入 PERSIST_UNKNOWN，既不进失败数组、也不拉黑
#   B. 列举成功但名字不在（M）⇒ 才是失败并拉黑
#   C. 沿用条目在入账前按 original 剔除，ROUND_FIXED_OK 只计真新落盘
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/file_fix_pipeline.sh" 2>/dev/null

WORK=/tmp/persist_threeway_test
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'cd / && rm -rf "$WORK"' EXIT
cd "$WORK"

# --- mocks ---
BLACKLISTED=()
_blacklist_add() { BLACKLISTED+=("$1"); }
_fix_method_short() { printf '%s' "${1:-}"; }
_short_path() { printf '%s' "$1"; }
_norm_rel_path() { printf '%s' "$1"; }
tee() { cat; }
# RC_LISTING_FAIL=1 ⇒ lsf 恒失败（模拟驱动未就绪）；PLIST=1 ⇒ 只有名单里的名字存在
RC_LISTING_FAIL=0
EXISTING=""
rclone() {
  case "$1" in
    lsf)
      if [ "$RC_LISTING_FAIL" = "1" ]; then
        echo "ERROR : error listing: 500 internal server error" >&2
        return 3
      fi
      local _bn=""
      while [ $# -gt 0 ]; do case "$1" in --format|--separator) shift 2;; *) _bn="$1"; shift;; esac; done
      local _n
      for _n in $EXISTING; do printf '%s;%s\n' "$_n" 1234; done
      return 0 ;;
    *) return 0 ;;
  esac
}

LIST="$WORK/list.txt"
printf 'a.mp4\0371234\037orig-a.mp4\037rclone copyto（短名）\037copyto_shorthash\n' > "$LIST"
printf 'b.mp4\0371234\037orig-b.mp4\037rclone copyto（短名）\037copyto_shorthash\n' >> "$LIST"

# ===== A. 列举失败 ⇒ 未定，不拉黑 =====  
RC_LISTING_FAIL=1; BLACKLISTED=()
OPENLIST_PERSIST_PROBE_TRIES=1 OPENLIST_PERSIST_PROBE_RETRY_SLEEP=0 \
  _persist_verify_entries "openlist:wopan176Crypt/9" "$LIST" 0 "$WORK/log.txt" >/dev/null 2>&1
[ "${PERSIST_UNKNOWN:-0}" = "2" ] && ok "A1 列举失败 2 条 → 全部计未定" || bad "A1 UNKNOWN=${PERSIST_UNKNOWN:-空}（期望 2）"
[ "${PERSIST_FAIL:-0}" = "0" ] && ok "A2 未定不计失败" || bad "A2 FAIL=${PERSIST_FAIL:-空}（期望 0）"
[ "${#PERSIST_FAILED_ORIGS[@]}" = "0" ] && ok "A3 未定不进失败数组（不会触发换方法重试）" || bad "A3 失败数组=${#PERSIST_FAILED_ORIGS[@]}"
[ "${#BLACKLISTED[@]}" = "0" ] && ok "A4 未定不拉黑方法" || bad "A4 误拉黑 ${#BLACKLISTED[@]} 条"
[ "${PERSIST_OK:-0}" = "0" ] && ok "A5 未定也不计入通过（没有证据）" || bad "A5 OK=${PERSIST_OK:-空}"

# ===== B. 列举成功但名字不在 ⇒ 确定失败 + 拉黑 =====
RC_LISTING_FAIL=0; EXISTING=""; BLACKLISTED=()
OPENLIST_PERSIST_PROBE_TRIES=1 OPENLIST_PERSIST_PROBE_RETRY_SLEEP=0 \
  _persist_verify_entries "openlist:wopan176Crypt/9" "$LIST" 0 "$WORK/log.txt" >/dev/null 2>&1
[ "${PERSIST_FAIL:-0}" = "2" ] && ok "B1 列举正常但文件不在 → 确定失败 2 条" || bad "B1 FAIL=${PERSIST_FAIL:-空}（期望 2）"
[ "${PERSIST_UNKNOWN:-0}" = "0" ] && ok "B2 未定应为 0（这不是观测失败）" || bad "B2 UNKNOWN=${PERSIST_UNKNOWN:-空}"
[ "${#BLACKLISTED[@]}" = "2" ] && ok "B3 确定失败才拉黑（2 条）" || bad "B3 拉黑 ${#BLACKLISTED[@]} 条（期望 2）"

# ===== C. 大小一致 ⇒ 通过 =====
RC_LISTING_FAIL=0; EXISTING="a.mp4 b.mp4"; BLACKLISTED=()
OPENLIST_PERSIST_PROBE_TRIES=1 OPENLIST_PERSIST_PROBE_RETRY_SLEEP=0 \
  _persist_verify_entries "openlist:wopan176Crypt/9" "$LIST" 0 "$WORK/log.txt" >/dev/null 2>&1
[ "${PERSIST_OK:-0}" = "2" ] && ok "C1 名字在且大小一致 → 通过 2 条" || bad "C1 OK=${PERSIST_OK:-空}（期望 2）"

# ===== B4. 全灭可疑: 6 条全部查不到 → 判观测失真，整批顺延、不拉黑 ====="
#   为什么需要这条: 驱动重建索引期间 rc=0 的空列表会让每条都变成「M 确定不存在」，
#   三分口径挡不住（那是"列举报错"，这是"列举成功但为空"）。刚上传成功的文件整批
#   消失不是真实事件 ⇒ 只能顺延复核，不能批量拉黑。
LIST6="$WORK/list6.txt"; : > "$LIST6"
for _n in 1 2 3 4 5 6; do printf 'f%s.mp4\0371234\037o%s.mp4\037rclone copyto（短名）\037copyto_shorthash\n' "$_n" "$_n" >> "$LIST6"; done
RC_LISTING_FAIL=0; EXISTING=""; BLACKLISTED=()
OPENLIST_PERSIST_PROBE_TRIES=1 OPENLIST_PERSIST_PROBE_RETRY_SLEEP=0 \
  _persist_verify_entries "openlist:wopan176Crypt/9" "$LIST6" 0 "$WORK/log.txt" >/dev/null 2>&1
[ "${PERSIST_FAIL:-0}" = "0" ] && ok "B4 全灭 6 条 → 不计失败" || bad "B4 FAIL=${PERSIST_FAIL:-空}（期望 0）"
[ "${PERSIST_UNKNOWN:-0}" = "6" ] && ok "B5 全灭 6 条 → 全部转未定" || bad "B5 UNKNOWN=${PERSIST_UNKNOWN:-空}（期望 6）"
[ "${#BLACKLISTED[@]}" = "0" ] && ok "B6 全灭不拉黑任何方法" || bad "B6 误拉黑 ${#BLACKLISTED[@]} 条"

# ===== D. 沿用条目不得计入 ROUND_FIXED_OK =====
declare -A FIXED_THIS_RUN=(); declare -A FIX_METHOD_BLACKLIST=()
GLOBAL_FIXED_FILES_JSON="[]"; GLOBAL_FIX_BLACKLIST_JSON="{}"
LOG_FILENAME="$WORK/task.log"
rm -f /tmp/ol_round_stats.env
: > /tmp/ol_fix_events.log
printf 'REUSED|orig-a.mp4|x\n' >> /tmp/ol_fix_events.log
LAST_SYNC_FIXED_FILES_JSON='[{"original":"orig-a.mp4"},{"original":"orig-b.mp4"}]'
SYNC_MISSING_TOTAL_RUN=2
_sync_accumulate_fixed_results >/dev/null 2>&1
_okv=$(sed -n 's/^ROUND_FIXED_OK=//p' /tmp/ol_round_stats.env 2>/dev/null)
[ "${_okv:-}" = "1" ] && ok "D1 沿用条目按 original 剔除（2 条中 1 条沿用 → 成功 1）" || bad "D1 ROUND_FIXED_OK=${_okv:-空}（期望 1）"
_rv=$(sed -n 's/^ROUND_REUSED=//p' /tmp/ol_round_stats.env 2>/dev/null)
[ "${_rv:-}" = "1" ] && ok "D2 沿用计数取事件日志去重口径" || bad "D2 ROUND_REUSED=${_rv:-空}（期望 1）"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]