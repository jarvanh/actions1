#!/usr/bin/env bash
# ── AI 整包直取（Phase 2，2026-11-10）──
# 由 takeover.sh 在 rsync_done 之后**后台**拉起：不占聊天路径的关键路径，
# 但一旦取到就能让 AI 栈跳过 Dropbox 下载。
#
# 契约：旧轮在交出瞬间用归档脚本现做 OmniRoute 整包并投到 /tmp/handoff-ai-payload
#（rsyncd 的 [ai] 模块）。取到 + tar 校验通过 → 播种 prefetch 协议
#（/tmp/openclaw-prefetch/OmniRoute.tar.gz + omniroute-tar.rc=0/.pid），
# 让 run-ai-gateway.sh 原有的 fetch_via_prefetch 命中它；校验/解包/载入命名卷
# 全部沿用原逻辑，只换传输通道。
# 取不到 → 什么都不播种 → gate 走 ai.json（Dropbox 归档，Phase 1.5 行为）。
# 这是「直传优先、失败回退 Dropbox」的落地方式。
# 2026-11-15：明确失败（旧轮 dump.rc≠0 / tar 校验不过 / 300s 单次超时）时写
# /tmp/handoff-ai-fail.reason，供 gate:ai_archives_done 立即放行 —— 旧轮明确说
# 快路径没戏时，继续空等 ai.json 只会白耗 60s（run 43707372232 实测）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"

OLD_TS_IP="${1:-}"
[ -n "$OLD_TS_IP" ] || { echo "⚠️ [ai-fetch] 缺旧轮 IP，放弃直取"; exit 0; }
AI_PAYLOAD_DIR=/tmp/handoff-ai-payload
PF_DIR=/tmp/openclaw-prefetch
mkdir -p "$AI_PAYLOAD_DIR" "$PF_DIR"
# 日志同时落盘与回流：setsid 子进程默认不进 step 日志，排障时会「看起来什么都没发生」。
# 用 tee 写一份 /tmp，并经由调用方给的 FIFO/文件回流（见 takeover.sh 的重定向）。
exec >>/tmp/handoff-ai-fetch.log 2>&1
echo "[$(date '+%F %T')] ai-fetch pid=$$ src=${1:-?}"
echo "[$(date '+%F %T')] ai-fetch start (src ${OLD_TS_IP}:${HANDOFF_RSYNC_PORT})"

OMNI_VOL="${OMNIROUTE_VOLUME:-omniroute_omniroute-data}"
OMNI_IMG="${OMNIROUTE_IMAGE:-diegosouzapw/omniroute:latest}"
DEB_DIR="$HOME/omniroute"

# 2026-11-16 实测事故：本脚本由 takeover 在**交出瞬间**拉起，常常早于旧轮 cutover
# 清理/重写 /tmp/handoff-ai-payload —— 读到的是**上一轮残留的 dump.rc（rc=1）**，
# 于是秒判「dump 失败」→ 永久回退 Dropbox → AI 闸门白等 12.5 分钟 →
# 全站停机被拉到 ~19 分钟（ai-api 530 就是这段）。
# 修法：记下本轮起始时刻，只信**晚于它**写入的 dump.rc；并先清掉残留文件。
# 2026-11-17 二次修正：基线**不能用本脚本启动时刻**。实测（14:02 交接）旧轮
# 的 dump.rc 写于 14:01:55，而 ai-fetch 14:02:01 才启动 —— 差 6 秒，被判成
# 「上一轮残留」→ 无限循环、还每轮删掉已下载的 1.68GB → 最终 timeout。
# 正确基线 = 旧轮的 cutoff（dump 一定发生在 cutover 之后），留 120s 容差。
_cut="$(handoff_get "$HANDOFF_OLD_REMOTE" '.cutoff_epoch' 2>/dev/null || true)"
case "${_cut:-}" in ''|*[!0-9]*) _cut=0 ;; esac
if [ "$_cut" -gt 0 ]; then
  _TAKEOVER_TS=$(( _cut - 120 ))
else
  _TAKEOVER_TS=$(( $(date +%s) - 600 ))   # 拿不到 cutoff：宽松回退 10 分钟
fi
echo "$_TAKEOVER_TS" > /tmp/handoff-ai-baseline-ts 2>/dev/null || true
rm -f "$AI_PAYLOAD_DIR/dump.rc" "$AI_PAYLOAD_DIR/omnivol.tar" "$AI_PAYLOAD_DIR/omnideploy.tar"
# 同时清掉上一轮的远程收尾信号（否则旧 VM 会在等待里秒读 done/giveup → 提前关 rsyncd）
rclone deletefile "${HANDOFF_REMOTE_DIR%/}/ai-fetch.json" >/dev/null 2>&1 || true
echo "[$(date '+%F %T')] ai-fetch 本轮基线 ts=${_TAKEOVER_TS}（早于此的 dump.rc 视为上一轮残留）"

# ── Phase 2b 快路径：取「裸卷 dump」并装进同名卷 ──
# 旧轮在交出瞬间停 AI 栈后直接 tar 卷（不做 VACUUM/压缩，10-20s 完成），
# 这里 rsync 直取（540MB，实测 88-150MB/s）+ 解包进卷，全程 ~15-30s。
# 一致性：旧轮容器已停，卷是静树 → 裸 dump 与 VACUUM 快照等价。
# 2026-11-14 事故：旧轮 dump 出 2GB omnivol.tar，但单次 rsync 被 `timeout 120`
# 中途杀掉（慢链路下 2GB 需要 >120s），循环重试又每次从头传 → 一直传不完；
# 本地只剩 dump.rc + 10KB omnideploy，校验判失败后回退 Dropbox，最终 52 分钟才服务。
# 修法：单次给 300s、加 --partial 可断点续传、总预算 600s（超时就走 Dropbox 回退）。
_deadline=$(( $(date +%s) + 600 ))
_i=0
while [ "$(date +%s)" -lt "$_deadline" ]; do
  _i=$((_i + 1))
  if timeout 300 rsync -a --partial --timeout=60 \
      "rsync://${OLD_TS_IP}:${HANDOFF_RSYNC_PORT}/ai/" "$AI_PAYLOAD_DIR/" >/dev/null 2>&1 \
     && [ -f "$AI_PAYLOAD_DIR/dump.rc" ]; then
    # 2026-11-14 实测：rsync 会先同步到 dump.rc / omnideploy.tar，而 2GB 的
    # omnivol.tar 还在传（rsync --partial 的临时文件 mtime=1970）——
    # 原代码此时直接 break，把「还没传完」误判成「dump 失败」，永久回退 Dropbox。
    # 区分两种情形：rc!=0 才是真失败（旧轮明确报错）；rc==0 但文件缺失/为空
    # 说明仍在传输 → 继续下一轮（--partial 续传）。
    _rc="$(cat "$AI_PAYLOAD_DIR/dump.rc" 2>/dev/null)"
    _rc_mtime=$(stat -c %Y "$AI_PAYLOAD_DIR/dump.rc" 2>/dev/null || echo 0)
    if [ "${_rc_mtime:-0}" -lt "${_TAKEOVER_TS:-0}" ]; then
      # 注意：**不能删**已下载的 omnivol.tar（--partial 要续传；删了就得从头再来，
      # 实测因此每轮重下 1.68GB 直到 600s 预算耗尽）。
      echo "⏳ [ai-fetch] dump.rc 早于本轮基线（mtime ${_rc_mtime} < ${_TAKEOVER_TS}）→ 上一轮残留，继续等"
      sleep 3; continue
    fi
    if [ "$_rc" != "0" ]; then
      echo "⚠️ [ai-fetch] 旧轮 dump 失败（rc=${_rc:-空}），走 Dropbox 回退"
      echo "old_dump_rc=${_rc:-empty}" > /tmp/handoff-ai-fail.reason
      break
    fi
    if [ ! -s "$AI_PAYLOAD_DIR/omnivol.tar" ] || [ ! -s "$AI_PAYLOAD_DIR/omnideploy.tar" ]; then
      echo "⏳ [ai-fetch] dump.rc=0 但大文件未到齐（第 ${_i} 次，omnivol=$(stat -c %s "$AI_PAYLOAD_DIR/omnivol.tar" 2>/dev/null || echo 0)B）—— 继续续传"
      sleep 3; continue
    fi
    # 校验 tar 完整性（截断包绝不装载）
    if ! tar tf "$AI_PAYLOAD_DIR/omnivol.tar" >/dev/null 2>&1 \
       || ! tar tf "$AI_PAYLOAD_DIR/omnideploy.tar" >/dev/null 2>&1; then
      echo "⚠️ [ai-fetch] dump 包校验不过（第 ${_i} 次）"
      # 2026-11-15：同一轮内校验失败 ≥3 次 = 旧轮的包坏了（不是没传完），
      # 600s 预算内继续重传大概率拿到同一个坏包 → 标记明确失败，gate 提前放行
      _fail=$(( ${_fail:-0} + 1 ))
      [ "$_fail" -ge 3 ] && { echo "old_payload_corrupt" > /tmp/handoff-ai-fail.reason; break; }
      sleep 5; continue
    fi
    # ① 部署目录（compose + .env）：让 run-ai-gateway 的 restore 走「已就绪」短路
    mkdir -p "$DEB_DIR"
    if ! tar xf "$AI_PAYLOAD_DIR/omnideploy.tar" -C "$DEB_DIR" 2>/dev/null; then
      echo "⚠️ [ai-fetch] 部署目录解包失败，走 Dropbox 回退"; break
    fi
    # ② 装载命名卷
    docker volume create "$OMNI_VOL" >/dev/null 2>&1 || true
    if docker run --rm --user root -v "${OMNI_VOL}:/target" -v "$AI_PAYLOAD_DIR:/src:ro" "$OMNI_IMG" \
         sh -c 'nice -n 19 ionice -c3 tar xf /src/omnivol.tar -C /target' >/dev/null 2>&1 \
       && docker run --rm --user root -v "${OMNI_VOL}:/data:ro" "$OMNI_IMG" \
            sh -c 'test -s /data/storage.sqlite -o -s /data/server.env' >/dev/null 2>&1; then
      : > /tmp/handoff-ai-fast.ok
      echo "⚡ [ai-fetch] 卷直装完成（$(du -h "$AI_PAYLOAD_DIR/omnivol.tar" | awk '{print $1}')）—— AI 栈走快路径，跳过 Dropbox"
      # 2026-11-17：把收尾信号写进 new.json（旧 VM 的 cutover 轮询它来决定
      # 何时关 rsyncd —— /tmp 是各 VM 本地的，旧 VM 看不到 fast.ok）
      _nf=/tmp/handoff-new-ai-fetch.json
      printf '{"ai_fetch":"done","ts":%s}' "$(date +%s)" > "$_nf" 2>/dev/null || true
      rclone copyto "$_nf" "${HANDOFF_REMOTE_DIR%/}/ai-fetch.json" >/dev/null 2>&1 || true
      rm -f "$_nf"
      exit 0
    fi
    echo "⚠️ [ai-fetch] 卷装载失败（第 ${_i} 次）"
  fi
  sleep 5
done
echo "ℹ️ [ai-fetch] 快路径未就绪 —— AI 栈走 Dropbox 归档（Phase 1.5 行为）"
# 通知旧 VM：本机已放弃快路径（rsyncd 可以关了）
_nf=/tmp/handoff-new-ai-fetch.json
printf '{"ai_fetch":"%s","ts":%s}' "$([ -s /tmp/handoff-ai-fail.reason ] && echo giveup || echo timeout)" "$(date +%s)" > "$_nf" 2>/dev/null || true
rclone copyto "$_nf" "${HANDOFF_REMOTE_DIR%/}/ai-fetch.json" >/dev/null 2>&1 || true
rm -f "$_nf"
# 600s 预算耗尽仍没拿到包：若旧轮 payload 里只有半包（omnivol 缺失/为空且 dump.rc
# 从未变 0），多半是旧轮 dump 进程死了 —— 同样标记明确失败，gate 不必再等 ai.json
target="$AI_PAYLOAD_DIR/omnivol.tar"
if [ ! -s "$target" ]; then
  echo "old_payload_incomplete" > /tmp/handoff-ai-fail.reason
fi
exit 0
