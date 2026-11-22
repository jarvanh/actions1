#!/usr/bin/env bash
# ── 从 actions.tar.gz 恢复仓库、Secrets 与 Variables 到新的 GitHub 仓库 ──
#
# 用法（在解包后的归档根目录执行）：
#   ./restore.sh <owner/repo> [--private|--public]
#
# 前置：
#   - 已安装 gh 并完成 `gh auth login`（token 需 repo + workflow 权限；
#     组织仓库还需 admin:org 才能写 Secrets）
#   - 新账号下已建好（或允许本脚本创建）目标仓库
#
# 说明：
#   - 代码用 `git push --mirror` 恢复，包含所有分支、标签与历史。
#   - Secrets 从 secrets/secrets.json 逐项经 stdin 写入，不在命令行暴露值。
#   - Variables 从 metadata/variables.json 恢复。
#   - 迁移完成后请轮换全部 Secrets，并删除本归档或离线加密保存。
set -euo pipefail

TARGET="${1:-}"
VISIBILITY="${2:---private}"

if [ -z "$TARGET" ] || [ "$TARGET" = "-h" ] || [ "$TARGET" = "--help" ]; then
  echo "Usage: $0 <owner/repo> [--private|--public]" >&2
  exit 2
fi

case "$VISIBILITY" in
  --private|--public) ;;
  *) echo "Visibility must be --private or --public" >&2; exit 2 ;;
esac

ARCHIVE_ROOT="${ARCHIVE_ROOT:-$(pwd)}"
if [ ! -d "$ARCHIVE_ROOT/repo/repo.git" ]; then
  # 允许从脚本所在目录执行（归档根目录或仓库内 .github/scripts/archive）
  ARCHIVE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ ! -d "$ARCHIVE_ROOT/repo/repo.git" ]; then
  echo "❌ 找不到 repo/repo.git（请在 actions.tar.gz 解包后的根目录执行）" >&2
  exit 2
fi
if [ ! -s "$ARCHIVE_ROOT/secrets/secrets.json" ]; then
  echo "❌ 找不到 secrets/secrets.json" >&2
  exit 2
fi
command -v gh >/dev/null 2>&1 || { echo "❌ 需要 gh CLI" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "❌ 需要 git" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "❌ 需要 jq" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "❌ 请先 gh auth login" >&2; exit 2; }

echo "== 1/4 创建或复用目标仓库：$TARGET =="
if gh repo view "$TARGET" >/dev/null 2>&1; then
  echo "ℹ️ 仓库已存在，直接推送 mirror"
else
  gh repo create "$TARGET" "$VISIBILITY" --description "actions（自建 GitHub Actions 工作流集合）" >/dev/null
  echo "✅ 已创建 $TARGET"
fi

echo "== 2/4 推送全量 mirror（全部分支/标签/历史） =="
TMPDIR_RESTORE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RESTORE"' EXIT
git clone --mirror "$ARCHIVE_ROOT/repo/repo.git" "$TMPDIR_RESTORE/repo.git" >/dev/null
git -C "$TMPDIR_RESTORE/repo.git" push --mirror "https://github.com/${TARGET}.git"
DEFAULT_BRANCH="$(git -C "$TMPDIR_RESTORE/repo.git" symbolic-ref --short HEAD 2>/dev/null || echo main)"
gh repo edit "$TARGET" --default-branch "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
echo "✅ 代码已恢复（默认分支：$DEFAULT_BRANCH）"

echo "== 3/4 恢复 Secrets =="
SECRET_COUNT=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  # -j：原样输出，不追加换行；多行 Secret 也能保持原始字节
  if jq -j --arg n "$name" '.[$n]' "$ARCHIVE_ROOT/secrets/secrets.json" \
      | gh secret set "$name" --repo "$TARGET" >/dev/null; then
    SECRET_COUNT=$((SECRET_COUNT + 1))
  else
    echo "⚠️ 写入失败：$name" >&2
  fi
done < <(jq -r 'keys[]' "$ARCHIVE_ROOT/secrets/secrets.json")
echo "✅ 已写入 $SECRET_COUNT 个 Secrets"

if [ -s "$ARCHIVE_ROOT/secrets/UNCAPTURED.txt" ] && ! grep -qx '(none)' "$ARCHIVE_ROOT/secrets/UNCAPTURED.txt"; then
  echo "⚠️ 以下 Secrets 在归档时未能取值，需要从原账号后台补齐：" >&2
  sed 's/^/   - /' "$ARCHIVE_ROOT/secrets/UNCAPTURED.txt" >&2
fi

echo "== 4/4 恢复 Variables =="
if [ -s "$ARCHIVE_ROOT/metadata/variables.json" ]; then
  VAR_COUNT=0
  while IFS=$'\t' read -r name value_b64; do
    [ -n "$name" ] || continue
    value="$(printf '%s' "$value_b64" | base64 -d)"
    if gh variable set "$name" --repo "$TARGET" --body "$value" >/dev/null; then
      VAR_COUNT=$((VAR_COUNT + 1))
    else
      echo "⚠️ 变量写入失败：$name" >&2
    fi
  done < <(jq -r '.variables[]? | [.name, (.value // "" | @base64)] | @tsv' "$ARCHIVE_ROOT/metadata/variables.json")
  echo "✅ 已写入 $VAR_COUNT 个 Variables"
else
  echo "ℹ️ 没有 variables.json，跳过"
fi

cat <<'EOF'

✅ 仓库层恢复完成。接下来：
  1. 在仓库 Settings → Actions → General 确认允许 Actions，并设置 Workflow permissions 为 Read and write。
  2. 按 MIGRATION.md 第 5 节恢复 Dropbox 归档（openclaw.tar.gz / openclaw.env / OmniRoute.tar.gz 等）。
  3. 手动触发 openclaw.yml 首轮，验证 /health、SSH 入口与通知。
  4. 迁移完成后轮换全部 Secrets，并删除本归档或离线加密保存。
EOF