# Telegram 通知台账（域级出口与档位）

> 本文件只回答两件事：**哪一类通知从哪个出口发出、默认走什么档位**。
> 版式规则在 [`telegram-notify.md`](telegram-notify.md)（引用写「规范 · 主题名」）。
>
> **不登记逐条通知**——标题、档位、调用点都会随实现漂移。需要「现在到底有哪些通知」时
> 现场枚举：
>
> ```bash
> bash skills/telegram-notify-audit/scripts/list_notify.sh          # 全部发送点 + 标题 + 档位
> bash skills/telegram-notify-audit/scripts/list_notify.sh openclaw # 只看某个域
> ```
>
> 更新时机：某个域换了发送出口、或**默认**档位变了。新增 / 改名 / 下线单条通知
> **不需要改本文件**（单条档位以调用点为准）。

---

## 1. 域 → 出口 → 默认档位

| 域 | 发送出口 | 默认档位 |
|---|---|---|
| OpenList 同步 | `.github/scripts/openlist/`（`load_all.sh` 注入真源；`telegram.sh` 的 `send_telegram_message` 统一出口） | 普通；失败 / 告警类显式 alert |
| Telegram 频道内容管线 | `.github/scripts/tg-channel/` | 普通 |
| 备份与任务 workflow | workflow 内联（`github_backup_all`、`self-hosted_backup`、`notion-backup`、`icloud-photos-downloader`、`pixivutil2`、`ph-dl`、`p`、`upload-video-to-tg` 等） | 成功普通；失败 / 中断 / 崩溃兜底 alert；部分完成（⚠️ 未取全 / 单步失败）维持普通，由独立兜底 step 升级（iCloud 例外：全普通） |
| OpenClaw Runner 与 AI 网关 | `.github/workflows/openclaw.yml` + `.github/scripts/openclaw/run-*.sh`；交接进度 `.github/scripts/handoff/handoff-notify.sh` | 起停与播报（就绪 / 停止 / 倍率 / 用量 / 交接进度 / 入口与凭据推送）普通；失败 / 残留 / 风控 / 入口故障 alert；🟡 等即可（额度耗尽 / 账号池冷却 / 通道关闭 / Plan 降级）普通；停机倒计时 alert |
| Windows 入口 | `.github/workflows/rdp.yml`、`tailscale-windows.yml`（pwsh） | 普通（入口与凭据推送） |
| Emby | `.github/workflows/emby.yml` | 启动 / 回退 / 停止按结论动态（服务可用 → 普通；失败 / 中断 → alert；直链回退后服务仍可用，普通）；凭据普通；播放普通 |
| 测速三套 | `.github/scripts/proxy-speedtest/` | 主报告普通；异常退出 / 终止 alert |
| 保活接力熔断 | `.github/scripts/lib/self_retrigger.sh` | alert |
| 本机常驻服务 | `.github/scripts/health/system_health.sh`、`services.sh` 生成的 dropbox 挂载守卫（仓库内）；`board.py`、`gateway-watchdog.py`（宿主机，不在仓库） | 故障 alert；恢复普通 |
| 媒体 | `tg-channel/tg_send_video.py`（视频 caption）、`openlist/sync_notify.sh`（`sendDocument` 日志附件） | 不走档位（不经 sendMessage 发送层） |

> **内嵌通知的拆/不拆**：判据见规范 · 接线。依赖落盘产物的拆独立 `always()` step，
> 依赖运行时变量的在业务步内加失败兜底；「已就绪」与长驻循环不拆。别把「不拆」报成缺陷。

> **接力熔断告警的覆盖面**：只有走共享接力 `self_retrigger.sh` 的 workflow 能发
> `🧯 保活接力已熔断`；手写接力的 workflow 没有这条告警，改接力时要自己补失败兜底。

## 2. 档位判定规则

**唯一口径在规范 · 档位判定**（图标对照表 + 两条判据），此处只留三条调用约定：

- 默认普通：`send_tg "$msg"` 不传 tier → @FuckSaberBot。
- 重要档：`send_tg "$msg" alert` / `send_tg_chunked "$msg" alert` /
  `send_telegram_message "$msg" HTML alert` / `send_telegram(env, text, 'alert')`
  → @SaberFuckBot。
- 档位由**调用点显式声明**，发送层不按标题匹配。同一发送点「正常与异常共用」的
  （各网关 `gw_send`、停止通知、Emby 停止通知）按**分支**传 tier。逐条档位以
  `list_notify.sh` 输出为准。
- alert 档**无回落**：`_ALERT` 凭据缺失即发送失败并在日志留痕；调用点**不要**加
  `if [ -n "$..._ALERT" ]` 之类的静默守卫（规范 · 接线）。
- 进度面板、`sendDocument` / `sendVideo` 直连主 bot，不参与档位路由。
- bot 分工的唯一口径见规范 · 全库 bot 分工。

## 3. 不发通知的场景

- **没有发送点的 workflow 不登记**：用 `list_notify.sh` 现场确认；要补通知时照
  规范 · 结果通知，并把 `TG_RUN_URL` 接上。
- **只做 `workflow_call` 编排的 workflow** 自身不发，由被调 workflow 负责。
- **只上传媒体、不产生业务通知的 workflow** 不接 sendMessage；caption 见规范 · 媒体 caption。
- **纯保活 workflow** 只有共享接力链路的熔断告警；手写接力需自行补失败兜底。

## 4. 域字段口径在哪

各域的字段级约定（哪些字段等宽、排序、冷却怎么写、数据源是哪个接口）跟着实现走。
**只写非显然、且写错会出事的约定**；逐条标题与字段枚举交给 `list_notify.sh <域>`
与代码注释：

| 域 | 文档 |
|---|---|
| workbuddy-gateway / trae2api / zcode2api / AI 网关用量报告 | [`openclaw.md`](openclaw.md)「九、通知口径」 |
| Emby 起播等待 | [`emby.md`](emby.md)「起播等待」 |
| 测速三套 | [`proxy-speedtest-taier.md`](proxy-speedtest-taier.md) 等 |
| 保活接力 | [`self-retrigger.md`](self-retrigger.md) |
