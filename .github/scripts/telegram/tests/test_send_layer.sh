#!/usr/bin/env bash
# 发送层回归测试（2026-11-26 审查后补）
#
# 为什么要独立一套：2026-11-26 在 tg_notify.sh 里实锤了三个**静默**故障 ——
#   ① escape_html 用 echo，值恰好是 -n/-e/-E 时字段变空；
#   ② 429 正则不容忍 `"retry_after": 2` 的空格 → 一次都不重试、通知直接丢；
#   ③ send_tg_chunked 的分片靠进程替换，python3 缺失时零分片仍 rc=0。
# 这三类故障都不会让调用方看到非零退出码，只有 stub 探针能稳定复现，故固化为回归测试。
#
# 用法: bash .github/scripts/telegram/tests/test_send_layer.sh
# 不依赖真实网络 / 凭据：curl、python3 都在临时 PATH 里打桩。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SEND_LAYER="$REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
[ -r "$SEND_LAYER" ] || { echo "❌ 找不到发送层: $SEND_LAYER"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tg-send-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '✅ %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '❌ %s\n' "$*"; }

# ---------- stub 基础设施 ----------
mkdir -p "$WORK/bin" "$WORK/nopy"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$TG_TEST_CALLS"
code="${TG_TEST_CODE:-200}"
body="${TG_TEST_BODY:-{\"ok\":true}}"
printf '%s\n%s' "$body" "$code"
STUB
chmod +x "$WORK/bin/curl"
# 强制让 python3 失败：模拟精简 runner / PATH 损坏
printf '#!/usr/bin/env bash\nexit 127\n' > "$WORK/nopy/python3"
chmod +x "$WORK/nopy/python3"
export TELEGRAM_BOT_TOKEN=stub TELEGRAM_CHAT_ID=1
export PATH="$WORK/bin:$PATH"

run_stub() { # <测试名> <额外 PATH 前缀> <待执行 shell 代码>
  : > "$WORK/calls.log"
  TG_TEST_CALLS="$WORK/calls.log" PATH="$2:$PATH" bash -c "$3" >"$WORK/out.log" 2>"$WORK/err.log"
  RC=$?
  CALLS=$(wc -l < "$WORK/calls.log" | tr -d ' ')
  OUT=$(cat "$WORK/out.log")
  ERR=$(cat "$WORK/err.log")
}

# ---------- T1 escape_html 吞值 ----------
run_stub t1 "$WORK/bin" "source '$SEND_LAYER'; for v in -n -e -E -ne normal; do printf '[%s]\n' \"\$(escape_html \"\$v\")\"; done"
NORMALIZED=$(printf '%s' "$OUT" | tr '\n' '|')
# 命令替换会剥掉末尾换行，所以归一化结果没有尾部 '|'
[ "$RC" -eq 0 ] && [ "$NORMALIZED" = '[-n]|[-e]|[-E]|[-ne]|[normal]' ] \
  && ok 'T1 escape_html 保留 -n/-e/-E/-ne 原值' \
  || bad "T1 escape_html 吞值: RC=$RC OUT=[$NORMALIZED]"

# ---------- T2 429 带空格 JSON 必须重试 5 次 ----------
export TG_TEST_CODE=429 TG_TEST_BODY='{"ok":false,"error_code":429,"parameters":{"retry_after": 0}}'
run_stub t2 "$WORK/bin" "source '$SEND_LAYER'; TG_CHUNK_DELAY=0 send_tg 'hello'"
[ "$CALLS" -eq 5 ] \
  && ok 'T2 429 带空格 retry_after 重试 5 次' \
  || bad "T2 429 重试次数: CALLS=$CALLS RC=$RC ERR=[$ERR]"
unset TG_TEST_CODE TG_TEST_BODY

# ---------- T3 分片缺 python3 必须报错而非静默成功 ----------
run_stub t3 "$WORK/nopy" "source '$SEND_LAYER'; send_tg_chunked '\$(printf x%.0s {1..5000})'"
[ "$RC" -ne 0 ] && [ "$CALLS" -eq 0 ] && [[ "$ERR" == *'python3 不可用'* ]] \
  && ok 'T3 缺 python3 时分片失败并留痕' \
  || bad "T3 分片静默失败: RC=$RC CALLS=$CALLS ERR=[$ERR]"

# ---------- T4 正常分片仍能发出 ----------
LONG_TEXT=$(python3 -c "print('x'*9000)")
export TG_TEST_LONG_TEXT="$LONG_TEXT"
run_stub t4 "$WORK/bin" "source '$SEND_LAYER'; TG_CHUNK_DELAY=0 send_tg_chunked \"\$TG_TEST_LONG_TEXT\""
[ "$RC" -eq 0 ] && [ "$CALLS" -ge 3 ] \
  && ok "T4 正常分片发送 $CALLS 片" \
  || bad "T4 正常分片失败: RC=$RC CALLS=$CALLS ERR=[$ERR]"

# ---------- T5 HTML 400 不重发 ----------
export TG_TEST_CODE=400 TG_TEST_BODY='{"ok":false,"description":\"can\u0027t parse entities\"}'
run_stub t5 "$WORK/bin" "source '$SEND_LAYER'; send_tg 'hello'"
[ "$CALLS" -eq 1 ] && [ "$RC" -ne 0 ] \
  && ok 'T5 HTML 解析失败不重发' \
  || bad "T5 400 重试了: CALLS=$CALLS RC=$RC"
unset TG_TEST_CODE TG_TEST_BODY

# ---------- T6 收尾区无 URL 仍输出时长 ----------
run_stub t6 "$WORK/bin" "source '$SEND_LAYER'; unset TG_RUN_URL; msg='body'; tg_add_footer msg; printf '%s' \"\$msg\""
[[ "$OUT" == *'⏱ 已运行'* ]] && [[ "$OUT" != *'运行日志'* ]] \
  && ok 'T6 无 TG_RUN_URL 时仍显示时长、不显示链接' \
  || bad "T6 收尾区降级异常: OUT=[$OUT]"

printf '\n=== 结果: PASS=%s FAIL=%s ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1