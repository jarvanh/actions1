#!/bin/bash
# ===== 锁定: 拒写同步标记时必须作废该 marker 的「跳过依据」=====
#
# 为什么要有这个测试（2026-11-16 加，run 43774563232 日志实证）:
#   子目录 ..._HongKongDoll_HongKongDoll 玩偶姐姐 3 的真实时序:
#     23:36:39 「24小时内已成功同步（距今 22 小时），跳过」  ← 只按时间戳判跳过
#     23:36:40 「⚠️ 拒绝写入同步标记: 目标端文件数 2 < 源端 149（缺失 147 个）」
#     23:36:40 「  本次不写 marker，下次运行将重新同步」      ← 这句与代码行为相反
#   拒写分支只合并修复记录、**保留旧 last_success** ⇒ 下轮又命中跳过窗口
#   ⇒ 这棵子树按 24h 周期空转，147 个文件永远补不上。
#   指纹: 连续三轮日志里这些子树的数字逐字节相同
#     （2/149 · 0/297 · 23/297 · 52/422 · 272/422 · 19842/23818）。
#
# 锁定的契约:
#   C1 有 last_success 时: 作废后 marker **不含** last_success，且留痕可回溯
#   C2 作废必须**保留** fixed_files / fix_blacklist（还原索引 + filter 保护来源）
#   C3 作废后 check_sync_marker 不再返回 skip（改为放行做真同步）
#   C4 无 last_success 时不做任何写入（幂等，不产生噪音写）
#   C5 marker 不存在时安全返回，不写
#   C6 marker 非法 JSON 时拒绝写回（绝不抹掉旧记录）
#   C7 拒写分支确实调用了作废函数（调用点契约，防将来被删）
#
# 桩的写法定式（踩过的坑）: `rclone rcat` 在管道里跑 ⇒ 总是子 shell，
#   **变量赋值传不回父 shell**（首版本用 _RCAT_CALLS 计数，实测恒为 0 而实际写入成功）。
#   故桩把 marker 落到磁盘文件，断言也读文件 —— 这也更接近"远端真被改写"的事实。
#
# 用法: bash test_marker_invalidate_on_refusal.sh   （退出码 0=全过）
set -u

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../../.." && pwd)"
SOURCE_MARKER="$REPO_ROOT/.github/scripts/openlist/sync_marker.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MARKER_FILE="$WORK/marker.json"    # 桩的"远端 marker"
RCAT_N="$WORK/rcat_n"              # rcat 调用次数（跨子 shell 用文件计数）

SYNC_STATE_DIR="olstate"
SYNC_SKIP_SECONDS=86400

rclone() {
  case "$1" in
    cat)
      [ -f "$MARKER_FILE" ] || return 1
      cat "$MARKER_FILE"
      return 0
      ;;
    rcat)
      # 真实 rcat 的行为: 从 stdin 读内容覆盖远端目标；落盘以便断言
      local _n=0
      [ -f "$RCAT_N" ] && _n=$(cat "$RCAT_N")
      echo $((_n + 1)) > "$RCAT_N"
      cat > "$MARKER_FILE"
      return 0
      ;;
    mkdir) return 0 ;;
    *)     return 0 ;;
  esac
}

_force_sync_matches() { return 1; }

source "$SOURCE_MARKER"

MARKER_PATH="$(get_marker_path "taskX_sub" "openlist:wopan175/1")"

reset_state() { rm -f "$MARKER_FILE" "$RCAT_N"; }
rcat_calls()  { [ -f "$RCAT_N" ] && cat "$RCAT_N" || echo 0; }

# ────────────────────────────────────────────────────────────
# C1 + C2 · 有 last_success → 清掉它，但保留修复记录
# ────────────────────────────────────────────────────────────
reset_state
cat > "$MARKER_FILE" <<'JSON'
{
  "source_path": "onedrive:1/sub",
  "dest_path": "openlist:wopan175/1/sub",
  "last_success": "2026-11-15T01:34:00Z",
  "source_bytes": 123456,
  "source_count": 149,
  "top_dirs": ["a", "b"],
  "fixed_files": [{"original": "x/y.mp4", "alternative": "ab12cd34.mp4", "size_bytes": 999, "method": "m2"}],
  "fixed_count": 1,
  "fixed_bytes": 999,
  "fix_blacklist": {"x/y.mp4": ["copyto_original"]}
}
JSON

if _invalidate_marker_skip_basis "$MARKER_PATH" >/dev/null 2>&1; then
  ok "C1-执行: 有 last_success 时作废返回 0"
else
  bad "C1-执行: 作废函数返回非 0"
fi

if [ "$(rcat_calls)" -eq 1 ]; then
  ok "C1-写入: 恰好写回一次"
else
  bad "C1-写入: 写回次数=$(rcat_calls)（期望 1）"
fi

if jq -e 'has("last_success") | not' "$MARKER_FILE" >/dev/null 2>&1; then
  ok "C1-字段: marker 已不含 last_success"
else
  bad "C1-字段: marker 仍然含 last_success"
fi

if jq -e '(.skip_basis_invalidated_at // "") != ""' "$MARKER_FILE" >/dev/null 2>&1; then
  ok "C1-留痕: 写入 skip_basis_invalidated_at（可回溯谁在何时被作废）"
else
  bad "C1-留痕: 未写入 skip_basis_invalidated_at"
fi

if jq -e '(.fixed_files | length) == 1 and .fixed_files[0].alternative == "ab12cd34.mp4"' "$MARKER_FILE" >/dev/null 2>&1; then
  ok "C2: fixed_files 完整保留（一键还原的唯一索引）"
else
  bad "C2: fixed_files 被破坏"
fi

if jq -e '(.fix_blacklist["x/y.mp4"] | length) == 1' "$MARKER_FILE" >/dev/null 2>&1; then
  ok "C2: fix_blacklist 完整保留（跨轮方法记忆）"
else
  bad "C2: fix_blacklist 被破坏"
fi

if jq -e '.source_count == 149 and .fixed_count == 1 and (.top_dirs | length) == 2 and .source_bytes == 123456' "$MARKER_FILE" >/dev/null 2>&1; then
  ok "C2: 其余字段（source_count/source_bytes/fixed_count/top_dirs）原样保留"
else
  bad "C2: 其余字段被破坏"
fi

# ────────────────────────────────────────────────────────────
# C3 · 作废后 check_sync_marker 必须放行（对比: 作废前是 skip）
#   时间戳必须"刚刚"（窗口内），否则复现不了线上的 skip 分支
# ────────────────────────────────────────────────────────────
reset_state
RECENT="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"last_success":"%s","source_count":149,"source_bytes":1}\n' "$RECENT" > "$MARKER_FILE"

MARKER_ACTION=""
check_sync_marker "onedrive:1/sub" "openlist:wopan175/1/sub" "taskX_sub" >/dev/null 2>&1 || true
if [ "$MARKER_ACTION" = "skip" ]; then
  ok "C3-对照: 未作废时命中跳过窗口（复现线上那条 skip）"
else
  bad "C3-对照: 期望 skip，实际 ${MARKER_ACTION:-空}"
fi

_invalidate_marker_skip_basis "$MARKER_PATH" >/dev/null 2>&1 || true
MARKER_ACTION=""
check_sync_marker "onedrive:1/sub" "openlist:wopan175/1/sub" "taskX_sub" >/dev/null 2>&1 || true
if [ "$MARKER_ACTION" = "proceed" ]; then
  ok "C3-生效: 作废后不再跳过，改为 proceed（真同步）"
else
  bad "C3-生效: 作废后仍为 ${MARKER_ACTION:-空}（应 proceed）"
fi

# ────────────────────────────────────────────────────────────
# C4 · 无 last_success → 不写
# ────────────────────────────────────────────────────────────
reset_state
echo '{"source_count":149,"fixed_files":[]}' > "$MARKER_FILE"
_invalidate_marker_skip_basis "$MARKER_PATH" >/dev/null 2>&1
if [ "$(rcat_calls)" -eq 0 ]; then
  ok "C4: 无 last_success 时不产生写入（幂等）"
else
  bad "C4: 无 last_success 却写入了 $(rcat_calls) 次"
fi

# ────────────────────────────────────────────────────────────
# C5 · marker 不存在 → 安全返回 0，不写
# ────────────────────────────────────────────────────────────
reset_state
if _invalidate_marker_skip_basis "$MARKER_PATH" >/dev/null 2>&1; then
  ok "C5: marker 不存在时返回 0"
else
  bad "C5: marker 不存在时返回非 0"
fi
if [ "$(rcat_calls)" -eq 0 ]; then
  ok "C5: marker 不存在时不写"
else
  bad "C5: marker 不存在却写入了"
fi

# ────────────────────────────────────────────────────────────
# C6 · 非法 JSON → 拒绝写回（原内容保持不动）
# ────────────────────────────────────────────────────────────
reset_state
printf '{"last_success":"2026-11-15T01:34:00Z","fixed_files":[{"original":"keep.mp4"}]' > "$MARKER_FILE"
BEFORE="$(cat "$MARKER_FILE")"
_invalidate_marker_skip_basis "$MARKER_PATH" >/dev/null 2>&1
if [ "$(rcat_calls)" -eq 0 ] && [ "$(cat "$MARKER_FILE")" = "$BEFORE" ]; then
  ok "C6: 非法 JSON 不写回，原 marker 一字未动"
else
  bad "C6: 非法 JSON 竟被写回（rcat=$(rcat_calls)）"
fi

# ────────────────────────────────────────────────────────────
# C7 · 调用点契约: 拒写分支必须调用作废函数
# ────────────────────────────────────────────────────────────
REFUSE_LINE=$(grep -n '拒绝写入同步标记: 目标端文件数' "$SOURCE_MARKER" | head -1 | cut -d: -f1)
INVAL_LINE=$(grep -n '_invalidate_marker_skip_basis "\$marker_path"' "$SOURCE_MARKER" | head -1 | cut -d: -f1)
if [ -n "$REFUSE_LINE" ] && [ -n "$INVAL_LINE" ] && [ "$INVAL_LINE" -gt "$REFUSE_LINE" ]; then
  ok "C7: 拒写分支内（第 ${REFUSE_LINE} 行之后、第 ${INVAL_LINE} 行）确实调用了作废函数"
else
  bad "C7: 未在拒写分支找到作废调用（refuse=${REFUSE_LINE:-无} invalidate=${INVAL_LINE:-无}）"
fi

echo "----------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
