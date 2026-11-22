#!/usr/bin/env bash
# ── VD（域名前缀 secret）合法性预检 ──
#
# 背景：2026-11-21 起 p / subs-check / ql / teslamate / sub-store / HomeAssistant 等
# workflow 全部卡在 `cloudflared tunnel route dns`，cloudflared 只回一句
# "xxx.***.eu.org is not a valid hostname" —— 真正的信息（secret 里到底混进了
# 空格 / 下划线 / 非 ASCII 同形字）被 GitHub 的打码吞掉，排障只能靠猜。
#
# 本脚本只输出「字节长度 + 各类字符出现次数 + 是否合法 DNS 标签」这些元信息，
# 绝不回显 secret 值本身（公开仓库日志，任何值都不打印）。
# 校验一律走 LC_ALL=C 的字节级判定：bash 的 [A-Za-z] 区间在 UTF-8 locale 下会
# 按 collation 放宽，可能把 é 之类的非 ASCII 字符误判成合法。
#
# 用法（workflow 里）：
#   env:
#     VD: ${{ secrets.VD }}
#   run: |
#     source "$GITHUB_WORKSPACE/.github/scripts/lib/require_vd.sh"
#     require_vd <用途标签>          # 例如 require_vd p（不合法 → 步骤失败）
#     require_vd <用途标签> --warn   # 不合法只告警、不中断（可选/容错步骤用）
#
# 返回：合法返回 0；不合法返回 1（配合 bash -e 让步骤带着明确原因失败）。
set -u

require_vd() {
  local tag="${1:-unknown}"
  local mode="${2:-fail}"
  local v="${VD:-}"

  local bytes lower upper digits hyphen high space tab newline cr underscore quote slash dot
  bytes=$(printf '%s' "$v" | LC_ALL=C wc -c | tr -d ' ')
  lower=$(printf '%s' "$v" | LC_ALL=C tr -cd 'a-z' | LC_ALL=C wc -c | tr -d ' ')
  upper=$(printf '%s' "$v" | LC_ALL=C tr -cd 'A-Z' | LC_ALL=C wc -c | tr -d ' ')
  digits=$(printf '%s' "$v" | LC_ALL=C tr -cd '0-9' | LC_ALL=C wc -c | tr -d ' ')
  hyphen=$(printf '%s' "$v" | LC_ALL=C tr -cd '-' | LC_ALL=C wc -c | tr -d ' ')
  high=$(printf '%s' "$v" | LC_ALL=C tr -d '\000-\177' | LC_ALL=C wc -c | tr -d ' ')
  space=$(printf '%s' "$v" | LC_ALL=C tr -cd ' ' | LC_ALL=C wc -c | tr -d ' ')
  tab=$(printf '%s' "$v" | LC_ALL=C tr -cd '\t' | LC_ALL=C wc -c | tr -d ' ')
  cr=$(printf '%s' "$v" | LC_ALL=C tr -cd '\r' | LC_ALL=C wc -c | tr -d ' ')
  newline=$(printf '%s' "$v" | LC_ALL=C tr -cd '\n' | LC_ALL=C wc -c | tr -d ' ')
  underscore=$(printf '%s' "$v" | LC_ALL=C tr -cd '_' | LC_ALL=C wc -c | tr -d ' ')
  quote=$(printf '%s' "$v" | LC_ALL=C tr -cd "\"'" | LC_ALL=C wc -c | tr -d ' ')
  slash=$(printf '%s' "$v" | LC_ALL=C tr -cd '/' | LC_ALL=C wc -c | tr -d ' ')
  dot=$(printf '%s' "$v" | LC_ALL=C tr -cd '.' | LC_ALL=C wc -c | tr -d ' ')

  local valid=false
  if [ "$bytes" -ge 1 ] && [ "$bytes" -le 63 ] && [ "$high" -eq 0 ] \
     && printf '%s' "$v" | LC_ALL=C grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'; then
    valid=true
  fi

  printf '[vd-check:%s] 字节=%s 合法DNS标签=%s 小写=%s 大写=%s 数字=%s 连字符=%s 非ASCII字节=%s 空格=%s Tab=%s 回车=%s 换行=%s 下划线=%s 引号=%s 斜杠=%s 点=%s\n' \
    "$tag" "$bytes" "$valid" "$lower" "$upper" "$digits" "$hyphen" "$high" \
    "$space" "$tab" "$cr" "$newline" "$underscore" "$quote" "$slash" "$dot"

  if [ "$valid" != true ]; then
    local level="error"
    [ "$mode" = "--warn" ] && level="warning"
    echo "::${level}::VD secret 不是合法 DNS 标签 —— 需为单个前缀（仅 a-z A-Z 0-9 与连字符，无空格/下划线/引号/换行/非ASCII）。上行为元信息，值本身不打印。"
    [ "$mode" = "--warn" ] && return 0
    return 1
  fi

  # 归一化：DNS 本身大小写不敏感，但 Cloudflare 侧 zone/记录是小写，
  # 带大写时 `cloudflared tunnel route dns` 会报 "is not a valid hostname"
  # （本地校验能过、zone 匹配失败，报错信息极具误导性）。
  # 这里统一转小写后再交给调用方使用（只改变量，不打印值）。
  VD=$(printf '%s' "$v" | LC_ALL=C tr 'A-Z' 'a-z')
  export VD
  return 0
}