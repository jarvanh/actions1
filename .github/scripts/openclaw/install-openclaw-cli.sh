#!/usr/bin/env bash
# 安装 OpenClaw CLI：先下载官方 installer 到临时文件，校验 SHA256 后再执行。
#
# 背景（安全整改 ACT4）：原调用形态是 `curl -fsSL https://openclaw.ai/install.sh | bash`
# —— 远端脚本内容直接进 shell，既没有版本固定也没有完整性校验，上游/传输链路任何
# 变化都会立刻以 runner 权限执行。本脚本把流程改成「下载 → 校验 → 执行」：
#   1. 下载到私有临时文件（curl --proto '=https' --tlsv1.2，只允许 HTTPS）
#   2. 与仓库内 pin 的 SHA256（.github/scripts/checksums/openclaw-install.sh.sha256）比对
#   3. 不一致或 pin 缺失一律失败（fail closed），绝不执行未校验内容
#
# ⚠️ 上游 installer 更新后本脚本会按设计失败，此时必须：
#   1. 人工审阅新 installer 的 diff（curl 下来比对，不要直接放过）
#   2. 更新 .github/scripts/checksums/openclaw-install.sh.sha256
#   3. 与本次改动一起提交
# 这是有意的摩擦：OpenClaw 的安装器以 runner 权限运行，变更必须被看见。
#
# 用法: install-openclaw-cli.sh [installer 参数...]   （如 --no-onboard）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${OPENCLAW_INSTALLER_URL:-https://openclaw.ai/install.sh}"
PIN_FILE="${OPENCLAW_INSTALLER_PIN_FILE:-${SCRIPT_DIR}/../checksums/openclaw-install.sh.sha256}"

if [ ! -r "$PIN_FILE" ]; then
  echo "::error::OpenClaw installer 校验和文件缺失: $PIN_FILE" >&2
  exit 1
fi
EXPECTED="$(awk '$2 == "openclaw-install.sh" {print $1}' "$PIN_FILE" | head -n 1)"
case "$EXPECTED" in
  [0-9a-fA-F]*) ;;
  *)
    echo "::error::OpenClaw installer 校验和未配置（$PIN_FILE 中无有效 SHA256）" >&2
    exit 1
    ;;
esac

# 2026-11-15 上游 installer 改版新增两道环境检查（实测 run 43658656383 之后的
# 手工复现）：npm 全局 prefix 不可写 + 存在 ~/.nvm 时，installer 会拒绝继续并
# 要求用户交互式跑 `nvm install`。runner 是非交互环境，会直接失败。
# 对策：把 npm prefix 指到 runner 可写的 ~/.npm-global（并预建 lib/，否则
# installer 的 -w 检查仍不通过），并把其 bin 放到 PATH 最前。
# 副作用：openclaw CLI 落在 ~/.npm-global/bin —— 后续步骤需同样带上该 PATH
#（prepare-runtime-env 与调用方已统一从 install 步骤继承，见 openclaw.yml）。
if ! npm_prefix="$(npm config get prefix 2>/dev/null)" || [ ! -w "${npm_prefix:-/nonexistent}" ]; then
  export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-$HOME/.npm-global}"
  mkdir -p "$NPM_CONFIG_PREFIX/lib"
  export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
  # 持久化到 ~/.npmrc：后面的「Prepare runtime env」用 `npm config get prefix`
  # 组装 GITHUB_PATH，只有写进 npmrc，openclaw 的 bin 目录才会进后续步骤 PATH。
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
ACTUAL="$(sha256sum "$TMP_INSTALLER" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "::error::OpenClaw installer SHA256 校验失败（期望 $EXPECTED，实际 $ACTUAL）" >&2
  echo "::error::上游脚本已变化。请审阅差异后更新 $PIN_FILE 再重试；本轮拒绝执行未校验脚本。" >&2
  exit 1
fi
echo "✅ OpenClaw installer SHA256 校验通过（$ACTUAL）"

chmod 700 "$TMP_INSTALLER"
rc=0
bash "$TMP_INSTALLER" "$@" || rc=$?
exit "$rc"
