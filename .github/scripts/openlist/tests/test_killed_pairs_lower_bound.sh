#!/bin/bash
# ===== 锁定: 「本轮传输 X」是下界，且日志必须把这一点说出来 =====
#
# 为什么要有这个测试（2026-11-16 加，run 43849396256 实证）:
#   并行调度里被 `kill -9` 强行收摊的同步对**来不及写 .done**，它的
#   `transferred=` 永远拿不到 ⇒ total_transferred 里根本没有这部分字节。
#   该轮 16 对里 10 对是被强杀的，收尾只报 6 对的 105.878 GiB ——
#   不做说明就会把"下界"当"全量"：据此算提速幅度、算工期都会偏。
#   （我此前就按这个数做过口径判断，故加一行显式说明 + 本测试锁住。）
#
# 锁定的契约:
#   K1 超份额强杀分支必须自增强杀计数 _killed_n
#   K2 _killed_n 必须与 _trunc_n 同作用域声明（否则 reap 内部改了看不见）
#   K3 收尾必须在 _killed_n > 0 时打印口径说明
#   K4 说明里必须出现"下界"字样（语义不能被改成"精确值"）
#   K5 强杀日志本身要标明"已传字节不计入"
#
# 用法: bash test_killed_pairs_lower_bound.sh   （退出码 0=全过）
set -u

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../../.." && pwd)"
SRC="$REPO_ROOT/.github/scripts/openlist/task_engine.sh"

# ── K1 · 强杀分支自增计数 ──
KILL_BLOCK=$(grep -n '已超份额 .*宽限' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$KILL_BLOCK" ]; then
  # 取强杀判据前后 12 行作为该分支的窗口
  FROM=$((KILL_BLOCK - 12)); [ "$FROM" -lt 1 ] && FROM=1
  if sed -n "${FROM},${KILL_BLOCK}p" "$SRC" | grep -q '_killed_n=\$((_killed_n + 1))'; then
    ok "K1: 超份额强杀分支自增 _killed_n"
  else
    bad "K1: 强杀分支找不到 _killed_n 自增"
  fi
else
  bad "K1: 找不到强杀日志行（结构变了，请同步更新本测试）"
fi

# ── K2 · 与 _trunc_n 同作用域声明 ──
if grep -qE 'local .*_trunc_n=0 .*_killed_n=0|local .*_killed_n=0 .*_trunc_n=0' "$SRC"; then
  ok "K2: _killed_n 与 _trunc_n 同处 local 声明（reap 内自增可见）"
else
  bad "K2: _killed_n 未与 _trunc_n 同作用域声明"
fi

# ── K3 · 收尾按条件打印口径说明 ──
if grep -q '_killed_n:-0}" -gt 0' "$SRC"; then
  ok "K3: 收尾以 _killed_n>0 为条件打印说明"
else
  bad "K3: 收尾缺少 _killed_n 条件判据"
fi

# ── K4 · 说明必须写明"下界" ──
if grep -q '该数是\*\*下界\*\*' "$SRC"; then
  ok "K4: 说明明确写出「下界」语义"
else
  bad "K4: 说明未写明「下界」"
fi

# ── K5 · 强杀日志标明不含在途字节 ──
if grep -q '本对已传字节不计入本轮合计' "$SRC"; then
  ok "K5: 强杀日志标明已传字节不计入本轮合计"
else
  bad "K5: 强杀日志未标明字节不计入"
fi

echo "----------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
