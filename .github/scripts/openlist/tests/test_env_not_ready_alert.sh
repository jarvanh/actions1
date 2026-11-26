#!/bin/bash
# 环境未就绪告警 step 的行为测试（2026-11-26 加）
#
# 背景: run 45651997160 / 45727347379 的 apt 404 使「加载函数库/同步」全 skipped、
#   整轮零产出，而「自续触发」按设计不接力 ⇒ 停摆 8 小时无人知晓。
#   静默失败是最贵的一类故障: 「没在跑」和「跑挂了」在通知上没区别。
#
# 本测锁住四条不变量:
#   A. 环境就绪（OL_ENV_READY=1）⇒ 不发通知（与正常收尾通知互斥，不重复）
#   B. 环境未就绪 ⇒ 发 alert 档通知（tier 必须是 alert，不能走普通档）
#   C. 告警凭据缺失 ⇒ 跳过并告警，不失败（告警是附加能力，不能反过来搞挂 job）
#   D. 通知内容含「零产出 / 不自续」这两个关键信息（否则读者不知道严重性）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WF="$_REPO_ROOT/.github/workflows/openlist.yml"

# 抽取 step 脚本（保证测的是 workflow 里的真代码，不是副本）
S=$(python3 - "$WF" <<'PY'
import yaml,sys,io
wf=yaml.safe_load(io.open(sys.argv[1],encoding='utf-8'))
for s in wf['jobs']['build']['steps']:
    if s.get('name')=='Notify: 环境未就绪告警':
        print(s['run']); break
PY
)
[ -n "$S" ] && ok "A0 能抽取到告警 step 脚本" || { bad "A0 抽不到脚本"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# mock: tg 助手 + send_telegram_message 记录调用
run_step() {  # $1=OL_ENV_READY $2=有凭据(1/0)
  local env_ready="$1" has_cred="$2"
  ( set +e
    OL_ENV_READY="$env_ready"
    GITHUB_WORKSPACE=/tmp/guard_ws_$$
    mkdir -p "$GITHUB_WORKSPACE/.github/scripts/telegram"
    : > "$GITHUB_WORKSPACE/.github/scripts/telegram/tg_notify.sh"
    if [ "$has_cred" = "1" ]; then
      TELEGRAM_BOT_TOKEN_ALERT=tok; TELEGRAM_CHAT_ID_ALERT=chat
    else
      TELEGRAM_BOT_TOKEN_ALERT=; TELEGRAM_CHAT_ID_ALERT=
    fi
    SENT_FILE=/tmp/guard_sent_$$; : > "$SENT_FILE"
    # 覆盖 source 后的助手（真源文件为空，函数由这里提供）
    tg_add_title() { :; }; tg_add_kv() { :; }; tg_add_note() { :; }; tg_add_footer() { :; }
    send_telegram_message() { printf 'TIER=%s MSG=%s\n' "${3:-}" "$1" >> "$SENT_FILE"; }
    eval "$S" >/dev/null 2>&1
    cat "$SENT_FILE" 2>/dev/null
    rm -rf "$GITHUB_WORKSPACE" "$SENT_FILE"
  )
}

# A: 环境就绪 → 不发送
out=$(run_step 1 1)
if [ -z "$out" ]; then ok "A 环境就绪 → 不发通知（与正常收尾互斥）"; else bad "A 环境就绪却发了通知"; fi

# B: 环境未就绪 → 发 alert
out=$(run_step 0 1)
echo "$out" | grep -q 'TIER=alert' && ok "B 环境未就绪 → 发送且档位为 alert" || bad "B 未发或档位不对: $out"

# C: 凭据缺失 → 跳过且不失败
out=$(run_step 0 0)
if [ -z "$out" ]; then ok "C 凭据缺失 → 跳过发送（不搞挂 job）"; else bad "C 凭据缺失仍尝试发送"; fi

# D: 内容含关键信息
grep -q '零产出' <<< "$S" && ok "D1 文案含「零产出」" || bad "D1 文案未说明零产出"
grep -q '不自续' <<< "$S" && ok "D2 文案含「不自续」" || bad "D2 文案未说明接力已停"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]