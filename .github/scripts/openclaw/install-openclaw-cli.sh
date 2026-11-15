#!/usr/bin/env bash
# 安装 OpenClaw CLI：把官方 installer 下载到私有临时文件后执行。
#
# 2026-11-15 主人决定：**不固定版本、不校验 SHA256**，始终安装最新版。
# 背景：上游发版节奏约 1-2 周一次（实测 10.8 → 10.10 → 11.1 → 11.2 → 11.3 →
# 11.5-beta），install.sh 内容随发版变化；此前 pin 住 SHA256 后，上游每次改版都会
# 在下一轮 fail-closed 拒绝执行 → Install 失败 → 网关起不来（run 43658656383）。
# 主人已明确接受该风险（与「token 存 .env」同口径），此处不再做完整性约束。
#
# 保留的两条底线：
#   · 只允许 HTTPS 下载到私有临时文件，再显式 bash 执行（不做 curl | bash 管道）
#   · 下载失败/空文件一律拒绝执行
#
# ⚠️ 因此本脚本执行的是**上游当前内容**：任何上游改动都会在下一轮直接生效。
#
# 用法: install-openclaw-cli.sh [installer 参数...]   （如 --no-onboard）
set -euo pipefail

URL="${OPENCLAW_INSTALLER_URL:-https://openclaw.ai/install.sh}"

# 2026-11-15（上游改版新增检查）：npm 全局 prefix 不可写且存在 ~/.nvm 时，
# installer 会拒绝继续并要求交互式 `nvm install` —— runner 非交互，必然失败。
# 对策：把 prefix 指到 runner 可写的 ~/.npm-global（预建 lib/，否则它的 -w
# 检查仍不通过），并**持久化到 ~/.npmrc**：后续「Prepare runtime env」正是用
# `npm config get prefix` 组装 GITHUB_PATH，不落 npmrc 会导致 openclaw 不在
# 后续步骤的 PATH 里。
if ! npm_prefix="$(npm config get prefix 2>/dev/null)" || [ ! -w "${npm_prefix:-/nonexistent}" ]; then
  export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-$HOME/.npm-global}"
  mkdir -p "$NPM_CONFIG_PREFIX/lib"
  export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
  npm config set prefix "$NPM_CONFIG_PREFIX" >/dev/null 2>&1 || true
fi

TMP_INSTALLER="$(mktemp "${TMPDIR:-/tmp}/openclaw-install.XXXXXX")"
cleanup() { rm -f "$TMP_INSTALLER"; }
trap cleanup EXIT

echo "下载 OpenClaw installer: $URL"
if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "$TMP_INSTALLER" "$URL"; then
  echo "::error::OpenClaw installer 下载失败，拒绝执行" >&2
  exit 1
fi
if [ ! -s "$TMP_INSTALLER" ]; then
  echo "::error::OpenClaw installer 内容为空，拒绝执行" >&2
  exit 1
fi

chmod 700 "$TMP_INSTALLER"
rc=0
bash "$TMP_INSTALLER" "$@" || rc=$?
exit "$rc"
