#!/bin/bash
# 缺失清单两路差集（file_fix_pipeline.sh _missing_list_two_way_diff）—— 逻辑验证
# 验证:
#   1. 名在源端、目标端无 → 进清单（原 comm -23 语义）
#   2. 同名同尺寸 → 不进
#   3. 同名尺寸不符 → 进（409 死锁半截件口径，本次新增）
#   4. 尺寸列非纯数字（"-"）→ 不判"不符"，只按名判定（宁漏勿错）
#   5. 目标端多出来的名字 → 不进（只关心源端有的）
#   6. 文件名含 ';' → 仍能正确取出路径与尺寸（末段 ;size 切分）
#   7. 空行 → 忽略
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# load_all.sh 会串起整条依赖链，单测只 source 被测文件（含 OL_FIELD_SEP 兜底）
source "$_REPO_ROOT/.github/scripts/openlist/file_fix_pipeline.sh" 2>/dev/null

if ! declare -F _missing_list_two_way_diff >/dev/null 2>&1; then
  echo "FAIL: _missing_list_two_way_diff 未定义（source 失败？）"
  echo "PASS=$PASS FAIL=1"
  exit 1
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# 输入口径与生产一致: `rclone lsf -R --files-only --format ps --separator ;`
printf '%s\n' \
  'a/b.txt;100' \
  'c.txt;200' \
  'd.txt;0' \
  'e;f.txt;300' \
  'g.txt;-' \
  'i.txt;42' \
  '' > "$TMPD/src.ls"

printf '%s\n' \
  'a/b.txt;100' \
  'c.txt;150' \
  'd.txt;0' \
  'e;f.txt;999' \
  'g.txt;777' \
  'h.txt;50' \
  '' > "$TMPD/dst.ls"

got="$(_missing_list_two_way_diff "$TMPD/src.ls" "$TMPD/dst.ls" | sort | tr '\n' ' ')"
want="c.txt e;f.txt i.txt "

if [ "$got" = "$want" ]; then
  ok "T1 两路差集（名缺失 + 尺寸不符）逐条正确: [$got]"
else
  bad "T1 两路差集不符: got=[$got] want=[$want]"
fi

# 细分断言（失败时能一眼看出是哪一类错了）
echo "$got" | grep -q 'a/b.txt' && bad "T2 同名同尺寸被误纳入（a/b.txt）" || ok "T2 同名同尺寸不纳入"
echo "$got" | grep -qE '(^| )d\.txt( |$)' && bad "T3 同名同尺寸(0==0) 被误纳入（d.txt）" || ok "T3 同名同尺寸(0==0) 不纳入"
echo "$got" | grep -qE '(^| )g\.txt( |$)' && bad "T4 尺寸列非数字被误纳入（g.txt）" || ok "T4 尺寸列非数字不纳入"
echo "$got" | grep -qE '(^| )h\.txt( |$)' && bad "T5 目标端多出项被误纳入（h.txt）" || ok "T5 目标端多出项不纳入"
echo "$got" | grep -q 'e;f.txt' && ok "T6 文件名含 ';' 正确切分" || bad "T6 文件名含 ';' 切分错误"

# 纯名口径（旧缓存）: 无 ';' → 只按名判定，不因尺寸误纳入
printf '%s\n' 'a.txt' 'b.txt' > "$TMPD/src_plain.ls"
printf '%s\n' 'a.txt' > "$TMPD/dst_plain.ls"
got2="$(_missing_list_two_way_diff "$TMPD/src_plain.ls" "$TMPD/dst_plain.ls" | sort | tr '\n' ' ')"
[ "$got2" = "b.txt " ] && ok "T7 纯名口径仅按名差集（b.txt）" || bad "T7 纯名口径错误: got=[$got2]"

# T8: **目标端为空**（目录不存在 → dst 清单空）—— 必须把源端全部判为缺失。
# 这是生产回归（run 44602418951）: NR==FNR 在第一个文件 0 行时无法区分文件，
# 源端每行都被当成 dst 记录吞掉 ⇒ 返回空 ⇒ 修复管线不启动。日志指纹是
# "同名尺寸不符 -N（合计 0）" 的负数。
: > "$TMPD/dst_empty.ls"
got3="$(_missing_list_two_way_diff "$TMPD/src.ls" "$TMPD/dst_empty.ls" | sort | tr '\n' ' ')"
want3="a/b.txt c.txt d.txt e;f.txt g.txt i.txt "
[ "$got3" = "$want3" ] && ok "T8 目标端为空 → 源端全部判缺失（回归: NR==FNR 陷阱）" \
  || bad "T8 目标端为空时漏判: got=[$got3] want=[$want3]"

# T8b: 源端为空 → 无输出（不应把 dst 当源端反着判）
got4="$(_missing_list_two_way_diff "$TMPD/dst_empty.ls" "$TMPD/dst.ls" | sort | tr '\n' ' ')"
[ -z "$got4" ] && ok "T8b 源端为空 → 无输出" || bad "T8b 源端为空却有输出: [$got4]"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
