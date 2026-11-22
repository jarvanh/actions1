#!/usr/bin/env bash
# ── actions1 仓库全量快照归档（最终归档对象 actions1.tar.gz.age）──
#
# 目的：把「仓库本身」也纳入最终归档，迁移到新 GitHub 账号/仓库时无需再从
# 旧账号逐项抄 —— 代码全历史、Actions Secrets 明文、仓库变量、元数据与全量
# 迁移说明都在同一个包里。
#
# 调用方：openclaw.yml 的 "Snapshot actions1 repository" 步骤（最终归档之前）
# 关键输入：
#   SECRETS_JSON   = ${{ toJSON(secrets) }}，GitHub 在运行时注入的全部 Secrets
#   GH_TOKEN       = ${{ github.token }}，用于 mirror clone 与元数据 API
#   ARCHIVE_AGE_RECIPIENTS = age 收件人（每行一个 SSH/age 公钥）；私钥只在主人手里
#   各 Secret 同名环境变量 = 兜底（toJSON 偶发缺项时按名补）
# 产物布局（age 解密后解包即得）：
#   MIGRATION.md  README.md  restore.sh  MANIFEST.sha256
#   repo/repo.git/           git mirror（全部分支/标签/历史）
#   repo/repo-worktree.tar.gz 当前 HEAD 工作树快照
#   secrets/secrets.json     全部 Secrets 明文（600）
#   secrets/values/<NAME>    逐项原文（600，保留多行值）
#   secrets/index.tsv        名称/字节/行数/sha256（不含值）
#   secrets/UNCAPTURED.txt   仓库里存在但本次未能取值的 Secret 名称
#   metadata/*.json          仓库、分支、标签、Release、Workflow、Variables 元数据
#
# 安全口径：
#   - 明文 tar 只在 runner 本地短暂存在；打包完成后立即用 age 加密并删除明文。
#   - age 收件人是主人的 SSH 公钥；私钥不在仓库/Secrets/Dropbox 中。
#   - 未配置收件人或 age 不可用时 fail-closed，绝不回退上传明文。
#   - umask 077，包与暂存全部仅属主可读；任何值都不写日志、不进 stdout。
#   - mirror clone 后立刻把带 token 的 URL 换成无凭据 URL，并扫描 token 残留。
#   - 本包是「迁移用高敏材料」，解密后仍应离线保存并尽快轮换 Secrets。
set -euo pipefail

OUTPUT_TAR="${1:-}"
if [ -z "$OUTPUT_TAR" ]; then
  echo "Usage: $0 /path/to/output.tar.gz" >&2
  exit 2
fi

# ── 加密前置检查（fail-closed）──
# 收件人来自仓库变量 ARCHIVE_AGE_RECIPIENTS（每行一个 SSH/age 公钥）。
# 没有收件人就拒绝生成/上传任何明文包；这是防止 GitHub 误判和云端泄露的关键。
ARCHIVE_AGE_RECIPIENTS="${ARCHIVE_AGE_RECIPIENTS:-${ARCHIVE_AGE_RECIPIENT:-}}"
if [ -z "${ARCHIVE_AGE_RECIPIENTS//[[:space:]]/}" ]; then
  echo "actions1_archive_encryption_recipient_missing" >&2
  exit 5
fi
if ! command -v age >/dev/null 2>&1; then
  echo "actions1_archive_age_missing" >&2
  exit 5
fi

umask 077

REPO="${GITHUB_REPOSITORY:-jarvanh/actions1}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
SRC_WS="${GITHUB_WORKSPACE:-$(pwd)}"
MIN_SIZE=$((100 * 1024))
STAGE_DIR=""

ENCRYPTED=0
cleanup() {
  if [ -n "${STAGE_DIR:-}" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
  fi
  # 加密失败/中途退出时不留明文 tar
  if [ "${ENCRYPTED:-0}" -ne 1 ]; then
    rm -f "$OUTPUT_TAR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

rm -f "$OUTPUT_TAR"
STAGE_DIR=$(mktemp -d /tmp/actions1-repo-archive-stage.XXXXXX)
mkdir -p "$STAGE_DIR/repo" "$STAGE_DIR/metadata" "$STAGE_DIR/secrets/values"

# ── 1. 代码：全量 mirror（所有分支、标签、历史；可直接 push --mirror 恢复）──
CLONE_URL="${SERVER}/${REPO}.git"
if [ -n "$TOKEN" ]; then
  CLONE_URL="https://x-access-token:${TOKEN}@github.com/${REPO}.git"
fi
if ! git clone --mirror "$CLONE_URL" "$STAGE_DIR/repo/repo.git" >/tmp/actions1-archive-git.log 2>&1; then
  # 失败日志可能包含带 token 的 clone URL（调试信息里最典型的泄密点），
  # 任何环节都不回显原文，只报固定错误码；Detail 字段留给调用方自行排查网络/权限。
  echo "actions1_repo_clone_failed repo=${REPO}" >&2
  rm -f /tmp/actions1-archive-git.log
  exit 1
fi
# token 只用于本次 clone；归档里的 origin 必须是无凭据 URL
git -C "$STAGE_DIR/repo/repo.git" remote set-url origin "${SERVER}/${REPO}.git"
if [ -n "$TOKEN" ] && grep -RIl -F --binary-files=without-match "$TOKEN" "$STAGE_DIR/repo/repo.git" >/dev/null 2>&1; then
  echo "actions1_archive_token_leak_detected" >&2
  exit 1
fi

git -C "$STAGE_DIR/repo/repo.git" for-each-ref --format='%(refname) %(objectname)' \
  > "$STAGE_DIR/metadata/refs.txt"
git -C "$STAGE_DIR/repo/repo.git" rev-parse HEAD > "$STAGE_DIR/metadata/head.txt"
git -C "$STAGE_DIR/repo/repo.git" count-objects -v > "$STAGE_DIR/metadata/count-objects.txt"
if ! git -C "$STAGE_DIR/repo/repo.git" fsck --connectivity-only --no-dangling >/tmp/actions1-archive-fsck.log 2>&1; then
  echo "actions1_repo_fsck_failed" >&2
  tail -n 8 /tmp/actions1-archive-fsck.log >&2 || true
  exit 1
fi

# 当前 HEAD 工作树（不含 .git）单独一份，方便不熟悉 git 的人直接看文件
if git -C "$SRC_WS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$SRC_WS" archive --format=tar.gz --prefix=repo-worktree/ \
    -o "$STAGE_DIR/repo/repo-worktree.tar.gz" HEAD
else
  tar -C "$SRC_WS" --exclude=.git -czf "$STAGE_DIR/repo/repo-worktree.tar.gz" .
fi

# ── 2. 元数据（失败只降级，不影响代码/Secrets 主体）──
gh_api_to_file() { # <endpoint> <file>
  local endpoint="$1" file="$2"
  if command -v gh >/dev/null 2>&1 && gh api "$endpoint" > "$file" 2>/tmp/actions1-archive-gh.err; then
    return 0
  fi
  echo "metadata_fetch_failed endpoint=${endpoint}" > "${file%.json}.error.txt"
  return 0
}
gh_api_to_file "repos/${REPO}" "$STAGE_DIR/metadata/repo.json"
gh_api_to_file "repos/${REPO}/branches?per_page=100" "$STAGE_DIR/metadata/branches.json"
gh_api_to_file "repos/${REPO}/tags?per_page=100" "$STAGE_DIR/metadata/tags.json"
gh_api_to_file "repos/${REPO}/releases?per_page=100" "$STAGE_DIR/metadata/releases.json"
gh_api_to_file "repos/${REPO}/actions/workflows?per_page=100" "$STAGE_DIR/metadata/workflows.json"
gh_api_to_file "repos/${REPO}/actions/variables?per_page=100" "$STAGE_DIR/metadata/variables.json"
gh_api_to_file "repos/${REPO}/actions/secrets?per_page=100" "$STAGE_DIR/metadata/secret-names.json"

# ── 3. Secrets：toJSON(secrets) 为主，同名环境变量兜底 ──
# 这里刻意由 Python 读环境变量并在内存中组装；任何异常只输出固定错误码，
# 不打印原始值或 JSON 片段（防止 secret 进日志）。
python3 - "$STAGE_DIR" <<'PY'
import hashlib
import json
import os
import re
import sys

stage = sys.argv[1]

# 当前仓库已配置的 Secrets（2026-11-21 快照）。新增 Secret 时无需改这里：
# SECRETS_JSON 是主来源，本列表只用于 toJSON 缺项时从同名环境变量兜底。
# GH_TOKEN 在 workflow 里被 github.token 占用（脚本自身要用 gh API），
# 仓库里的同名 Secret 通过 GH_TOKEN_SECRET 传入，避免把临时 GITHUB_TOKEN
# 误当成可迁移 Secret 归档。
ENV_OVERRIDES = {"GH_TOKEN": "GH_TOKEN_SECRET"}

KNOWN_SECRETS = [
    "AI_GATEWAY_API_KEY", "ANTIGRAVITY_API_KEY", "AUTOCLAW_GATEWAY_KEY",
    "CLIPROXYAPI_API_KEY", "EMBY_API_TOKEN", "EMBY_USER", "GH_TOKEN",
    "GITEE_PRIVATE_TOKEN", "GLM2API_GATEWAY_KEY", "GLM_REFRESH_TOKEN",
    "JELLYFIN_API_TOKEN", "MANAGEMENT_KEY", "NOTION_API_KEY",
    "OPENCLAW_HOOK_TOKEN", "OPENCLAW_HOOK_URL", "PAT",
    "PROXY_SPEEDTEST_CDN_GIST_ID", "PROXY_SPEEDTEST_GISTNODES_GIST_ID",
    "PROXY_SPEEDTEST_GIST_ID", "PROXY_SPEEDTEST_GITEE_OWNER",
    "PROXY_SPEEDTEST_SUB_URLS", "PROXY_SPEEDTEST_TAIER_GIST_ID", "RCLONE",
    "RDP_PASSWORD", "RUNNER_PASSWORD", "RUSTDESK_PASSWORD",
    "SOCKS_EXIT_GIST_ID", "SUBS_CHECK_GIST_ID", "TAVILY_API_KEY",
    "TELEGRAM_BOT_TOKEN", "TELEGRAM_BOT_TOKEN_ALERT",
    "TELEGRAM_BOT_TOKEN_RSS_SB_BOT", "TELEGRAM_CHAT_ID",
    "TELEGRAM_CHAT_ID_ALERT", "TS_API_KEY", "TS_CERT_GPG_KEY",
    "TS_OAUTH_CLIENT_ID", "TS_OAUTH_CLIENT_SECRET", "VD",
    "YSHOP_WX_MINIAPP_APPID", "YSHOP_WX_MINIAPP_SECRET", "ZCODE_GATEWAY_KEY",
]

data = {}
raw = os.environ.get("SECRETS_JSON", "").strip()
if raw:
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            for k, v in obj.items():
                if isinstance(v, (str, int, float, bool)) or v is None:
                    data[str(k)] = "" if v is None else str(v)
    except Exception:
        pass

for name in KNOWN_SECRETS:
    if name in data:
        continue
    val = os.environ.get(ENV_OVERRIDES.get(name, name))
    if val is not None:
        data[name] = val

# GITHUB_TOKEN 是每次运行自动签发的短时令牌，不属于可迁移 Secret；
# 恢复后由 GitHub 自动提供，写入归档只会造成误导。
data.pop("GITHUB_TOKEN", None)

if not data:
    sys.stderr.write("actions1_secrets_empty\n")
    sys.exit(1)

safe_name = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
values_dir = os.path.join(stage, "secrets", "values")
os.makedirs(values_dir, exist_ok=True)
index_rows = []
clean = {}
for name in sorted(data):
    if not safe_name.match(name):
        continue
    val = data[name]
    clean[name] = val
    path = os.path.join(values_dir, name)
    with open(path, "wb") as fh:
        fh.write(val.encode("utf-8"))
    os.chmod(path, 0o600)
    digest = hashlib.sha256(val.encode("utf-8")).hexdigest()
    index_rows.append((name, str(len(val.encode("utf-8"))), str(val.count("\n") + 1), digest))

with open(os.path.join(stage, "secrets", "secrets.json"), "w", encoding="utf-8") as fh:
    json.dump(clean, fh, ensure_ascii=False, indent=2, sort_keys=True)
os.chmod(os.path.join(stage, "secrets", "secrets.json"), 0o600)

with open(os.path.join(stage, "secrets", "index.tsv"), "w", encoding="utf-8") as fh:
    fh.write("name\tbytes\tlines\tsha256\n")
    for row in index_rows:
        fh.write("\t".join(row) + "\n")

# 仓库里存在、但本次 toJSON/环境变量没拿到值的 Secret 名单（只列名字）
available = set(clean)
try:
    api = json.load(open(os.path.join(stage, "metadata", "secret-names.json"), encoding="utf-8"))
    api_names = {s.get("name") for s in api.get("secrets", []) if isinstance(s, dict)}
except Exception:
    api_names = set()
uncaptured = sorted(n for n in api_names if n and n not in available)
with open(os.path.join(stage, "secrets", "UNCAPTURED.txt"), "w", encoding="utf-8") as fh:
    if uncaptured:
        fh.write("\n".join(uncaptured) + "\n")
    else:
        fh.write("(none)\n")

with open(os.path.join(stage, "secrets", "README.md"), "w", encoding="utf-8") as fh:
    fh.write(
        "# Secrets（高敏）\n\n"
        "本目录保存 actions1 仓库全部 GitHub Actions Secrets 的**明文**，"
        "仅在 age 解密后的归档内可见，用于迁移到新账号后原样恢复。\n\n"
        "- `secrets.json`：JSON 对象，名称 → 值；多行值（如 `RCLONE`、"
        "`TS_CERT_GPG_KEY`）以 `\\n` 转义。\n"
        "- `values/<NAME>`：逐项原文，保留原始换行，可直接 "
        "`gh secret set <NAME> --repo <new-repo> < values/<NAME>`。\n"
        "- `index.tsv`：名称、字节数、行数、SHA-256；不含值，供核对。\n"
        "- `UNCAPTURED.txt`：仓库里存在但本次未取到值的 Secret 名称；"
        "迁移前需从原账号后台补齐。\n\n"
        "迁移完成后：立即轮换全部密钥；解密后的明文包应删除或离线加密保存。\n"
    )
PY

# ── 4. 迁移说明与恢复脚本 ──
cp "$SRC_WS/docs/migration.md" "$STAGE_DIR/MIGRATION.md"
cp "$SRC_WS/README.md" "$STAGE_DIR/README.md"
cp "$SRC_WS/.github/scripts/archive/restore-actions1.sh" "$STAGE_DIR/restore.sh"
chmod 700 "$STAGE_DIR/restore.sh"

# ── 5. 清单与元信息 ──
{
  echo "repo=${REPO}"
  echo "archived_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "source_commit=$(git -C "$SRC_WS" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "source_branch=${GITHUB_REF_NAME:-unknown}"
  echo "secrets_count=$(find "$STAGE_DIR/secrets/values" -type f | wc -l | tr -d ' ')"
  echo "refs_count=$(wc -l < "$STAGE_DIR/metadata/refs.txt" | tr -d ' ')"
  echo "encryption=age-ssh"
  echo "encryption_recipients=$(printf '%s\n' "$ARCHIVE_AGE_RECIPIENTS" | grep -c '^[[:space:]]*[^[:space:]]' || true)"
} > "$STAGE_DIR/ARCHIVE-META.txt"

(
  cd "$STAGE_DIR"
  find . -type f ! -name MANIFEST.sha256 -print0 \
    | sort -z \
    | xargs -0 sha256sum > MANIFEST.sha256
)

nice -n 19 ionice -c3 tar -C "$STAGE_DIR" -czf "$OUTPUT_TAR" .
chmod 600 "$OUTPUT_TAR"

# ── 6. 完整性判据：缺任一核心项都拒绝覆盖云端好包 ──
actual_size=$(stat -c%s "$OUTPUT_TAR" 2>/dev/null || echo 0)
if [ ! -s "$OUTPUT_TAR" ] || [ "$actual_size" -lt "$MIN_SIZE" ]; then
  echo "actions1_archive_too_small size=${actual_size} min=${MIN_SIZE}" >&2
  exit 4
fi

list_file=$(mktemp /tmp/actions1-archive-list.XXXXXX)
tar -tzf "$OUTPUT_TAR" > "$list_file"
missing=""
for required in ./MIGRATION.md ./restore.sh ./repo/repo.git/HEAD ./repo/repo-worktree.tar.gz ./secrets/secrets.json ./MANIFEST.sha256; do
  if ! grep -qxF "$required" "$list_file"; then
    missing="$missing $required"
  fi
done
rm -f "$list_file"
if [ -n "$missing" ]; then
  echo "actions1_archive_incomplete missing=${missing}" >&2
  exit 4
fi

secret_count=$(find "$STAGE_DIR/secrets/values" -type f | wc -l | tr -d ' ')
ref_count=$(wc -l < "$STAGE_DIR/metadata/refs.txt" | tr -d ' ')
if [ "$secret_count" -lt 1 ] || [ "$ref_count" -lt 1 ]; then
  echo "actions1_archive_incomplete secrets=${secret_count} refs=${ref_count}" >&2
  exit 4
fi

# ── 7. age 加密（SSH 公钥收件人；私钥只在主人手里）──
# 收件人每行一个，支持同时加密给多把 SSH key（任意一把私钥可解）。
# age 的 -R 参数是「收件人文件路径」，不是 key 字符串；这里写临时文件（600）。
RECIPIENTS_FILE=$(mktemp /tmp/actions1-age-recipients.XXXXXX)
chmod 600 "$RECIPIENTS_FILE"
_recipient_count=0
while IFS= read -r _recipient; do
  # 去首尾空白；保留 key 内部的单个空格
  _recipient="$(printf '%s' "$_recipient" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$_recipient" ] || continue
  printf '%s\n' "$_recipient" >> "$RECIPIENTS_FILE"
  _recipient_count=$((_recipient_count + 1))
done <<< "$ARCHIVE_AGE_RECIPIENTS"
if [ "$_recipient_count" -eq 0 ]; then
  rm -f "$RECIPIENTS_FILE"
  echo "actions1_archive_encryption_recipient_invalid" >&2
  exit 5
fi

OUTPUT_ENC="${OUTPUT_TAR}.age"
rm -f "$OUTPUT_ENC"
if ! age -R "$RECIPIENTS_FILE" -o "$OUTPUT_ENC" "$OUTPUT_TAR"; then
  rm -f "$RECIPIENTS_FILE"
  echo "actions1_archive_encrypt_failed" >&2
  exit 5
fi
rm -f "$RECIPIENTS_FILE"
if [ ! -s "$OUTPUT_ENC" ]; then
  echo "actions1_archive_encrypt_empty" >&2
  exit 5
fi
chmod 600 "$OUTPUT_ENC"
enc_size=$(stat -c%s "$OUTPUT_ENC")
# 加密成功后立刻删除明文 tar；后续调用方只认 .age
rm -f "$OUTPUT_TAR"
ENCRYPTED=1

echo "archive_ready size=${enc_size} plaintext_size=${actual_size} secrets=${secret_count} refs=${ref_count} output=${OUTPUT_ENC} encrypted=age-ssh"
