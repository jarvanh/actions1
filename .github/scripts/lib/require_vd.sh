#!/usr/bin/env bash
# ── VD（域名前缀 secret）合法性预检 ──
#
# 背景：2026-11-21 起 p / subs-check / ql / teslamate / sub-store / HomeAssistant 等
# workflow 全部卡在 `cloudflared tunnel route dns`，cloudflared 只回一句
# "xxx.***.eu.org is not a valid hostname" —— 真正的信息（secret 里到底混进了
# 空格/下划线/引号/换行）被 GitHub 的打码吞掉，排障只能靠猜。
#
# 本脚本只输出「长度 + 各类字符是否出现 + 是否合法 DNS 标签」这些元信息，
# 绝不回显 secret 值本身（公开仓库日志，任何值都不打印）。
#
# 用法（workflow 里）：
#   env:
#     VD: ${{ secrets.VD }}
#   run: |
#     source "$GITHUB_WORKSPACE/.github/scripts/lib/require_vd.sh"
#     require_vd <用途标签>          # 例如 require_vd p（不合法 → 步骤失败）
#     require_vd <用途标签> --warn   # 不合法只告警、不中断（可选/容错步骤用）
#
# 返回：合法返回 0；不合法返回 1（配合 `bash -e` 让步骤带着明确原因失败）。
set -u

require_vd() {
  local tag="${1:-unknown}"
  local mode="${2:-fail}"
  local v="${VD:-}"
  local len=${#v}
  local has_space=false has_tab=false has_newline=false has_underscore=false
  local has_quote=false has_slash=false has_dot=false has_upper=false
  local edge_hyphen=false valid=false

  case "$v" in *" "*) has_space=true ;; esac
  case "$v" in *$'\t'*) has_tab=true ;; esac
  case "$v" in *$'\n'*) has_newline=true ;; esac
  case "$v" in *"_"*) has_underscore=true ;; esac
  case "$v" in *"'"*|*'"'*) has_quote=true ;; esac
  case "$v" in *"/"*) has_slash=true ;; esac
  case "$v" in *"."*) has_dot=true ;; esac
  case "$v" in *[A-Z]*) has_upper=true ;; esac
  case "$v" in -*|*-) edge_hyphen=true ;; esac

  # 单个 DNS 标签：字母/数字开头结尾，中间允许连字符，长度 1-63
  if [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
    valid=true
  fi

  printf '[vd-check:%s] 长度=%s 合法DNS标签=%s 含空格=%s 含Tab=%s 含换行=%s 含下划线=%s 含引号=%s 含斜杠=%s 含点=%s 含大写=%s 首尾连字符=%s\n' \
    "$tag" "$len" "$valid" "$has_space" "$has_tab" "$has_newline" \
    "$has_underscore" "$has_quote" "$has_slash" "$has_dot" "$has_upper" "$edge_hyphen"

  if [ "$valid" != true ]; then
    local level="error"
    [ "$mode" = "--warn" ] && level="warning"
    echo "::${level}::VD secret 不是合法 DNS 标签 —— secrets.VD 需为单个小写前缀（仅 a-z 0-9 与连字符，无空格/下划线/引号/换行/点）。上行为元信息，值本身不打印。"
    [ "$mode" = "--warn" ] && return 0
    return 1
  fi
  return 0
}