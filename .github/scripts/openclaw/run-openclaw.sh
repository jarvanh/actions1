#!/usr/bin/env bash
# openclaw 工作流「Run OpenClaw」步骤本体（2026-10-30 原样搬移自 yml，零逻辑改动）。
# 外置背景：workflow 文件 2026-10-29（f08b15f）起突破 GitHub workflow 500KB
#（=512,000 字节）上限，每轮 push 全部 "workflow file issue" 零 job 失败、
# schedule 停摆 —— 按 .github/scripts/services/ 同款模式给 yml 减重。
# 消费方：/tmp/run-openclaw-step.log（失败通知取摘要）、/tmp/run-openclaw-meta.env。
# yml 薄包装保留 id=run_openclaw 与 if 条件；脚本非零退出即步骤失败。
# 2026-11-27 修复：首启等待健康时显式回收陈旧 gateway state lock。
# OpenClaw 跨 PID namespace 无法证明旧 holder 已停，只按心跳老化不会自动回收，
# 新进程会空等 95s 才放弃，18789 超时；恢复入口要求 --confirm 本轮指纹，
# 只处理 recover-lock 自己判定为 unchanged 的 owner，绝不误伤活网关。

set -euo pipefail

RUN_OPENCLAW_STEP_LOG="/tmp/run-openclaw-step.log"
RUN_OPENCLAW_META="/tmp/run-openclaw-meta.env"
: > "$RUN_OPENCLAW_STEP_LOG"
: > "$RUN_OPENCLAW_META"
exec > >(tee -a "$RUN_OPENCLAW_STEP_LOG") 2>&1

# 宿主机资源参数（swap 容量 / vm.swappiness）在网关起来前收敛。
# 放在 install/start 之前：swap 必须在内存尖峰之前就位，否则网关一启动就可能
# 撞上 3G swap 被占满的老形态（2026-11-05：swap 打满 + SQLite 37s 停顿）。
# 非致命：脚本自身保证 exit 0，这里再兜一层，绝不因调优失败阻断 gateway。
if [ -f "$(dirname "$0")/host-tuning.sh" ]; then
  bash "$(dirname "$0")/host-tuning.sh" || echo "⚠️ host-tuning.sh 执行失败（非致命，继续启动）"
fi

CURRENT_OPENCLAW_VERSION="$(openclaw --version 2>/dev/null | head -n 1 || true)"
CURRENT_OPENCLAW_SEMVER="$(printf '%s\n' "$CURRENT_OPENCLAW_VERSION" | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n 1 || true)"
KNOWN_GOOD_VERSION_FILE="$HOME/.openclaw/openclaw-known-good-version"
echo "CURRENT_OPENCLAW_VERSION=$CURRENT_OPENCLAW_VERSION" >> "$RUN_OPENCLAW_META"
echo "CURRENT_OPENCLAW_SEMVER=$CURRENT_OPENCLAW_SEMVER" >> "$RUN_OPENCLAW_META"
echo "FAIL_STAGE=preflight_doctor" >> "$RUN_OPENCLAW_META"
PREFLIGHT_BEGIN_TS=$(date +%s)

fail_startup() {
  local msg="$1"
  echo "❌ $msg"
  exit 1
}

normalize_openclaw_version() {
  printf '%s\n' "${1:-}" | tr -d '[:space:]' | grep -oE '^[0-9]{4}\.[0-9]+\.[0-9]+$' || true
}

read_openclaw_version_file() {
  local file="$1"
  if [ -s "$file" ]; then
    normalize_openclaw_version "$(head -n 1 "$file" 2>/dev/null || true)"
  fi
}

# 版本历史（2026-11-28）：known-good 不再只存一行裸版本。
# 背景：一次 build 失败的 fallback 选中版本 == 当前失败版本（都是 2026.11.10），
# 于是「回退」变成把同一份有 pid-namespace 锁缺陷的 CLI 重装一遍，必然再次失败。
# 现在记录 version + pid-ns 指纹 + 时间，本地保留最近 N 条，并同步一份到 Dropbox；
# 回退时优先取 Dropbox 历史里「不等于当前失败版本」的最新一条。
OPENCLAW_VERSION_HISTORY_MAX="${OPENCLAW_VERSION_HISTORY_MAX:-5}"
OPENCLAW_VERSION_HISTORY_REMOTE="${OPENCLAW_VERSION_HISTORY_REMOTE:-dropbox:self-hosted/openclaw-known-good-versions.txt}"

record_successful_openclaw_version() {
  local version="$1" pidns ts
  version="$(normalize_openclaw_version "$version")"
  if [ -z "$version" ]; then
    echo "⚠️ Cannot record successful OpenClaw version: current version is empty or invalid."
    return 0
  fi
  mkdir -p "$HOME/.openclaw"
  pidns="$(readlink /proc/1/ns/pid 2>/dev/null || echo unknown)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # 去重口径：同一 version 只保留最新一条（tac → 取首次出现 → 还原顺序）
  {
    [ -s "$KNOWN_GOOD_VERSION_FILE" ] && cat "$KNOWN_GOOD_VERSION_FILE"
    printf '%s\tpidns=%s\t%s\n' "$version" "$pidns" "$ts"
  } | tac | awk -F'\t' 'NF && !seen[$1]++' | tac | tail -n "$OPENCLAW_VERSION_HISTORY_MAX" > "$KNOWN_GOOD_VERSION_FILE.tmp"
  mv "$KNOWN_GOOD_VERSION_FILE.tmp" "$KNOWN_GOOD_VERSION_FILE"
  echo "RECORDED_SUCCESSFUL_OPENCLAW_VERSION=$version" >> "$RUN_OPENCLAW_META"
  echo "✅ Recorded successful OpenClaw version: $version (pidns=$pidns)"
  # Dropbox 备份一份，供「本机被回收 / 本地文件丢失」时回退使用；失败不阻断
  if command -v rclone >/dev/null 2>&1; then
    if rclone copyto "$KNOWN_GOOD_VERSION_FILE" "$OPENCLAW_VERSION_HISTORY_REMOTE" >/dev/null 2>&1; then
      echo "☁️ Version history synced: $OPENCLAW_VERSION_HISTORY_REMOTE"
    else
      echo "⚠️ Version history sync failed (non-fatal): $OPENCLAW_VERSION_HISTORY_REMOTE"
    fi
  fi
}

# 兼容旧格式（一行裸版本）：只取第一列，忽略 2026-11-28 起新增的指纹列
read_openclaw_version_file() {
  local file="$1"
  if [ -s "$file" ]; then
    normalize_openclaw_version "$(tail -n 1 "$file" 2>/dev/null | cut -f1 || true)"
  fi
}

# 按「新 → 旧」列出文件里所有可解析版本（每行一条，已去重）
list_known_versions() {
  local file="$1"
  [ -s "$file" ] || return 0
  tac "$file" 2>/dev/null | while IFS=$'\t' read -r v _rest; do
    normalize_openclaw_version "$v"
  done
}

fetch_dropbox_version_history() {
  local out="$1"
  command -v rclone >/dev/null 2>&1 || return 1
  rclone cat "$OPENCLAW_VERSION_HISTORY_REMOTE" > "$out" 2>/dev/null || return 1
  [ -s "$out" ]
}

resolve_fallback_openclaw_version() {
  local version="" hist
  hist="$(mktemp)"

  # ① 首选：Dropbox 备份的历史版本（最新一条且不等于当前失败版本）
  if fetch_dropbox_version_history "$hist"; then
    while IFS= read -r version; do
      if [ -n "$version" ] && [ "$version" != "$CURRENT_OPENCLAW_SEMVER" ]; then
        echo "FALLBACK_VERSION_SOURCE=dropbox_history" >> "$RUN_OPENCLAW_META"
        rm -f "$hist"
        echo "$version"
        return 0
      fi
    done < <(list_known_versions "$hist")
  fi

  # ② 次选：本地版本历史（同样跳过当前失败版本）
  while IFS= read -r version; do
    if [ -n "$version" ] && [ "$version" != "$CURRENT_OPENCLAW_SEMVER" ]; then
      echo "FALLBACK_VERSION_SOURCE=known_good_history" >> "$RUN_OPENCLAW_META"
      rm -f "$hist"
      echo "$version"
      return 0
    fi
  done < <(list_known_versions "$KNOWN_GOOD_VERSION_FILE")
  rm -f "$hist"

  # ③ 兜底：配置里记录的 lastTouchedVersion（跳过当前失败版本）
  if [ -s "$HOME/.openclaw/openclaw.json" ]; then
    version="$(jq -r '.meta.lastTouchedVersion // empty' "$HOME/.openclaw/openclaw.json" 2>/dev/null | head -n 1 || true)"
    version="$(normalize_openclaw_version "$version")"
    if [ -n "$version" ] && [ "$version" != "$CURRENT_OPENCLAW_SEMVER" ]; then
      echo "FALLBACK_VERSION_SOURCE=meta_lastTouchedVersion" >> "$RUN_OPENCLAW_META"
      echo "$version"
      return 0
    fi
  fi

  echo ""
  return 1
}

fix_openclaw_permissions() {
  echo "🔧 Fixing file permissions to pass security checks..."
  sudo chmod -R o-w "$(npm root -g)"
  chmod 700 ~/.openclaw
  if [ -f ~/.openclaw/openclaw.json ]; then
    chmod 600 ~/.openclaw/openclaw.json
  fi
}

# OpenClaw 的 agent exec 隔离要求 gateway service cgroup 暴露 cpu/io/memory 控制器。
# GitHub hosted runner 的 user.slice 默认只向下委托 cpu/memory/pids，io 被挡在
# user.slice 一层 → gateway 每次 exec 都告警并退化为共享内存保护。这里从 user.slice
# 逐级打开 +io（root 权限），让新起的 gateway service 直接拿到控制器；非 cgroup v2
# 或无 sudo 的环境静默跳过，绝不阻断启动。
ensure_gateway_cgroup_controllers() {
  local uid base um p
  uid="$(id -u)"
  base="/sys/fs/cgroup/user.slice"
  um="$base/user-${uid}.slice/user@${uid}.service"
  for p in "$base" "$base/user-${uid}.slice" "$um" "$um/app.slice"; do
    [ -d "$p" ] || continue
    grep -qw io "$p/cgroup.subtree_control" 2>/dev/null && continue
    echo '+io' | sudo tee "$p/cgroup.subtree_control" >/dev/null 2>&1 || true
  done
}

# apple-design 的 SKILL.md 曾带两个 description 键（第一个为空），OpenClaw 会整份跳过。
# 只删第一个空的 description 行，修好后不再匹配；数据修正随主包归档延续。
repair_known_skill_frontmatter() {
  local f="$HOME/.openclaw/workspace/skills/apple-design/SKILL.md"
  [ -f "$f" ] || return 0
  if grep -qx 'description: >' "$f"; then
    awk 'BEGIN{done=0} { if (!done && $0=="description: >") { done=1; next } print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "🔧 Repaired duplicate description key in apple-design skill"
  fi
}

openclaw_port_listening() {
  sudo lsof -Pi :18789 -sTCP:LISTEN -t >/dev/null
}

openclaw_log_ready() {
  journalctl --user -u openclaw-gateway.service --since "5 minutes ago" --no-pager 2>/dev/null \
    | grep -q "\[gateway\] ready"
}

openclaw_health_http_ok() {
  [ "$(curl -fsS -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 15 http://127.0.0.1:18789/health || true)" = "200" ]
}

# 陈旧 gateway state lock 自愈：OpenClaw 2026.11.10 在跨 PID namespace 时无法证明
# 旧 holder 已停，心跳再老也不会自动回收；新 gateway 会先空等 95s 才放弃监听。
# recover-lock 的 --confirm 只接受本轮检查生成的 unchanged-owner 指纹；再叠加
# 心跳至少 300s 的门限，避免把另一 namespace 刚启动、端口尚未绑定的活网关误判成僵尸。
# 仅在「端口未监听 + 日志出现锁等待」时试一次。
heal_stale_gateway_lock() {
  local label="$1"

  # 端口已在听就是有活网关，任何状态下都不碰锁。
  if openclaw_port_listening || openclaw_health_http_ok; then
    return 0
  fi
  journalctl --user -u openclaw-gateway.service --since "3 minutes ago" --no-pager 2>/dev/null \
    | grep -qE 'cannot verify Gateway ownership|previous Gateway to release state|GatewayLockNamespaceError' || return 0

  echo "🔓 Detected unverifiable/stale gateway state lock (${label}); inspecting for explicit recovery..."
  local inspection confirm_line confirm_fp max_age=0 age
  inspection="$(openclaw gateway recover-lock --json 2>&1 || true)"
  confirm_line="$(printf '%s\n' "$inspection" | grep -m1 '"confirmation"' || true)"
  confirm_fp="$(printf '%s\n' "$confirm_line" | sed -E 's/.*"confirmation"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  # 指纹只保证「检查后记录未变」；还必须真的老旧才动锁。心跳新鲜时绝不回收，
  # 避免把另一 namespace 里刚启动、端口尚未绑定的活网关误判成僵尸。
  while IFS= read -r age; do
    [ -n "$age" ] || continue
    [ "$age" -gt "$max_age" ] && max_age="$age"
  done < <(printf '%s\n' "$inspection" | grep -oE 'last renewed [0-9]+ s ago' | awk '{print $3}' || true)
  if [ "$max_age" -lt 300 ]; then
    echo "⏭️ Lock heartbeat is fresh (${max_age}s); not recovering."
    return 0
  fi
  if [ -z "$confirm_fp" ] || ! printf '%s\n' "$confirm_fp" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "⏭️ No unchanged-owner confirmation fingerprint; lock is live/verified or inspection unavailable."
    return 0
  fi

  echo "🧹 Recovering unchanged gateway owner lock with confirmation ${confirm_fp:0:12}..."
  if openclaw gateway recover-lock --confirm "$confirm_fp"; then
    echo "✅ Gateway state lock recovered; restarting gateway so it retries admission immediately."
    echo "STALE_GATEWAY_LOCK_RECOVERED=1" >> "$RUN_OPENCLAW_META"
    # 恢复只清锁记录；进程可能仍停在 95s 等待中，必须重启才能立刻重走准入。
    systemctl --user reset-failed openclaw-gateway.service 2>/dev/null || true
    systemctl --user restart openclaw-gateway.service 2>/dev/null || true
    return 0
  fi
  echo "⚠️ Gateway state lock recovery failed; keep the original failure path for diagnostics."
  return 0
}

wait_for_openclaw_health() {
  local label="$1"
  local timeout_sec="${2:-180}"
  local interval_sec="${3:-5}"
  local start_ts now_ts elapsed
  local _lock_healed_at=0
  start_ts=$(date +%s)

  echo "Waiting for OpenClaw health (${label}, timeout=${timeout_sec}s)..."
  while true; do
    now_ts=$(date +%s)
    elapsed=$((now_ts - start_ts))

    if openclaw_port_listening; then
      if openclaw_health_http_ok; then
        echo "✅ OpenClaw Gateway health is OK after ${elapsed}s (${label})."
        return 0
      fi

      if openclaw_log_ready; then
        echo "⏳ Gateway is listening and logged ready, but /health is still slow after ${elapsed}s (${label}); continuing grace wait."
      else
        echo "⏳ Gateway port is listening, waiting for ready/health... ${elapsed}/${timeout_sec}s (${label})"
      fi
    else
      echo "⏳ Gateway port is not listening yet... ${elapsed}/${timeout_sec}s (${label})"
      # 锁等待只会拖延首启，不会让端口自己 listen；在等待窗口前半段显式恢复一次。
      if [ "$_lock_healed_at" = 0 ] && [ "$elapsed" -ge 5 ] && [ "$elapsed" -lt $((timeout_sec / 2)) ]; then
        heal_stale_gateway_lock "$label"
        _lock_healed_at=1
      fi
    fi

    if [ "$elapsed" -ge "$timeout_sec" ]; then
      echo "❌ OpenClaw Gateway health did not become OK within ${timeout_sec}s (${label})."
      return 1
    fi
    sleep "$interval_sec"
  done
}

dump_openclaw_diagnostics() {
  echo "⚠️ Gateway not healthy yet. Diagnostics:"
  echo "--- systemd status ---"
  systemctl --user --no-pager --full status openclaw-gateway.service || true
  echo "--- recent journal ---"
  journalctl --user -u openclaw-gateway.service --since "10 minutes ago" --no-pager | tail -n 120 || true
  echo "--- /tmp/openclaw logs ---"
  find /tmp/openclaw -maxdepth 1 -type f -name 'openclaw-*.log' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | head -2 \
    | cut -d' ' -f2- \
    | while IFS= read -r log_file; do
        echo "--- tail $log_file ---"
        tail -n 80 "$log_file" || true
      done
}

fix_openclaw_permissions
ensure_gateway_cgroup_controllers
repair_known_skill_frontmatter

echo "FAIL_STAGE=config_validate" >> "$RUN_OPENCLAW_META"
echo "🧪 Preflight config validation for $CURRENT_OPENCLAW_VERSION ..."
CONFIG_VALID_FOR_CURRENT=0
DOCTOR_RAN=0
if openclaw config validate >/tmp/config-validate.log 2>&1; then
  CONFIG_VALID_FOR_CURRENT=1
  echo "✅ Config valid for current version."
else
  echo "⚠️ Config invalid for current version. Trying 'openclaw doctor --fix' to repair, then re-validating. Details:"
  tail -n 15 /tmp/config-validate.log 2>/dev/null || true
  echo "🛠️ Running 'openclaw doctor --fix' to repair the config..."
  DOCTOR_RAN=1
  openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"
  if openclaw config validate >/tmp/config-validate-2.log 2>&1; then
    CONFIG_VALID_FOR_CURRENT=1
    echo "✅ Config repaired by doctor; now valid for current version."
  else
    echo "❌ Config still invalid after doctor. Gateway start will be skipped; fallback reinstall, downgrade guard and snapshot rollback handle recovery. Details:"
    tail -n 10 /tmp/config-validate-2.log 2>/dev/null || true
  fi
fi

if [ "$CONFIG_VALID_FOR_CURRENT" = "1" ] && [ "$DOCTOR_RAN" != "1" ]; then
  # 优化（2026-10-02）：config 已校验通过时，preflight doctor 只在 OpenClaw
  # **版本变化**时才跑。实测该步固定耗时 79s，而配置合法时 doctor 并无
  # 修复动作（日志仅 warnings + registry 刷新 + agent-db 完整性检查）。
  # 版本未变 ⇒ 跳过（省 79s）；版本一变 ⇒ 照跑，保住升级时的自愈。
  # 状态文件放在 ~/.openclaw 内：它随主包归档/恢复，上轮记录得以延续。
  # 版本解析失败时（CURRENT_OPENCLAW_SEMVER 为空）一律照跑 —— 保守。
  DOCTOR_STATE_FILE="$HOME/.openclaw/openclaw-doctor-last-version"
  LAST_DOCTOR_VERSION="$(head -n 1 "$DOCTOR_STATE_FILE" 2>/dev/null || true)"
  if [ -n "$CURRENT_OPENCLAW_SEMVER" ] && [ "$LAST_DOCTOR_VERSION" = "$CURRENT_OPENCLAW_SEMVER" ]; then
    echo "⏭️ Skipping preflight doctor: config valid & version unchanged (${CURRENT_OPENCLAW_SEMVER})"
  else
    echo "🛠️ Running preflight 'openclaw doctor --fix' before gateway restart... (${LAST_DOCTOR_VERSION:-none} → ${CURRENT_OPENCLAW_SEMVER})"
    openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"
    mkdir -p "$HOME/.openclaw"
    printf '%s\n' "$CURRENT_OPENCLAW_SEMVER" > "$DOCTOR_STATE_FILE"
  fi
fi
PREFLIGHT_END_TS=$(date +%s)
echo "PREFLIGHT_DOCTOR_DURATION_SEC=$((PREFLIGHT_END_TS - PREFLIGHT_BEGIN_TS))" >> "$RUN_OPENCLAW_META"

echo "FAIL_STAGE=initial_start" >> "$RUN_OPENCLAW_META"
INITIAL_START_BEGIN_TS=$(date +%s)
echo "Restarting OpenClaw gateway..."

# 2026-10-22 冷启动优化（run 39637798065 日志实证）：unit 由 CLI 生成时带
# TimeoutStopSec=330，而 `gateway install --force` 已经把服务拉起来了；
# 紧接着再 `gateway restart` 会走一遍完整 stop→start —— 首启进程还在 boot、
# 不响应 SIGTERM，systemd 就陪它等到 330s 才 SIGKILL。日志里
# 16:59:47 "Gateway service installed" → 17:05:23 "Restarted systemd service"
# 的 336s 静默正是它（冷启动根本没有「旧进程」要停）。
# 对策两层：① drop-in 保持 openclaw 要求的 TimeoutStopSec=330（install 重写主
#    unit 不影响 .d 覆盖）；② 冷启动不再调 CLI restart：install 已拉起就直接等
#    健康，unit 未激活才显式 start。② 生效后冷启动不会再出现 330s 的 stop 等待。
GW_UNIT="openclaw-gateway.service"
GW_DROPIN_DIR="$HOME/.config/systemd/user/${GW_UNIT}.d"
# 2026-10-22 修复（run 5507 日志+本机复现实证）：drop-in 必须在 install
# **之后**落盘。install 的发布事务会快照受管工件（unit/generated/service.d
# 系目录）并在发布间隙做严格指纹比对（systemd-definition-mutation:248），
# 事务开始前已存在的 drop-in 目录会被判「工件被外部改动」→ 中止 + 回滚
# 删 unit，该机后续 install 全部连带失败。EE6A3D5 起的正确顺序是 install
# 成功后再补 drop-in（TimeoutStopSec 对下一次 stop 依然生效，无损失）。
# 防御：若上一轮残留了 drop-in（如 10-22 失败轮），先摘除再装；
# 装完后由 apply_gw_dropin 统一重写（不依赖旧目录）。
GW_DROPIN_BACKUP=""
if [ -d "$GW_DROPIN_DIR" ]; then
  GW_DROPIN_BACKUP="${GW_DROPIN_DIR}.pre-install.$$.$(date +%s%N)"
  mv "$GW_DROPIN_DIR" "$GW_DROPIN_BACKUP" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
fi

# install 成功后落盘 drop-in：目录 755 / 文件 644（install 的安全门会拒绝
# group/world-writable 的定义文件 —— run 5507 当晚本机复现的第二道坎）。
# 先回放上方摘除时侧移的运营者 drop-in（memory.conf / 20-*.conf 等），再写
# 托管项，避免每轮供应把运营者覆盖清空。
apply_gw_dropin() {
  mkdir -p "$GW_DROPIN_DIR"
  chmod 755 "$GW_DROPIN_DIR"
  if [ -n "${GW_DROPIN_BACKUP:-}" ] && [ -d "$GW_DROPIN_BACKUP" ]; then
    for _f in "$GW_DROPIN_BACKUP"/*.conf; do
      [ -e "$_f" ] || continue
      if [ "$(basename "$_f")" = "10-stop-timeout.conf" ]; then
        continue
      fi
      cp -p "$_f" "$GW_DROPIN_DIR/" 2>/dev/null || true
    done
    rm -rf "$GW_DROPIN_BACKUP"
  fi
  # L4 内存护栏（2026-10-21 16:50 事故 10G peak）：仅在缺失时创建，
  # 已存在的运营者配置由上方回放保留，不覆盖。
  # 2026-11-05：补 MemorySwapMax —— swap 扩到 25G 后，若无上限，单靠
  # MemoryHigh/Max 无法阻止网关一个进程吃掉大部分 swap（实测曾占 1.17G/3G）。
  if [ ! -f "$GW_DROPIN_DIR/memory.conf" ]; then
    cat > "$GW_DROPIN_DIR/memory.conf" <<'EOF_MEM'
[Service]
MemoryHigh=9G
MemoryMax=11G
MemorySwapMax=4G
EOF_MEM
    chmod 644 "$GW_DROPIN_DIR/memory.conf"
  fi
  GW_NODE_BIN_DIR="$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/node)")"
  GW_SERVICE_PATH="$HOME/.bun/bin:$GW_NODE_BIN_DIR:/usr/local/bin:/usr/bin:/bin:$HOME/.nvm/current/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/bin:$HOME/.nix-profile/bin"
  cat > "$GW_DROPIN_DIR/10-stop-timeout.conf" <<EOF_STOP
[Service]
Environment=PATH=$GW_SERVICE_PATH
TimeoutStopSec=330
EOF_STOP
  chmod 644 "$GW_DROPIN_DIR/10-stop-timeout.conf"
  rm -rf "${GW_DROPIN_DIR}".pre-install.* 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
}

# 2026-10-24: install 生成 unit 时按目录是否存在决定是否收录 ~/.bun/bin
# （version-manager 黑名单不含 bun）。先建目录，让首启进程的 PATH 就包含 bun；
# bun 本体由后续 zcode2api 步骤装进同一目录，PATH 在 spawn 时查找。
mkdir -p "$HOME/.bun/bin"
INITIAL_START_RESTART_OK=1
if [ "$CONFIG_VALID_FOR_CURRENT" != "1" ]; then
  echo "⚠️ Skipping gateway start: config still invalid after doctor. Going straight to fallback reinstall with the recorded compatible version."
  INITIAL_START_RESTART_OK=0
elif ! openclaw gateway install --force; then
  echo "⚠️ Initial gateway install failed; will attempt fallback reinstall."
  INITIAL_START_RESTART_OK=0
else
  if [ "$(systemctl --user is-active "$GW_UNIT" 2>/dev/null || echo inactive)" = "active" ]; then
    echo "⏭️ unit 已由 install --force 拉起，跳过 gateway restart，直接等健康（冷启动快路径）"
  else
    echo "ℹ️ unit 未激活，systemctl --user start 拉起（不走 CLI restart）"
    systemctl --user reset-failed "$GW_UNIT" 2>/dev/null || true
    systemctl --user start "$GW_UNIT" 2>/dev/null || echo "⚠️ systemctl start 返回非零，交给健康检查判定"
  fi
  # drop-in 在 install 之后落盘（原因见上）：此刻 unit 已在盘上、服务已拉起，
  # 等健康前补齐 PATH 与 TimeoutStopSec=330（对下一次 stop 生效）
  apply_gw_dropin
  echo "COLD_START_SKIP_RESTART=1" >> "$RUN_OPENCLAW_META"
fi

if [ "$INITIAL_START_RESTART_OK" = "1" ] && wait_for_openclaw_health "initial_start" 180 5; then
    INITIAL_START_END_TS=$(date +%s)
    echo "INITIAL_START_DURATION_SEC=$((INITIAL_START_END_TS - INITIAL_START_BEGIN_TS))" >> "$RUN_OPENCLAW_META"
    record_successful_openclaw_version "$CURRENT_OPENCLAW_SEMVER"
    echo "✅ OpenClaw Gateway is healthy!"
else
    INITIAL_START_END_TS=$(date +%s)
    echo "INITIAL_START_DURATION_SEC=$((INITIAL_START_END_TS - INITIAL_START_BEGIN_TS))" >> "$RUN_OPENCLAW_META"
    dump_openclaw_diagnostics

    echo "FAIL_STAGE=fallback_reinstall" >> "$RUN_OPENCLAW_META"
    echo "🔄 Initial start failed after preflight doctor. Attempting to fallback and reinstall recorded OpenClaw version..."

    TARGET_VERSION="$(resolve_fallback_openclaw_version || true)"
    if [ -z "$TARGET_VERSION" ]; then
      fail_startup "No fallback OpenClaw version found. Checked $KNOWN_GOOD_VERSION_FILE and .meta.lastTouchedVersion."
    fi
    echo "✅ Selected fallback OpenClaw version: $TARGET_VERSION"

    echo "Installing openclaw@$TARGET_VERSION ..."
    echo "FALLBACK_TARGET_VERSION=$TARGET_VERSION" >> "$RUN_OPENCLAW_META"
    FALLBACK_REINSTALL_BEGIN_TS=$(date +%s)
    npm i -g "openclaw@$TARGET_VERSION"

    fix_openclaw_permissions

    echo "🧪 Validating config against fallback openclaw@$TARGET_VERSION ..."
    if openclaw config validate >/tmp/config-validate-fallback.log 2>&1; then
      echo "✅ Config valid for fallback version."
    else
      echo "⚠️ Config invalid for fallback version. Trying 'openclaw doctor --fix' first. Details:"
      tail -n 10 /tmp/config-validate-fallback.log 2>/dev/null || true
      openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"
      if openclaw config validate >/tmp/config-validate-fallback-2.log 2>&1; then
        echo "✅ Config repaired by doctor for fallback version."
      else
        DOWNGRADE_TS="$(date +%Y%m%d-%H%M%S)"
        echo "❌ Config still invalid for fallback version after doctor. Moving the current state aside so the fallback version starts clean (kept as *.state-bak-$DOWNGRADE_TS; sessions will be lost, upgrade back to recover). Details:"
        tail -n 10 /tmp/config-validate-fallback-2.log 2>/dev/null || true
        for STATE_DB in "$HOME/.openclaw/state/openclaw.sqlite" "$HOME/.openclaw/state/openclaw.sqlite-wal" "$HOME/.openclaw/state/openclaw.sqlite-shm"; do
          if [ -f "$STATE_DB" ]; then
            mv "$STATE_DB" "$STATE_DB.state-bak-$DOWNGRADE_TS" && echo "➡️ Moved aside: $STATE_DB"
          fi
        done
        echo "🛠️ Running 'openclaw doctor --fix' on the clean state..."
        openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"
      fi
    fi

    echo "Restarting OpenClaw after fallback reinstall..."
    FALLBACK_RESTART_OK=1
    # 2026-10-03 事故：降级后的启动崩溃循环会烧光 systemd StartLimitBurst
    # （10 次/300s），此后 restart 恒报 "Start request repeated too quickly"，
    # 自愈还没开始就被熔断锁死。restart 前先清 failed 计数。
    systemctl --user reset-failed openclaw-gateway.service 2>/dev/null || true
    if [ -d "$GW_DROPIN_DIR" ]; then
      GW_DROPIN_BACKUP="${GW_DROPIN_DIR}.pre-install.$$.$(date +%s%N)"
      mv "$GW_DROPIN_DIR" "$GW_DROPIN_BACKUP" 2>/dev/null || true
      # 与初始路径（apply_gw_dropin 前）保持一致：drop-in 已从磁盘移除，
      # 不 daemon-reload 的话 systemd 仍持有旧定义，gateway install --force 会报
      # SERVICE_DEFINITION_UNKNOWN(cannot be safely inspected) 而整轮失败。
      systemctl --user daemon-reload 2>/dev/null || true
    fi
    mkdir -p "$HOME/.bun/bin"
    if ! openclaw gateway install --force; then
      echo "⚠️ Fallback gateway install failed."
      FALLBACK_RESTART_OK=0
    elif ! openclaw gateway restart; then
      echo "⚠️ Fallback gateway restart failed."
      FALLBACK_RESTART_OK=0
    fi

    if [ "$FALLBACK_RESTART_OK" = "1" ]; then
      # 回退重装的 install 同样要求无 drop-in 现场；成功后先回放再等健康
      apply_gw_dropin
    fi
    if [ "$FALLBACK_RESTART_OK" = "1" ] && wait_for_openclaw_health "fallback_reinstall" 180 5; then
      FALLBACK_REINSTALL_END_TS=$(date +%s)
      echo "FALLBACK_REINSTALL_DURATION_SEC=$((FALLBACK_REINSTALL_END_TS - FALLBACK_REINSTALL_BEGIN_TS))" >> "$RUN_OPENCLAW_META"
      record_successful_openclaw_version "$TARGET_VERSION"
      echo "✅ OpenClaw Gateway is healthy after fallback reinstall!"
    else
      FALLBACK_REINSTALL_END_TS=$(date +%s)
      echo "FALLBACK_REINSTALL_DURATION_SEC=$((FALLBACK_REINSTALL_END_TS - FALLBACK_REINSTALL_BEGIN_TS))" >> "$RUN_OPENCLAW_META"
      dump_openclaw_diagnostics

      # 2026-10-11 移除版本化快照回滚（主人拍板）：快照是主包的服务端副本，
      # 主包坏它也坏，兜底价值≈0，却长期占用一份 4.2GB 云端空间。自愈链
      # 收敛为：doctor --fix → 回退重装（已记录的兼容版本）。走到这里说明
      # 两条都失败了，直接判死走失败通知（人工介入，现场保留）。
      echo "FAIL_STAGE=fallback_reinstall" >> "$RUN_OPENCLAW_META"
      err="回退到最近记录版本（${TARGET_VERSION:-未知}）重装后，OpenClaw 依然无法启动（健康检查失败）"
      fail_startup "$err"
    fi
fi
