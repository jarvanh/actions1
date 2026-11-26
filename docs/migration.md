# actions 全量迁移说明

> 适用场景：把 `jarvanh/actions` 整体迁移到新的 GitHub 账号/组织（或从本归档冷启动一套等价环境）。
>
> 归档对象：`dropbox:self-hosted/actions.tar.gz`。2026-11-22 起 `openclaw.yml`
> 不再每轮生成/覆盖该包（「Snapshot actions repository」步骤已移除，防 action_required）；
> Dropbox 上 **2026-11-22 19:39 的版本为最后一版**，迁移直接用它；需要刷新时手动跑
> `actions-archive.yml`。
>
> 本说明是迁移流程的**唯一入口**；各子系统的实现细节仍以 `docs/openclaw.md`、
> `docs/emby.md` 等专项文档为准。

---

## 一、归档包里有什么

`actions.tar.gz` 解包后的布局：

```
actions.tar.gz
├── MIGRATION.md                 # 本文件
├── README.md                    # 仓库说明（快照时点）
├── restore.sh                   # 一键恢复仓库 + Secrets + Variables
├── repo/
│   ├── repo.git/                # git mirror：全部分支、标签、历史
│   └── repo-worktree.tar.gz     # 当前 HEAD 工作树（不含 .git）
├── secrets/
│   ├── secrets.json             # 全部 Actions Secrets 明文（名称 → 值）
│   ├── values/<NAME>            # 逐项原文（保留多行）
│   ├── index.tsv                # 名称/字节/行数/SHA-256（不含值）
│   ├── UNCAPTURED.txt           # 归档时未能取值的 Secret 名称
│   └── README.md
├── metadata/
│   ├── repo.json                # 仓库元信息
│   ├── branches.json / tags.json / releases.json / workflows.json
│   ├── variables.json           # Actions Variables（含值）
│   ├── secret-names.json        # Secret 名称清单（不含值）
│   └── refs.txt / head.txt / count-objects.txt
├── ARCHIVE-META.txt             # 归档时间、源提交、分支、计数
└── MANIFEST.sha256              # 全包文件校验和
```

> ⚠️ `secrets/` 与 `secrets.json` 是**明文密钥**。这个包等同于账号的钥匙串。
> 按主人 2026-11-21 的决定：**Dropbox 视为可信存储**，该包可长期保存在
> `dropbox:self-hosted/actions.tar.gz`；迁移完成后仍建议轮换 Secrets（降低历史泄露面），
> 但不必为此删除或额外加密云端归档。

---

## 二、迁移前准备

1. **新账号/组织**：能创建仓库、能运行 Actions。
2. **GitHub PAT**（建议 fine-grained 或 classic）：
   - `repo`：读写目标仓库；
   - `workflow`：写入 `.github/workflows`；
   - 组织仓库还需要 `admin:org`（写组织级 Secrets）或仓库 `admin` 权限。
3. **工具**：`git`、`gh`（已 `gh auth login`）、`jq`、`rclone`、`tar`。
4. **外部依赖账号**（按需）：
   - Dropbox：保存 `self-hosted/` 下的全部归档；
   - Tailscale：`TS_OAUTH_CLIENT_ID` / `TS_OAUTH_CLIENT_SECRET` / `TS_API_KEY`；
   - Cloudflare：命名隧道证书与 `VD` 域名；
   - Telegram：各 bot token 与 chat id；
   - 其他服务（Emby、Jellyfin、Notion、Gitee、OpenList 等）的凭据。

### 先停旧环境

迁移期间**必须只保留一套在跑**。旧仓库的 `openclaw.yml` 每 5 分钟调度一次，
两台同时运行会争抢 Dropbox 上的同一份归档并造成双写：

```bash
# 在旧仓库 Settings → Actions → General → Disable Actions
# 或至少禁用 openclaw.yml 的 schedule（删除 cron 触发器）
```

确认旧环境已停（没有新的 run、没有 Tailscale `openclaw` 节点）后再开始恢复。

---

## 三、恢复仓库代码

### 方式 A：一键脚本（推荐）

```bash
mkdir actions-restore && cd actions-restore
tar -xzf /path/to/actions.tar.gz
./restore.sh <new-owner>/<new-repo> --private   # 或 --public
```

脚本会：创建仓库（若不存在）→ `git push --mirror` 全部分支/标签/历史 →
写入 Secrets → 写入 Variables。

### 方式 B：手工恢复

```bash
# 1) 建仓
gh repo create <new-owner>/<new-repo> --private

# 2) 推送全量镜像（包含所有 refs）
git clone --mirror repo/repo.git /tmp/actions.git
git -C /tmp/actions.git push --mirror https://github.com/<new-owner>/<new-repo>.git

# 3) 校验
git ls-remote https://github.com/<new-owner>/<new-repo>.git | head
```

恢复后确认：

- 默认分支为 `main`；
- 分支、标签数量与原仓库一致（见 `metadata/refs.txt`）；
- `.github/workflows/` 下工作流文件齐全；
- `git log` 历史完整（mirror 包含全部提交）。

---

## 四、恢复 Secrets 与 Variables

### 4.1 一键写入

```bash
# Secrets：逐项经 stdin 写入，值不出现在命令历史/进程参数中
jq -r 'keys[]' secrets/secrets.json | while IFS= read -r name; do
  jq -j --arg n "$name" '.[$n]' secrets/secrets.json \
    | gh secret set "$name" --repo <new-owner>/<new-repo>
done

# Variables
jq -r '.variables[]? | [.name, (.value // "" | @base64)] | @tsv' metadata/variables.json \
| while IFS=$'\t' read -r name value_b64; do
  gh variable set "$name" --repo <new-owner>/<new-repo> \
    --body "$(printf '%s' "$value_b64" | base64 -d)"
done
```

### 4.2 逐个文件写入（多行值更直观）

```bash
for f in secrets/values/*; do
  gh secret set "$(basename "$f")" --repo <new-owner>/<new-repo> < "$f"
done
```

### 4.3 核对

```bash
gh secret list --repo <new-owner>/<new-repo>
gh variable list --repo <new-owner>/<new-repo>
```

- `secrets/index.tsv` 记录每个 Secret 的字节数、行数与 SHA-256；可逐项对照。
- 若 `secrets/UNCAPTURED.txt` 不是 `(none)`，说明这些 Secret 在归档时就没取到值，
  必须从原账号后台/其他备份补齐；否则对应工作流会在运行时报鉴权失败。

### 4.4 当前快照中「工作流引用但仓库未配置」的 Secrets

以下名称在 2026-11-21 的 `actions` 仓库中**没有配置值**（工作流引用了它们），
迁移后需要补齐后对应工作流才能完整运行：

```
APPLEID  APPLEPASSWORD  ESHOP_MYSQL_PASSWORD  ESHOP_MYSQL_ROOT_PASSWORD
NGROK_AUTH_TOKEN  OPENLIST_ADMIN_PASSWORD  PORNHUBNAME
SUB_STORE_FRONTEND_BACKEND_PATH  TELEGRAM_CHANNEL_ID_PH
TG_API_HASH  TG_API_ID  TG_SESSION  VAULTWARDEN  X
ZCODE_GATEWAY_API_KEY
```

> `GITHUB_TOKEN` 不需要手工设置：每个 workflow run 由 GitHub 自动签发。
> `TG_SESSION` 可在本机交互生成：`python3 .github/scripts/tg-channel/tg_login.py`（二维码或手机号验证码登录，凭据读环境变量或 `~/.tg_creds`），session 直写 GitHub Secret，不打印、不落盘。

---

## 五、恢复 Dropbox 归档（服务数据）

`openclaw.yml` 启动时会从 `dropbox:self-hosted/` 读取以下对象。迁移到新账号后，
把原 Dropbox（或本地备份）中的这些文件原样放回同一路径：

| 归档对象 | 内容 | 恢复时机 |
|---|---|---|
| `openclaw.tar.gz` | OpenClaw 主状态包（`~/.openclaw`，最后健康状态） | 启动时自动解包 |
| `openclaw.env` | `~/.openclaw/.env` 独立小文件（4KB 级，先于主包恢复） | 启动时自动恢复 |
| `OmniRoute.tar.gz` | OmniRoute 数据卷快照（`storage.sqlite` 等） | AI 网关步骤自动恢复 |
| `CliRelay.tar.gz` / `CLIProxyAPI.tar.gz` | 回退后端数据（按需） | 仅当 `ai_backend` 指定回退后端 |
| `zcode.tar.gz` | ZCode 个人数据（`~/.zcode`） | Restore ZCode 步骤 |
| `zcode2api-data.tar.gz` | zcode2api 的 `.env` + `data/`（账号池） | zcode2api 启动步骤 |
| `rsstt.tar.gz` | rss-to-telegram 的 `config/`（bot.session + db.sqlite3） | 容器启动步骤 |
| `actions.tar.gz` | **本仓库全量快照（代码 + Secrets + 本说明）** | 人工迁移时使用 |

此外还需要：

- `dropbox:self-hosted/rclone.conf`：rclone 配置（`RCLONE` secret 的持久化副本）；
- `dropbox:self-hosted/.cloudflared/`：Cloudflare 命名隧道证书；
- `dropbox:self-hosted/workbuddy-gateway/`：workbuddy 凭据（`workbuddy*.json`，需扫码）；
- `dropbox:self-hosted/qingyan-proxy/`、`autoclaw-proxy/`、`qoder2api/` 等运行数据
  （详见 `docs/openclaw.md`）。

> 恢复顺序建议：先 `openclaw.env` → `openclaw.tar.gz`，再服务数据（OmniRoute /
> zcode / zcode2api / rsstt）。这样即使大包恢复失败，聊天入口也能先起来。

---

## 六、仓库设置与首次运行

1. **Actions 权限**：Settings → Actions → General：
   - 允许 Actions；
   - Workflow permissions 选 **Read and write**（`openclaw.yml` 需要 `actions: write`
     来触发下一轮 run）；
   - 如使用组织仓库，确认组织级 Actions 策略未禁用。
2. **Variables**：确认 `OPENCLAW_HANDOFF=1`（启用 warm-standby 交接）、
   `CFIP_GIST_ID` 已恢复。
3. **首次手动触发**：

   ```bash
   gh workflow run openclaw.yml --repo <new-owner>/<new-repo>
   ```

4. **验证清单**：
   - [ ] `Install OpenClaw` 成功，`~/.openclaw/openclaw.json` 存在；
   - [ ] `Run OpenClaw` 后 `http://127.0.0.1:18789/health` 返回 200；
   - [ ] Tailscale 入口 `ssh runner@openclaw` 可连；
   - [ ] Telegram 收到「OpenClaw 已就绪」通知；
   - [ ] `actions-archive.yml` 手动跑一次，能生成并上传 `actions.tar.gz`（含最新 Secrets）；
   - [ ] `Trigger next OpenClaw run` 能触发下一轮（说明 `actions: write` 生效）。

---

## 七、其他工作流

仓库内各工作流依赖的 Secrets 如下（供迁移后逐项核对）：

| 工作流 | 依赖 Secrets |
|---|---|
| `HomeAssistant.yml` | `RCLONE` `TELEGRAM_BOT_TOKEN` `TELEGRAM_BOT_TOKEN_ALERT` `TELEGRAM_CHAT_ID` `TELEGRAM_CHAT_ID_ALERT` `VD` |
| `cfip-pool.yml` | `PAT` `TS_OAUTH_CLIENT_ID` `TS_OAUTH_CLIENT_SECRET` |
| `delete-workflow-runs.yml` | `PAT` |
| `emby.yml` | `EMBY_API_TOKEN` `EMBY_USER` `OPENLIST_ADMIN_PASSWORD` `RCLONE` `TELEGRAM_*` `VD` |
| `github_backup_all.yml` | `PAT` `RCLONE` `TELEGRAM_*` |
| `icloud-photos-downloader.yml` | `APPLEID` `APPLEPASSWORD` `RCLONE` `TELEGRAM_*` |
| `jellyfin.yml` | `JELLYFIN_API_TOKEN` `PAT` `RCLONE` `TELEGRAM_*` `VD` |
| `notion-backup.yml` | `RCLONE` `TELEGRAM_*` |
| `openclaw.yml` | `AI_GATEWAY_API_KEY` `AUTOCLAW_GATEWAY_KEY` `GLM2API_GATEWAY_KEY` `GLM_REFRESH_TOKEN` `RCLONE` `TELEGRAM_*` `TS_*` `VD` `ZCODE_GATEWAY_API_KEY` |
| `openlist*.yml` | `OPENLIST_ADMIN_PASSWORD` `RCLONE` `TELEGRAM_*`（`openlist.yml` 另需 `OPENCLAW_HOOK_*`） |
| `p.yml` | `PAT` `RCLONE` `TELEGRAM_*` `VAULTWARDEN` `VD` |
| `ph-dl.yml` | `PORNHUBNAME` `RCLONE` `TELEGRAM_*` `TELEGRAM_CHANNEL_ID_PH` `TG_API_HASH` `TG_API_ID` `TG_SESSION` |
| `pixivutil2.yml` | `RCLONE` `TELEGRAM_*` |
| `proxy-speedtest-*.yml` | `PAT` `PROXY_SPEEDTEST_*` `GITEE_PRIVATE_TOKEN` `TELEGRAM_*`（`gistnodes` 另需 `X`） |
| `ql.yml` | `PAT` `RCLONE` `TELEGRAM_*` `VD` |
| `rdp.yml` | `NGROK_AUTH_TOKEN` `RDP_PASSWORD` `TELEGRAM_*` |
| `self-hosted_backup.yml` | `RCLONE` `TELEGRAM_*` |
| `socks-exit-pool.yml` | `PAT` `SOCKS_EXIT_GIST_ID` `SUBS_CHECK_GIST_ID` |
| `sub-store.yml` | `RCLONE` `SUB_STORE_FRONTEND_BACKEND_PATH` `TELEGRAM_*` `VD` |
| `subs-check.yml` | `RCLONE` `VD` |
| `tailscale-windows.yml` | `RUNNER_PASSWORD` `TELEGRAM_*` `TS_*` |
| `teslamate.yml` | `RCLONE` `TELEGRAM_*` `VD` |
| `upload-video-to-tg.yml` | `RCLONE` `TELEGRAM_*` `TG_API_HASH` `TG_API_ID` `TG_SESSION` |

> `TELEGRAM_*` 指 `TELEGRAM_BOT_TOKEN`、`TELEGRAM_BOT_TOKEN_ALERT`、
> `TELEGRAM_CHAT_ID`、`TELEGRAM_CHAT_ID_ALERT`（按工作流实际引用为准）。

---

## 八、安全与收尾

1. **Dropbox 是可信存储（主人拍板）**：`actions.tar.gz` 长期保存在
   `dropbox:self-hosted/actions.tar.gz` 即可，不需要额外加密或迁移后立即删除。
2. **轮换 Secrets**：迁移完成后建议在旧账号/新账号均重新生成 token、bot token、
   OAuth 凭据、rclone 配置等，再更新新仓库（降低历史泄露面，非本次归档的前置条件）。
3. **撤销旧授权**：旧账号的 PAT、Tailscale OAuth client、Cloudflare 证书、
   Telegram bot token 全部吊销或轮换。
4. **只保留一套调度**：确认旧仓库 Actions 已禁用，避免两套环境同时运行。
5. **不得把该包带进其他通道**：不要提交进 Git 仓库、不要上传为 Actions artifact、
   不要发到 Telegram/邮件等聊天通道；唯一去向就是 Dropbox。
6. **合规提醒**：迁移和使用 GitHub Actions 需遵守 GitHub Terms of Service；
   不要用新账号规避平台处罚或继续被禁止的用途。

---

## 九、故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `git push --mirror` 403 | PAT 缺 `repo`/`workflow` 权限 | 重新签发 PAT，确认目标仓库 admin |
| `gh secret set` 403 | 组织仓库缺 `admin:org` | 用组织 owner 账号或仓库 admin PAT |
| 工作流启动即失败 `secrets.X` 为空 | Secret 未恢复或在 `UNCAPTURED.txt` 中 | 补齐后重跑 |
| `openclaw.tar.gz` 恢复失败 | Dropbox 路径不对/包损坏 | 校验 `MANIFEST.sha256`，重放归档 |
| 两套环境互相覆盖归档 | 旧仓库调度未停 | 立即禁用旧仓库 `openclaw.yml` schedule |
| Tailscale 主机名冲突 | 旧节点未退出 | 等 ephemeral 节点过期或在管理台删除 |

---

## 十、最小迁移检查表

- [ ] 旧仓库 Actions 已禁用
- [ ] 新仓库代码已 `push --mirror`（分支/标签/历史完整）
- [ ] Secrets 已写入并核对 `index.tsv`
- [ ] `UNCAPTURED.txt` 已处理（无遗漏）
- [ ] Variables 已恢复（`OPENCLAW_HANDOFF=1`、`CFIP_GIST_ID`）
- [ ] Dropbox `self-hosted/` 归档已就位
- [ ] `.cloudflared` 证书、`rclone.conf`、workbuddy 凭据已就位
- [ ] `openclaw.yml` 首轮运行成功、`/health` 200
- [ ] Telegram 通知与 Tailscale SSH 入口验证通过
- [ ] 全部 Secrets 已轮换（建议，非阻塞项）
- [ ] 确认 `actions.tar.gz` 仅存在于 Dropbox，未进入 Git / artifact / 聊天通道