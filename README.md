# actions

自用 GitHub Actions 工作流集合：网盘同步备份、媒体服务器运维、订阅签到、数据备份等，
均通过 `workflow_dispatch` 手动触发。

## 仓库结构

```
.github/
├── workflows/              34 个工作流定义
└── scripts/
    ├── openlist/           OpenList 同步工具 —— 最复杂的子系统，详见下文
    ├── emby302/            Emby 302 直链服务 —— 详见 docs/emby.md
    ├── telegram/           Telegram 通知（tg_notify.sh = 全库发送层真源）
    ├── tg-channel/         Telegram 频道内容管线（同步/上传/去重/清理；tg_login.py 交互生成 TG_SESSION）
    └── proxy-speedtest/    代理测速脚本（common 共享层 + gitee 上行/下行/延迟 + CDN 延迟/下载 + 泰尔三网 + Speedtest 官方测速点 + gist 抓节点喂 Sub-Store 去重；tests/ 为离线自检）
docs/                       子系统文档
proxy-speedtest/            测速结果数据
```

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/telegram-notify.md`](docs/telegram-notify.md) | **Telegram 通知规范**（版式与发送规则的唯一真源：版式模板、收尾区、发送层硬约束、验证基线） |
| [`docs/telegram-notify-registry.md`](docs/telegram-notify-registry.md) | **Telegram 通知台账**（域级出口与档位路由；不登记逐条通知，清单用 `list_notify.sh` 现场枚举） |
| [`docs/telegram-notify-catalog.md`](docs/telegram-notify-catalog.md) | **Telegram 通知总览**（域 × 形态 × 档位一页看全；种类与结构，不含逐条清单） |
| [`docs/socks-exit-pool.md`](docs/socks-exit-pool.md) | 出口节点池：SOCKS5 出口测活/判区 + subs-check 基座组合，发布独立 Gist |
| [`docs/emby.md`](docs/emby.md) | Emby 媒体服务器 + 302 直链子系统（架构、凭据体系、通知、排查手册） |
| [`docs/openclaw.md`](docs/openclaw.md) | OpenClaw Runner：自愈机制（四层 + 已退役机制⑤）+ 常驻服务（rss-to-telegram / AI 网关）+ Tailscale 远程入口 |
| [`docs/migration.md`](docs/migration.md) | **全量迁移说明**：仓库代码 + Actions Secrets + Variables + Dropbox 归档的恢复顺序与验证清单 |
| [`docs/proxy-speedtest-gitee.md`](docs/proxy-speedtest-gitee.md) / [`-cdn.md`](docs/proxy-speedtest-cdn.md) / [`-taier.md`](docs/proxy-speedtest-taier.md) | 代理测速三套（按测速点命名）：Gitee 上行/下行/延迟 / 国内 CDN 延迟+下载 / 泰尔三网 |
| [`docs/proxy-speedtest-gistnodes.md`](docs/proxy-speedtest-gistnodes.md) | 从 gist 搜索抓节点 → Sub-Store 去重出 mihomo YAML → 选一套测速（引擎由环境变量切换） |
| [`docs/archive/`](docs/archive/README.md) | **已完结**文档的归档（存史与查证用，不是进行中计划）：OpenList 同步修复蓝图、同步健康检查 |
| 下文「OpenList 同步子系统」 | OpenList 同步工具（内联在本文档） |

## 工作流清单

| 工作流 | 用途 |
|---|---|
| `openlist.yml` | OneDrive → OpenList 网盘同步（**本文档重点**） |
| `openlist-diag.yml` | OpenList 后端可写性诊断（独立 concurrency，单次 ~4min；**不搬数据**，见下文「后端可写性诊断」） |
| `openlist-restore-tryrun.yml` | 一键还原 **try run（只读预演）**：逐条给出「备份文件 / marker 原文件 / 实际执行还原」三条完整路径，**不写任何数据**；支持全量 / 最近 N 天（`within_days`）/ 某时刻之后（`since`）三种样本口径（见下文「一键还原 try run」） |
| `self-hosted_backup.yml` | 自建服务备份到 OneDrive |
| `github_backup_all.yml` | 备份全部 GitHub 仓库到 OneDrive |
| `emby.yml` | Emby 媒体服务器 + 302 直链 —— 详见 [`docs/emby.md`](docs/emby.md) |
| `jellyfin.yml` | 媒体服务器运维 |
| `HomeAssistant.yml` / `rdp.yml` / `openclaw.yml` | 自托管服务 |
| `ql.yml` / `sub-store.yml` / `subs-check.yml` | 签到与订阅管理 |
| `socks-exit-pool.yml` | subs-check 每个节点 × 每个验证通过的 SOCKS5 出口（path 级切换，YouTube 定区），产物写独立 Gist 文件 —— 详见 [`docs/socks-exit-pool.md`](docs/socks-exit-pool.md) |
| `icloud-photos-downloader.yml` / `ph-dl.yml` / `pixivutil2.yml` | 媒体抓取下载 |
| `proxy-speedtest-gitee.yml` / `proxy-speedtest-cdn.yml` / `proxy-speedtest-taier.yml` | 代理测速三套（按测速点命名）：Gitee 上行/下行/延迟 / 国内 CDN 延迟+下载 / 泰尔三网 |
| `proxy-speedtest-gistnodes.yml` | 抓 gist 公开节点 → Sub-Store 去重 → 交给上面三套之一测速（选哪套由 Variable `PROXY_SPEEDTEST_ENGINE` 决定）—— 详见 [`docs/proxy-speedtest-gistnodes.md`](docs/proxy-speedtest-gistnodes.md) |
| `upload-video-to-tg.yml` / `p.yml` / `teslamate.yml` / `notion-backup.yml` | 视频上传、Vaultwarden/TeslaMate 等杂项、Notion 每日备份 |
| `actions-archive.yml` / `cfip-pool.yml` / `tests.yml` | 手动仓库全量归档、CF 优选 IP 池重建、测试载体 |
| `openlist-debug.yml` / `openlist-preview.yml` / `openlist-fix-check.yml` / `openlist-marker-cleanup.yml` | OpenList 只读目录探针 / 独立剩余量预览 / 修复能力定点验证 / 旧 marker 清理 |
| `tailscale-windows.yml` | Windows 常驻远程入口（自续触发） |
| `delete-workflow-runs.yml` | 清理历史运行记录 |

---

# OpenList 同步子系统

> 代码：`.github/scripts/openlist/`　入口：`.github/workflows/openlist.yml`
> 以下为该子系统的完整文档。

`openlist.yml` 工作流的脚本实现：把 OneDrive 源端同步到 OpenList 挂载的多个网盘（crypt 加密后端），
并处理网盘侧的各种故障（假成功、405/8005、名长超限、423 锁等）。

主体为 bash 函数库，另有 `.py` / `.jq` 辅助程序；由 `load_all.sh` 统一加载。脚本层不含可执行入口，运行入口是 workflow 的 `run_mode`。

> 注：脚本注释中的「§N.N」引用一律指归档计划文档
> `docs/archive/openlist-remediation-plan-2026-09-13.md` 的章节编号
> （实验依据与决策记录的溯源）。

---

## 模块划分

文件名采用 `<领域>_<职责>.sh`，按域聚集（**诊断/运维族不进 `load_all.sh` 加载链**，由对应 workflow 独立调用）：

| 域 | 文件 | 职责 |
|---|---|---|
| **rclone** | `rclone_flags.sh` | rclone 参数单点定义（`RCLONE_*_FLAGS`） |
| | `rclone_query.sh` | 查询与过滤解析（`size --json`、`check`、exclude 提取） |
| **openlist** | `openlist_api.sh` | 管理面登录换 token、服务就绪等待 |
| | `openlist_storage_check.sh` | 存储账号失效巡检与 Telegram 告警（`storage/list` 全量真值 + 冷却/首次发现记账 `storage_alert.json` + Crypt 派生影响面；`check_openlist_storage_health`） |
| | `openlist_driver.sh` | 驱动刷新、健康预检、缓存刷新、truth-check |
| **sync** | `sync_engine.sh` | 核心同步引擎（编排 + 423/8005 重试） |
| | `sync_marker.sh` | 同步标记持久化（跳过、黑名单、修复清单）+ 修复记录生命周期（carry-forward 继承、已对齐收尾清理、父级守卫提取、**游标拒写分支立即持久化修复记录**——防「fold 后拒写丢记录 → 产物被删 → 重 fold」循环）+ **marker 打包外置备份**（`backup_sync_state_to_dropbox`） |
| | `sync_notify.sh` | 同步结果通知构建（统一 Telegram HTML 排版） |
| | `sync_trend.sh` | 跨 run 传输趋势（P0 可见化：剩余未传/净传速率/预计清零，收尾发「📈 同步趋势」通知） |
| | `sync_progress.sh` | 全局进度通知系统（含收尾五态标题、多层级阶段区） |
| **file** | `file_split.sh` | 大文件分割（ffmpeg 关键帧 / 7z 分卷） |
| | `file_fix.sh` | 单文件修复的 4 种方法 + 目录可写性三态预检 + 短哈希目录兜底 + 写入侧根层路径断根（防 `./` 污染进 marker） |
| | `file_fix_pipeline.sh` | 修复管线编排（方法轮换 + 增量持久化 + 最终 sync 的 filter 保护构建：marker ∪ 本轮累计 ∪ 父级守卫） |
| | `file_restore.sh` | 修复文件还原（目标端 → 原路径 / 源端） |
| | `restore_tryrun.sh` | 一键还原 **try run**（只读预演：三条完整路径推导 + 只读白名单护栏 + 时间窗 `within_days` / 绝对下界 `since` + 读取侧路径归一化（`./` 污染金丝雀）+ 双直读复核 + 缺失目录结构探针 + 源端原路径核对与阳性对照 + **marker 原文探针**（dump 归属/时间/源端直读，查"这条记录由谁、何时写下"）；`restore_try_run`） |
| | `reset_markers.sh` | marker **归档 + 清空**（一次性运维：先打包归档到 dropbox、归档失败拒绝清空、两道读取判据、默认 dry-run 需 `--commit`；`reset_markers` 入参） |
| **task** | `task_preview.sh` | 任务预览（大小估算、跳过预判、未传量估算） |
| | `task_engine.sh` | 任务注册表与编排（分批、轮转、阶段行生产 + 子任务分发前注入父级守卫，防「父级已修被子目录 sync 删」） |
| **基础** | `utils.sh` | 通用工具（格式化、日志判定、`_norm_rel_path` 读取侧路径归一化（`./` 污染兜底）；转义/树形渲染已收敛到 `telegram/tg_notify.sh`） |
| | `telegram.sh` | Telegram 进度面板（`send_telegram_message` + 删旧发新维护 message_id；排版/发送 source 真源） |
| | `load_all.sh` | 统一加载入口（L0 通知真源 → L6 分层；注释含 §N.N 引用指引） |
| **诊断**（`openlist-diag.yml` 调用） | `diag_common.sh` | 诊断族公共函数（`say/sec/http_code_of/is_409/_mk`） |
| | `diag_backend.sh` | 后端可写性总诊断：多组写探针（挂载根/任务子路径/并发/大文件阶梯）+ 容器日志原始 `rsp_code` dump |
| | `diag_write_probe.sh` | 目录可写性判据验证（探针写失败 == 不可写？→ 隐式 mkParentDir 假设的证实/证伪） |
| | `diag_dirname_probe.sh` | 目录名/路径变量分离（名字 vs 父层路径 vs 后端残留） |
| | `diag_l2_probe.sh` | L2「mkdir 假成功」普遍性实验（通用缺陷还是个例） |
| | `diag_depth_probe.sh` | 层级/深度 vs 健康窗口同构分离（同深度同形状对照） |
| | `diag_escape_probe.sh` | 兜底目录跳出故障子树可行性（上跳可写层 + 归位路径） |
| | `diag_409_semantics.sh` | 409 语义验证（幂等 vs 真故障）+ 短名改回原名是否蒸发 |
| | `diag_reject.sh` | 拒收归因（按内容 vs 按文件名/状态；三组对照 + 重启取真值） |
| **运维**（独立 workflow 调用） | `fix_check.sh` | 修复能力定点验证（对指定文件跑生产同款修复管线，逐文件判 fixed/fake_success/failed；`openlist-fix-check.yml`） |
| | `cleanup_legacy_marker_entries.sh` | 旧格式 marker 条目一次性清理（dry-run 默认，`--apply` 生效；`openlist-marker-cleanup.yml`） |

辅助程序：`get_storage_addition.py`（从 db 读存储配置）、
`scan_fix_signatures.py`（marker 丢失时反推修复条目）、`restore_info.jq`（还原方式分类）。

---

## 命名约定

**文件名**：`<领域>_<职责>.sh`，见上表五域。

**函数名**：

| 形式 | 含义 | 例 |
|---|---|---|
| `_xxx` | 内部函数，不跨模块调用 | `_extract_filter_args` |
| `xxx` | 公开 API，可被 workflow 或其他模块调用 | `sync_task`、`flush_task_preview` |
| `tg_xxx` | Telegram 排版助手 | `tg_add_kv`、`tg_add_section` |
| `progress_xxx` | 进度系统公开 API | `progress_task_begin` |

**领域限定词是硬性要求**：存在两套独立的"方法 N"编号体系，函数名与日志文案必须带领域词，
否则无从判断所指（详见下方"易混淆概念"）。

---

## 加载机制

```bash
source "$GITHUB_WORKSPACE/.github/scripts/openlist/load_all.sh"
```

按 **L0 → L6** 分层自下而上加载，括号内为主要依赖：

```
L0 通知真源 telegram/tg_notify.sh（跨目录 source，全库唯一实现）
L1 基础     rclone_flags · utils · telegram(进度面板)
L2 适配     rclone_query[utils] · openlist_api · openlist_storage_check[openlist_api,telegram]
L3 能力     file_fix · file_split · sync_marker · sync_progress · sync_trend
L4 编排     openlist_driver[openlist_api,file_fix] · file_fix_pipeline · sync_notify
L5 引擎     sync_engine
L6 任务     file_restore · restore_tryrun[file_restore] · task_preview · task_engine
```

> bash 函数在**调用时**才解析，所以顺序不影响正确性；保持分层纯粹为了可读性。
> 但注意：**不要在模块顶层写函数调用**，各文件顶层只允许变量/数组定义。

workflow 会把 `*.sh` `*.py` `*.jq` 拷到 `/tmp` 再 `source /tmp/load_all.sh`
（每个 step 是独立 shell）。新增模块文件**无需改 workflow**（通配符自动拷入），
但仍须在 `load_all.sh` 对应层加一行 `source`，否则不会被加载。

---

## 同步主流程

`run_mode=同步` 时，`run_all_tasks` 跑两遍：

```
第一遍（预览 pass，TASK_PREVIEW_ONLY=1 或 TASK_REGISTER_ONLY=1）
  run_all_tasks → sync_task → _preview_register
      → add_preview_pair（累加到 PREVIEW_PAIRS_TSV）
           └─ 顺带预判 --Nd-skip 窗口（pskip 列）+ 把待同步量写入
              PREVIEW_PENDING_MAP，供第二遍的跳过通知复用
  flush_task_preview → 按 task_name 分组，从 TSV 重算统计量 → 发 Telegram

第二遍（真正同步）
  run_all_tasks → sync_task → _sync_task_impl → sync_with_logging
      健康预检 → rclone copy（openlist: 目标端，2026-11-01 起）→ 重试(423/8005) → truth-check 取后端真值
      → diff 出缺失文件 → 修复管线 → 结果通知
```

预览的统计量是 `flush_task_preview` **从 TSV 重算**的（每个任务局部归零后累加自己那几行），
`PREVIEW_PAIRS_TSV` 是跨任务累加的唯一数据源。

---

## 易混淆概念

### 1. 两套"方法 N"

| 体系 | 位置 | 内容 | 命名要求 |
|---|---|---|---|
| **文件修复方法 1-4** | `file_fix.sh` | `copyto_original` / `copyto_shorthash` / `zip_split_original` / `zip_split_shorthash` | 展示层 `方法N·动作·变体`（`_fix_method_short`）；持久化层 `_fix_method_desc` 必须保留 `restore_info.jq` 依赖的分类子串（`分卷切割` / `短哈希文件名`） |
| **驱动刷新方法 1-3** | `openlist_driver.sh` | `storage/load_all` 重载 / 重启容器 / `storage/list` 探测 | 文案带领域词：`驱动刷新方法1` |

两者完全无关。历史教训：旧端点 `/api/driver/update` 恒失败，其失败 **≠ 驱动坏**，
不能当驱动状态信号（run 32749862280 实锤）。

文件修复方法的**黑名单条目存归一语义 ID**（`copyto_original` 等）而非描述文本，
以便命名口径演进后历史 marker 仍能命中（见 `_fix_method_norm`）。

### 2. 两个"split"

| | 维度 | 阈值 | 位置 |
|---|---|---|---|
| **文件级分割** | 把单个大文件切成多段 | 4GB（`LARGE_FILE_THRESHOLD_BYTES`） | `file_split.sh` |
| **任务级分批** | 按一级子目录把同步任务拆成子任务递归 | 20GB（workflow 设 `SYNC_SPLIT_THRESHOLD_BYTES`，脚本兜底 50GB） | `task_engine.sh` 的 `--auto-split` |

`SYNC_SPLIT_*` 是历史命名且属**用户可配环境变量**，为避免既有配置静默失效，未改名；
两者关系在 `file_split.sh` 与 `task_engine.sh` 头部有交叉标注。

### 3. `restore` vs `rebuild`

两个都是"目标端 → 源端"，但：

- `restore_source_from_target` — **非破坏性**：仅把 marker 修复条目回填源端，不删任何文件
- `rebuild_source_from_target` — **破坏性**：先 `rclone sync` 镜像再回填，
  源端多余文件会被删除，最终源端 = 目标端内容

### 4. 预览的"待同步" vs 本次实际传输

两者**不相等**，`--Nd-skip` 是唯一原因：预览 pass 不查 marker（只算差异），
同步 pass 的窗口判断在任何传输之前 —— 命中窗口的同步对整对跳过，一个字节都不传。

因此：

- 预览里命中跳过窗口的同步对会标 `⏭️ 本轮预计跳过`，合计另附
  "预计跳过 X / 预计实际传输 Y"（`add_preview_pair` 的 pskip 列 + `flush_task_preview`）
- 跳过通知带 `📦 本次未传`，给出被跳过的差异量（`send_sync_skipped`）：
  优先复用预览算好的值（`PREVIEW_PENDING_MAP`，预览与同步同 step，零成本），
  auto-split 子任务无独立预览条目时现场估算（`OPENLIST_SKIP_ESTIMATE=0` 关闭），
  任一端列举失败则不展示 —— 宁缺毋滥，避免把虚高全量挂到"未传"上
- `FORCE_SYNC=true` 跳过全部标记检查（`check_sync_marker` / `check_marker_skip_window`），
  预览此时也不会标注"预计跳过"

---

## 任务注册表

单点定义在 `task_engine.sh` 的 `SYNC_TASK_REGISTRY`，格式：

```
"id|源端|目标端|任务名|附加参数"
```

| 字段 | 说明 |
|---|---|
| id | 调试模式选择器，不需要单独调试的任务填 `-` |
| 附加参数 | `--auto-split` 源端超阈值时按子目录分批；`--Nd-skip` N 天内已成功则跳过；`--exclude` 等原样透传 rclone |

例：`"task0|onedrive:0|openlist:wopan176Crypt/0|task0|--auto-split --1d-skip"`

### `gd:` 同步对（2026-11-06 恢复）

`backup-gd` / `task0-gd` … `task3-gd` 是 **Google Drive 镜像**对。**禁止给它们加
`--auto-split`**：`sync_engine.sh` 对非 `openlist:*` 目标走 `rclone sync`（自带删除，
才是真镜像），而 `--auto-split` 会进入 `sync_by_file_batches` 的
`rclone copy --files-from`（**不删除**）⇒ 镜像会静默退化成只增不减，旧命名/两代重复的
文件永远留着（task3 曾因此多出 90.68 GiB）。每项带 `--max-delete <N>` 作为硬闸
（超限时 rclone abort，下轮继续，防止源端路径异常把 gd 清空）。
**恢复范围只有 backup / 0 / 1 / 2 / 3 五项**：用户明确决定 `task4`、`task5` **不同步到
gd**（两者源端合计 1527 GiB，而 gd 实际可用约 927 GiB，容量也不允许）。注册表里
不应出现 `task4-gd` / `task5-gd`。

⏸ **当前已临时移出（2026-11-13，用户决定）**：Google Drive 配额已满 —— 实测
`rclone about gd:` 为 `Used 2.883 TiB / Total 15 GiB`（付费容量掉了）。生产日志证实
这 5 个对**每个文件**都撞 `googleapi: Error 403: The user's Drive storage quota has
been exceeded`（run 43267803971，gd:backup 自 20:08:01 起连续 403），配额恢复前不可能
写入、每轮只在首个对上白烧约 7 次重试 ⇒ `SYNC_TASK_REGISTRY` 已移除
`backup-gd` / `task0-gd`~`task3-gd`，原行以注释形式留在数组下方（含恢复说明）。
配额快速失败（`_quota_backend_key` 按远端分组）与同盘跳过逻辑**保持不变**，
容量恢复后把 5 行放回数组即可，无需其他改动。

`gd:` 目标不经过写探针 / F5 全拒闸 / 批次巩固 / `_sync_mirror_prune` / truth-check /
修复管线 —— 这些都在 `[[ $dest_path == openlist:* ]]` 处提前返回。`file_split.sh`
另有代码级硬闸：非 `openlist:*` 目标一律跳过 `split_on_sync_failure`，因为该路径会
`rclone deletefile` **删除源端**原始大文件（"绝对不修改源端"红线），而 Drive 单文件
上限 5 TiB 根本不需要切割。

**配额已满 ⇒ 快速失败（2026-11-12 加）**：Drive 返回
`403 ... storage quota has been exceeded` 属**账号侧终态**，重试不会自愈。
实测（run 43001486184）rclone 内部 `--retries 3`、每次约 3 分钟 ⇒ 一个 gd 对白烧
~13 分钟，5 个 gd 对 ≈ 65 分钟（占 320 分钟预算 20%）且必然 0 产出。
现行为：`sync_with_logging` 识别该错误后 ①立即判失败（**不**冒充"到点交棒"）
②写 `/tmp/ol_quota_exhausted_<backend>` 标记（每轮新 runner，`/tmp` 天然清空 ⇒
容量恢复后下一轮自动参战）③跳过镜像清理 / truth-check / 修复管线（配额满时全是空转）
④并行调度看到标记即**跳过同后端其余同步对**，不再起 worker 烧重试。
⚠️ 这是运维信号不是代码 bug：出现即说明该盘需要扩容或清理（`rclone about gd:` 可看
`Total/Used`；实测曾出现 `Used 2.883 TiB / Total 15 GiB` —— 付费容量掉了）。

---

## 环境变量

集中定义在 workflow 的 `env:` 块（避免魔数散落脚本）。

**凭据**：`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `OPENLIST_ADMIN_PASSWORD`（均来自 secrets）

**阈值（字节）**：`LARGE_FILE_THRESHOLD_BYTES`(4GB) · `SYNC_SPLIT_THRESHOLD_BYTES`(20GB) ·
`OPENLIST_SPLIT_PART_BYTES`(1GB) · `OPENLIST_7Z_VOLUME_SIZE` · `OPENLIST_ERR_LOG_MAX_BYTES`

**超时（秒）**：`OPENLIST_PROBE_TIMEOUT` · `OPENLIST_RCLONE_LISTING_TIMEOUT` ·
`OPENLIST_DOWNLOAD_TIMEOUT` · `OPENLIST_UPLOAD_TIMEOUT` · `OPENLIST_TOKEN_REFRESH_SECS`

**重试与阀门**：`OPENLIST_8005_RETRY_ATTEMPTS` · `OPENLIST_423_RETRY_ATTEMPTS` ·
`OPENLIST_409_RETRY_ATTEMPTS`（2026-09-17 加，与 423 同款：409/mkParentDir 失败重跑整次 sync）·
`OPENLIST_PERSIST_RETRY_ROUNDS` · `OPENLIST_MISSING_FIX_MAX`(200) ·
`OPENLIST_MAX_SPLIT_ATTEMPTS` · `ROTATION_MAX_CONSECUTIVE_ATTEMPTS`(8)

**409 语义开关**（2026-09-17 加）: `_FIX_MKDIR_409_SEMANTICS`（默认 1=开；0=回退旧行为）。
开启时 mkdir 报 409 会先用 `lsd` 读操作复核目录是否**已存在**，存在即按幂等成功放行 ——
409 在 MKCOL 语义下常见含义就是"资源已存在"，旧行为一律判失败会导致整轮零落盘
（run `35186977864` 实测：2062 次 409、成功率 0%）。
⚠️ **该修复在生产轮从未被触达**：主轮 `35239780581`（含本修复）实跑 5h34m 后 timeout，
放行分支日志 **0 次**，而 `409 Conflict` 仍 1876 次 ⇒ **开关保留但收益未经证实**。
诊断 `35239688191` 也没能在 `wopan175` 上复现 409（与主轮后端不同，不能互相推断）。

⚠️ **「目录可写性预检是误判源」这一归因已被生产轮证伪**（2026-09-18，主轮 `35308273431`）：
按该归因做的三态解耦（`296a3c3`）在真实故障现场 **一次都没触发**
（`exists_but_readonly` = 0 次，`兜底终止` = 2 次）——因为那个短哈希目录
`API mkdir` 报 `HTTP_CODE:200` 但 `lsd` 仍读不到，**目录根本没建出来**，
判 `unwritable` 是**正确**的。⇒ 三态逻辑没错，是它治的病不对：
它治「建得出但写不进」，而生产病是「**兜底目录本身也建不出**」。

🔑 **★★ 当前主攻方向：查清「`API mkdir` 报 200 但目录不落盘」**（2026-09-18）。
这是所有"换目录"兜底（短哈希 / 跳出故障子树）的**共同前提** —— 只要它成立，
换到哪儿都建不出。⚠️ **待解矛盾（未解前不要改修法方向）**：在 `5/` **直属**层新建
4 个无关目录**全部真成功**（`35294896071`/`35295178274`），而在 `5/<深层>/` 新建
**全新名字**的短哈希目录**建不出**（`35308273431`）⇒ 差异疑在**层级/深度**
或**健康窗口**，需一轮按深度分层的同构实验分离这两个变量。
（详见计划文档 §12.14.6）

⚠️ **2026-09-18 定向诊断补充（三轮递进，判决已下）**：
- 探针写失败**确实**只是复现同一条 409 路径（`35289924584` W1）；「后端不可写」被否定
  （已存在目录写入 rc=0）；「绕开隐式 mkParentDir 即可写」也被否定（`--no-check-dest` 仍 409）。
- 失败**定位到故障路径的第二层目录**（`35291770701`）：该层 `mkdir` 回报成功但 `lsd` 查不到
  （**mkdir 假成功**），且其下兄弟目录**全部 409** ⇒ 故障污染整棵子树；与末层文件名无关
  （原样名在隔离处能正常建）。
- ★ **「通用缺陷」已被否定**（`35294896071` / `35295178274`，两轮独立）：在**同一挂载的同一层**
  下新建 **4 个互不相关的顶层目录，全部真成功**（rc=0 · 409=0 · lsd 存在=1）。同一时刻故障
  子树仍一律 409（`35295422027` 与 `35291770701` 逐字同构，可复现）。
- ⚠️ **但上一条与 `35308273431` 的深层失败表面矛盾**（见上"待解矛盾"），**尚未收口**。
⇒ **定性：这是该子树路径局部的坏状态，不是挂载级、不是名字相关。**

🔀 **兜底目录跳出故障子树（方向成立，但已暂停）**：现有短哈希兜底目录落在同一棵坏子树里，
故同样 409。但取证 run `35306329978` 实测该 `dest_path` **自身可写**、故障**未复现**
⇒ 对照无判别力，**暂停改动**（详见计划文档 §12.14.5）。

⚠️ **不要把 `OPENLIST_DRIVER_READY_WAIT` 调短**：生产已盲等 **70s**
（驱动就绪 60s + 路径刷新后 10s），而实测就绪只需约 10s
（`重启后写入: +0s=FAIL() +10s=OK +30s=OK +60s=OK`、`列表可见性: 首次非空=10s`）。
调短会引入新的时序脆弱性。详见计划文档 §12.14.4。

✅ **`note` 语义已分档**（2026-09-18，`296a3c3` 改动 3）：原 `已重启确认` 拆为
`-可写` / `-写入失败` / `-读取失败`；**后端熔断只认 `-写入失败`**（"读取失败"可能只是
重启后列表未就绪；`exists_but_readonly` 更不该计入——它是"建不出目录"而非"后端不可用"）。

同一轮探针的其它结论（用于排除）: 名长 32–128B / 父目录名长 10–60字 / 路径深度 d1–d5 /
覆盖写 / 子目录写 / 大文件 16–256MiB **全部通过**；并发 423 是**父目录 mkdir 竞争**
（已存在目录并发 OK、新目录 `retries3` OK），重试可解；吞吐 4 流 2.06 MiB/s、
出口基准 22.71 MiB/s（瓶颈确在 wopan 侧）。
**生产补充（2026-09-22，详见计划文档 §0「423 Locked 对接注」）**: 423 不止 mkdir 竞争——
已存在目录的 copyto 同样会 `Locked: 423`，且 12 流满负荷窗口内 retries=3 不可解；低并发
时段同后端正常。定性为**网盘限流的伴生现象**（与 12 流吞吐拐点同源，勿开新排查），
重试 + fold 兜底实战吸收中；仅当连发到熔断阈值才重估。
~~唯一待查新线索: 字符集阶梯里最贴近生产真实文件名的"混合"档 FAIL(405)~~
→ ✅ **已撤回**（2026-09-18 复核）：该档用的是**真实失败名逐字复刻**，本质是 §11.8
已定性的「特定目录名本身写入失败」（该名字搬到全新位置仍 405），**不构成新维度**。
生产兜底路径亦印证方向：`目录级兜底: 根目录折叠为短哈希目录` 之后**仍 409**
⇒ 兜底仍落在同一棵坏子树里。

`OPENLIST_MKDIR_FAIL_STREAK`（默认 3，0=关）: 同一后端**目录层**连续 N 个文件建不出目录
即收手跳过剩余文件（区别于方法层失败，不会误伤健康后端）。

**后端级熔断**（2026-09-12 加，见下方「后端级熔断」）: `OPENLIST_BACKEND_WRITE_PROBE`(1=开启) ·
`OPENLIST_BACKEND_WRITE_PROBE_TIMEOUT`(60s) · `OPENLIST_BACKEND_DEAD_THRESHOLD`(3，同挂载根连续几个目录判不可写即判后端死) ·
`OPENLIST_DIR_PROBE_MAX_RESTART`(3，目录探测的每轮重启预算)

**并发**：`OPENLIST_TRANSFERS`（workflow 输入 `transfers`，**默认 6**——2026-09-15 隔离实测拐点在 12 流）· `OPENLIST_CHECKERS` ·
`OPENLIST_SUBDIR_PARALLEL`（workflow 输入 `subdir_parallel`，**默认 2**；≥2 时顶层 auto-split 子目录并行同步，递归层始终串行）·
`OPENLIST_PAIR_PARALLEL`（workflow 输入 `pair_parallel`，**默认 2**；≥2 时按挂载根分组、跨后端并行同步对，同后端仍串行）·
`OPENLIST_SUBDIR_LIST_PARALLEL`（子目录大小列举并行度，默认 8）·
`OPENLIST_CONTAINER_LOCK`（容器读写锁文件，默认 /tmp/ol_container.lock——传输持共享锁、容器重启持独占锁）

**时间预算（优雅到站）**：`OPENLIST_SYNC_BUDGET_SECONDS`(19200=320min，同步 step 启动锚点) ·
`OPENLIST_SYNC_MIN_SLICE_SECONDS`(600=10min，剩余预算低于此不再开新工作) ·
`OPENLIST_PAIR_MIN_SLICE_SECONDS`(1500=25min，单个并行同步对的公平份额下限，见「单对份额」) ·
`OPENLIST_REPAIR_RESERVE_PCT`(25，上限 60；子目录循环预留"预算×此比例"给修复管线尾段——不预留则修复被饿死、长尾不收敛，见计划文档 §12.9) ·
`OPENLIST_SYNC_DEADLINE_EPOCH`（由 workflow 计算，调试/还原模式不设置=不干预）

**开关**：`FORCE_SYNC` · `OPENLIST_SPLIT_ON_SYNC_FAILURE` · `OPENLIST_TASK_ROTATION` ·
`OPENLIST_SKIP_ESTIMATE`（=0 关闭跳过通知的"本次未传"现场估算，只复用预览缓存）·
`OPENLIST_BATCH_CONSOLIDATE` · `OPENLIST_HASH_DIR_FALLBACK`（=0 关闭短哈希目录兜底）·
`OPENLIST_DIR_PROBE_MAX_RESTART`（目录可写性预检的每轮重启预算，默认 3）·
`OPENLIST_DIR_PROBE_TIMEOUT`（预检探针超时，默认 120s）·
`OPENLIST_WRITE_REPROBE_INTERVAL`（F22 写探针周期性重探间隔，默认 1800s；≤0 关闭）·
`OPENLIST_405_FAST_FAIL_MIN`（F10 单批 405 计数阈值，默认 20；=0 关闭）·
`OPENLIST_409_FAST_FAIL_MIN`（409 死目录判据阈值，默认 20；=0 关闭。批内与子目录级 sync 两处
同款: 409 计数达阈值 **且** 零字节零 Copied ⇒ 确定性建不出父目录，跳过重试直接交修复管线）·
`OPENLIST_PREVIEW_LISTING_TIMEOUT`（F17 预览 listing 短超时，默认 240s，**必须带单位**）·
`TASK_PREVIEW_ONLY` / `TASK_REGISTER_ONLY`（由 workflow 设置）

---

## 运行模式

workflow 的 `run_mode` 单选互斥：

| 模式 | 行为 |
|---|---|
| `同步` | 预览（可 `skip_preview` 跳过）→ 全量同步 |
| `调试 · 修复管线测试` | 只跑指定任务的修复管线 |
| `⚠️ 还原 · 修复文件还原为原路径` | `restore_fixed_files`（改名类走 `rclone copyto` 复制回原路径并**保留备份副本**——2026-09-26 起弃用 moveto，副本是短哈希体系下唯一内容载体；也不能用 copy/move：它们会把 dst 当目录、建出以目标文件名命名的目录） |
| `⚠️ 灾难恢复 · 目标端→源端` | `restore_source_from_target`（非破坏性） |
| `⚠️ 灾难恢复 · 目标端→源端（删除源端多余文件）` | `rebuild_source_from_target`（**破坏性**） |

带 ⚠️ 的三项会改写目标端或回传/删改源端，运行前核对 `restore_task` 任务名。

### 一键还原 try run（只读预演）

真跑「⚠️ 还原」之前先看一眼会怎么走，走 **`openlist-restore-tryrun.yml`**（独立 workflow，
独立 concurrency，**一个字节都不写**）。全量核对（`check_exists=是`）实测约 40 分钟
（4684 条 × 逐条真实远端列举 ≈ 0.48s/条），故 job 上限给到 300 分钟；`check_exists=否` 时
不拉容器、纯 marker 推导。⚠️ 但「分钟级」只对少量 marker 成立 —— 当 marker 累积到
482 个 / 1949 条目（2026-11-26 实测峰值），`task=all` 纯推导也要 **30 分钟以上**
（run 45732745581），不是卡死：要快速体检就传 `task=<前缀>` 或 `within_days=N` 缩小样本。
逐条给出三条完整路径 + 一条交叉核对路径：

| 字段 | 取值 |
|---|---|
| ① 备份文件（目标端现存形态） | `<dest_path>/<alternative>` |
| ② marker 记录的原文件 | `<dest_path>/<original>` |
| ③ 实际执行还原的完整路径 | 改名类 = `rclone copyto` 的 dst（= ②，复制回原路径并保留备份副本）；分卷类 = 本地合卷解压产物 `copyto` 的 dst（= ②，分卷同样保留）；`alt==orig` 记为 noop（只校验存在，不搬） |
| ④ 源端原路径（灾难恢复口径） | `<source_path>/<original>` |

另核对「备份文件在不在 / 原路径是否已存在」。**两个"在不在"都各走两条判据**：列列举
（目录清单缓存）为初判，判"缺/不在"时再逐条 `lsjson` **直读**复核，分歧以直读为准
（OpenList 对新建目录/文件有列表缓存延迟，§0：只靠列表会把成功判成失败）。报告分两行记
「直读复核」与「直读复核（原路径）」各自的翻案数 —— 混成一个数就分不清是哪一侧的列表
不可信（`test_restore_tryrun.sh` 场景 11 / 16 锁住）。

**备份判缺失时还会做一次结构探针**（只读 `lsf --dirs-only`，场景 17 锁住）：把"缺失"
拆成三层可判 —— ① 替代目录（短哈希目录）到底建没建 ② 建了的话里面是不是空的
（空 = 文件压根没落；非空 = 落盘了但名字对不上，两种修法完全不同）③ 源端同层形状对照
（`source_path` 同层子目录一并列出，两侧形状同屏才判得了"差集 0"这类表面矛盾）。

零写入是**结构性**保证：预演模块所有
远端调用走只读白名单（只放行 `ls/lsd/lsf/lsl/lsjson/cat/size/version`），写子命令一律拒绝
执行（`test_restore_tryrun.sh` 场景 4/5 锁住）。入参 `check_exists=否` 时只做 marker 推导、
不拉起容器（秒级），三条路径照样准确，仅存在性显示「未核对」——**不会**把"没起容器"
误报成"备份丢了"。

**时间窗（入参 `within_days`）**：`0`/留空 = **全量**（默认）；填 `N` = 只预演**最近 N 天**
产生的 marker。为什么要这个口径：还原失败的条目会**留在 marker 里不删**，marker 只增不减，
攒几周后全量里的绝大多数是早已失效的旧记录，把「备份缺失」数抬得很高却不是当前问题 ⇒ 想看
"最近几轮到底有没有真缺"必须按时间窗筛。**取不到时间戳的 marker 一律跳过并明示**（无法证明
它新 = 不放行），报告与通知各记一行「扫描 N 个 · 跳过超窗 X 个 · 跳过无时间戳 Y 个」——否则
"筛完缺失变少了"会被误读成"问题消失了"，实际只是样本变小了。

时间源: **marker 自带的 `last_success`**（UTC，写 marker 时落盘）为主，远端 ModTime（`lsl`）
兜底 —— 实测 **OneDrive 的 `rclone lsl` 返回 0 行**（该后端不吐 ModTime 列表），只靠 ModTime
会让筛选在生产上整体失效。
⚠️ **一个时间戳都取不到时视为机制失效 ⇒ 回落全量并告警**，绝不产出「条目 0」——那个"零"会被
读成"最近没缺"，实际是根本没测。

**绝对下界（入参 `since`）**：`YYYY-MM-DD` 或 `YYYY-MM-DDTHH:MM:SS`（UTC），只看该时刻
**之后**产生的 marker。为什么 `within_days` 不够：判「新旧 marker 是否不兼容」要切出
**全都是新语义写的**那一批，而语义变更是一个**时刻**（最近一次改写 marker 语义的是
`e90118e` 2026-09-19T11:03:00Z，还原命令 `move`→`moveto`；更早 `137c005` 2026-09-16
统一方法命名），相对天数会把该时刻**之前**的旧语义 marker 一起放进来 ⇒ 样本不纯、结论不可判。
与 `within_days` 同时给时**取更严者**（两个下界都满足才放行）；解析不出格式 ⇒ 大声告警并
**回落全量**（宁可多跑，也不假装筛过）。报告头与汇总行都会打印「绝对下界」与
「生效下界 `<ts>` UTC」，方便核对这一轮到底看了哪些 marker。

**⚠️ 唯一的例外入参 `reset_markers`（关 / dry / commit）**：会**删** `onedrive:/logs/sync_state`
下的 marker —— 先打包归档到 dropbox（`sync_state_reset_<时间戳>.tar.gz` + `MANIFEST.txt` 自证），
**归档失败即拒绝清空**；两道判据（列表非空 + 下载数 ≥ 列表数）与 `backup_sync_state_to_dropbox`
同口径，避免"空包覆盖好备份"。默认 `dry`（只打印将删多少、归档到哪），必须显式选 `commit` 才真删。
它不是预演的一部分：选中后**独占本次运行**并提前退出（也不拉容器），日志形态与只读轮完全不同 ——
"这轮到底删没删"不该靠回忆当时选了什么。

---

## 结论级判据（踩过的坑，改动前先读）

这一节是从 2026-09 那轮专项修复里沉淀的**结论**，不是过程记录（过程已归档到
[`docs/archive/`](docs/archive/README.md)）。它们回答"为什么这里要这么写"，
照做可以避免重踩已花过很大代价才定位的坑。

### 1. 吞吐天花板：1.2 MiB/s，工程外，别再折腾

瓶颈是 **runner → 国内网盘的国际链路，且多个后端共享**（实测跨后端并行合计 0.50 <
单后端 1.20 MiB/s，并行不仅无增益还有害）。管线侧仅剩约 **2× 利用率**空间，
绝对上限就是 1.2 MiB/s，**不是 4–8×**。
⇒ 想真正提速只能改网络路径（境内 runner / 对国内路由更好的代理），属于工程外。
看到"同步太慢"先对照这个数，别在参数上反复试。

### 2. 判据纪律：以列表为准的判据，必须直读交叉验证

OpenList 对**新建**目录/文件的列表有缓存延迟（实测首次可见 ~10s，等 15s 仍可能不可见）。
用"列列举里有没有"判"在不在"，会把**成功判成失败**。
正解是**直读判据**（按全路径 `lsjson` stat）。

⇒ 凡是拿列表当结论的地方（副本在不在、源端在不在、目录建没建成），都要有一条独立的
直读判据交叉验证。**出账/删除这类不可逆动作尤其如此** —— 一次列表假阴就会把"其实还在"
的记录当失效删掉，而短哈希不可逆 ⇒ 删了就再无自证能力。

### 3. 硬顶闸纪律：装在阻塞函数**内部**

可能长期不返回的代码（轮询 / 等待 / 单次长任务），其内部必须有**周期性硬顶复查**，
并把结果通过**返回值**传给调用方收摊。
装在调用点前的闸只能查到"进入那一瞬间"，进入后就再也查不到第二次 —— 这正是当初
"预算正常到点却又耗到被平台硬杀"的成因（连续六处无界点都是这个形态的变体）。

### 4. 还原语义：保留副本 + 出账须双判据 + 真还原须过门禁

- **保留备份副本**：还原用 `copyto` 而非 `moveto`（搬走即删副本）。副本是短哈希体系下
  唯一内容载体，删了会让下次预演把"已还原"误报成"备份缺失"。
  同理，同步轮的「已对齐收尾」也**默认不删**替代形态（`OPENLIST_CARRY_DELETE_ALIGNED=0`）。
- **出账不可逆** ⇒ 副本侧与源端侧判据都须双判据。
- **真还原必须先过门禁**（见上节）。

### 5. 改完立即提交：未提交的改动会被远端并行推送冲掉

本仓库会被并行推送。一次远端 merge 曾把本机改动整段吞掉，而**回归套件仍然全绿** ——
因为被吞掉的恰恰是**测试自身**（防护丢了，自然没人报错）。
⇒ 判断防护是否还在，只能查**防护本身是否存在**，不能看测试是否通过。

---

## 传输趋势与接力

**跨 run 传输趋势（P0 可见化，`sync_trend.sh`）**：回答"照现在的速度还要多久传完"。
预览 pass 后把全量未传量（`PREVIEW_PENDING_MAP` 合计）落盘，每次实际传输累计净传字节
（两个记录点：`_sync_task_finalize` + 最终完整同步尾部，无重复计数），收尾 step（always()，
被取消的 run 也执行）追加 `{时间戳, run_id, 历时, 净传, 剩余}` 到
`onedrive:/logs/sync_state/trend.jsonl` 并发送「📈 同步趋势」通知（近 5 轮净传速率 +
剩余 + 预计清零）。`trend.jsonl` 读改写三情形：远端不存在→创建 / 存在→追加 /
读取失败→放弃回传只发通知（宁丢一条样本，不覆盖历史——同 marker 过期副本防护原则）。
`skip_preview=true` 的 run 剩余量记为未知，趋势速率不受影响。
📊 **`trend.jsonl` 各字段的口径（读之前先看这段，否则极易误读）**:

| 字段 | 真实含义 | 容易误读成 |
|---|---|---|
| `transferred_bytes` | 本轮经 rclone 的**净传输**字节 | 「已同步数据总量」——实际含重复传输 |
| `missing_files` | 本轮缺失文件**去重**数（事件日志 `MISSING\|` 口径） | 「还差多少文件」——只是本轮观测到的缺失 |
| `fixed_files` | 本轮 **fix_list 去重条目数**，**含「沿用上轮」** | 「本轮修好了几个文件」——实际的「真新落盘」要看收尾日志里的「新落盘」 |
| `pairs_total` / `pairs_synced` | 本轮注册对数 / **真正跑完**的对数 | 「跑了多少对」——`pairs_synced` 只算写成 marker 的 |
| `remaining_bytes` | 剩余字节；`skip_preview` 轮恒 `null` | ——（跳过了预览就拿不到，不是 0）|

`fixed_files` 的坑最实际: 它取自 `/tmp/ol_round_stats.env` 的 `ROUND_FIXED_OK`（**原始累计值**），
而收尾日志里「新落盘」是另一路计算（`_sync_accumulate_fixed_results` 已剔除沿用条目）。
所以 `fixed_files:13` 配「新落盘 0 · 沿用 568」是对的 —— 13 是去重条目数，不是新落盘数。
要判断「这轮真的修好了多少」必须看收尾日志的「新落盘」，不能只看 trend 的 `fixed_files`。

**同步对完成度（2026-11-25 补）**: 趋势此前只有「传了多少字节」，答不了「同步完没完」——
  `skip_preview=true` 轮 `remaining_bytes` 恒 null。现由并行汇总把
  `PAIRS_TOTAL / PAIRS_SYNCED / PAIRS_TRUNCATED / PAIRS_FAILED / PAIRS_SKIPPED`
  落 `/tmp/ol_pair_stats.env`（跨 step 只能走文件），收尾写入 trend.jsonl 的
  `pairs_total / pairs_synced` 两字段，并在趋势通知输出「同步对完成度 X/Y」。
  「完成」只认**真正写成 marker** 的对（目标端文件数已达源端）；到点交棒、失败、
  配额跳过分别单列，均不算完成。无数据（串行模式/旧样本）时字段写 null、通知不渲染该行，
  读侧 `.get()` 兜底，历史样本不受影响。

📊 **吞吐基线（2026-11-25 按 trend.jsonl 50 个完整预算轮实测）**: 排除为取日志而调短预算的轮次后，
中位 **16.7 GiB/h**、均值 24.6、区间 **0 – 99.7**。分段看差异极大 —— 11-13~11-15 多在 2–18，
11-18~11-19 连续四轮跑到 **55–99 GiB/h**（336–450 GiB/轮），11-19 之后回落到 5–55。
对照同期的 `OPENLIST_TRANSFERS=6 / SUBDIR_PARALLEL=2 / PAIR_PARALLEL=2` **完全一致**，
⇒ 吞吐的 5–10 倍波动来自**后端限速与负载**，不来自并发参数。
**推论（写下来防误判）**: 任何「提速 X%」的结论都不能用单轮/相邻两轮对比得出 —— 必须看多轮中位数。
本仓的提速改动属于**消除结构性浪费**（公平份额按并行度折算、快照段删掉只写不读的每文件列举、
复核改单次 lsf），省的是**确定的时间**；能否跑到 50+ GiB/h 取决于后端当时状态，不由代码决定。
🐢 **为什么「同步完不成」——机制拆解（2026-11-25 实测，16 对逐对核对）**

用 `onedrive:/logs/sync_state` 的 482 个 marker 逐对核对 16 个注册同步对，结果:
**只有 1 对**（`task0-baidupan`，301.5 GiB/2636 文件）在 24h 内写出过 `last_success`；
其余 15 对要么**从未**写出、要么已超 24h。直接后果:

1. 顶层对的 `--1d-skip` 判据是 `last_success` 在 1 天内（`check_sync_marker`）。没有时间戳
   ⇒ 该分支打「标记无时间戳」并**无条件继续同步** ⇒ 这 15 对的**顶层**每轮都要重列。
   ⚠️ 但**不是**「每轮全量重传」: `check_sync_marker` 在 `_sync_task_impl` 里是**递归**
   执行的，`--auto-split` 拆出的子目录各自也有 marker；已完成且 24h 内的子目录会被
   跳过（实测 run 45542724284 有 **50 次**「24小时内已成功同步，跳过」）。
   所以真实成本是「顶层全量列举 + 未完成子目录重传」，不是全部重传。
2. 顶层 marker 的判据是「目标端文件数 ≥ 源端」的**精确**相等。只要还有 1 个修不好的
   文件（内容性拒收 / 密文名超限 / 目录建不出来），`last_success` 就永远不写 ⇒ 上述循环
   无法自解。实测缺口最大的子树: `onedrive:3/1024j-视频-pornhub-channel` →
   `openlist:wopan176Crypt/...` 目标端 52 / 源端 422（缺 370，连续 23 轮未补齐）。
3. 于是每轮 320min 预算主要花在「顶层重列 + 未完成子目录」上，真正的日增量只占一部分。
   轮转游标能保证每对都被服务到，但「服务」不等于「收敛」—— 收敛的瓶颈是那些
   **永远补不齐的子目录**（内容性拒收），它们让顶层 `last_success` 永远写不出来。

**结论与出路（按代价从低到高）**:
- 先看收尾的「缺口归因」行（`sync_marker.sh`）: 若缺口 ⊆ EXHAUSTED 台账 ⇒ 该对已尽最大
  努力，问题在**后端内容性拒收**（需人工改名/换后端），不是同步逻辑；
- 若台账外仍有缺口 ⇒ 继续用修复管线追（`openlist-fix-check` 可对单棵子树定点验证）；
- **不要**为了让它「看起来完成」而放宽精确校验 —— 那会把「缺 370 个文件」伪装成同步成功，
  代价是数据静默丢失。

⏱ **「marker 多久没更新算正常」—— 实测基线（2026-11-25）**: 单轮内 marker 写入间隔**不是均匀的**。
按 run 45542724284 的全部 marker 写入时刻统计，最长间隔达 **58 分钟**（其余 51.9 / 48.4 / 34.1 / 23.4 / 21.8 分钟）。
原因: marker 只在「一个同步对或子目录整体完成」时才写，而大目录单次传输可跑 30–60 分钟。
⇒ **半小时内没有新 marker 不代表卡死**；判断是否卡住要看别的信号（如同轮其它 marker 的时间分布、
`task_rotation.json` 是否推进），不要仅凭「marker 静默」就重启或干预。

⏰ **cron 兜底实际不可靠 —— 别把它当续命机制（2026-11-25/26 实测）**:
`.github/workflows/openlist.yml` 配的是 `0 */3 * * *`（期望每 3 小时），但按最近 12 次 `schedule`
触发的实际间隔统计: **最小 4.0h / 中位 8.3h / 最大 12.5h**，中位是期望的 **2.8 倍**。
GitHub 对高频 cron 的限流是平台行为，不是 workflow 配置问题（仓库早期已实测 `*/5` 曾 4.5h 零触发）。

⇒ **真正的续命机制是「自续触发」step**（每轮收尾 dispatch 下一轮），cron 只是它失灵时的慢兜底。
推论（与「环境未就绪告警」配套）: 一旦自续触发因前置步骤失败而按设计不接力，
下一次运行可能要等 **4–12 小时**；这期间系统完全静默。所以那种情况下的 alert 不是「锦上添花」，
而是**唯一能让故障被人看见的通道**（run 45651997160 停摆 8 小时即因缺少该告警）。

📉 **「已传 1.05× 源端总量」不等于「都传过了」—— 两个数字必须一起看（2026-11-25 实测）**:
`trend.jsonl` 60 轮累计净传 **6.08 TiB**，而 marker 汇总的源端总量是 **5.78 TiB**（1.05×）；
但同一天按 marker 的 `last_refusal` 统计，仍有 **9 个 marker / 合计 22,196 个文件**处于缺口状态:

| 缺口文件 | 连续轮数 | 子树（dest） |
|---|---|---|
| 14,904 | 2 | `openlist:wopan176Crypt/1/1024j/视频` |
| 3,976 | 11 | `openlist:wopan176Crypt/1/1024j/套图` |
| 2,298 | 1 | `openlist:wopan176Crypt/4/1024j-视频-pornhub-channel` |
| 370 | 23 | `openlist:wopan176Crypt/3/1024j-视频-pornhub-channel` |
| 329 | 1 | `openlist:wopan175/4/1024j-视频-pornhub-channel` |
| 149 | 9 | `openlist:wopan175/3/1024j-视频-pornhub-channel` |

两者不矛盾: **重复传的是「能传的」，缺的是「传不上的」**。累计量超总量说明重复传输已超 5%，
而缺口是另一批文件。⇒ 判断「同步完没完」**不能只看累计字节**，必须同时看缺口文件数。
提速的正确方向也因此不是「提带宽」，而是「降低重复传输比率 + 清缺口」。

🎯 **「同步对完成度 1/16」—— 单轮完成率的实测真值（run 45623471576）**:
该轮收尾打出的完成度行是: **`1/16 个真正同步完成（到点交棒 10 · 失败 5 · 跳过 0）`**，
trend 里同源字段为 `pairs_total:16 / pairs_synced:1`。拆开看:

| 状态 | 对数 | 占比 | 含义 |
|---|---|---|---|
| 真正完成 | 1 | 6% | 该对在本轮内跑完并通过精确校验 |
| 到点交棒 | 10 | 63% | 份额用尽被截断，下轮从头再来 |
| 失败 | 5 | 31% | 本轮内报错 |

**这就是「同步慢」的机制层答案**: 320min 预算 ÷ 16 对 ÷ 2 并行 ≈ 每对 30min，
而大多数对的单轮工作量远超 30min ⇒ 63% 的对每轮只能推进一段、然后重来。
所以「提升同步速度」的真正杠杆不是提带宽，而是**减少被截断的对数**：
要么让对更少（按子树拆细、让小的先完成），要么让每对拿到更长的不间断时间。
⚠️ 但两者都会改变轮转公平性 —— 动之前必须实测，不要凭直觉调 `OPENLIST_PAIR_PARALLEL`。

🔴 **`wopan175` / `wopan176` 的 403 是 WoPan 边缘 WAF 瞬时拦截，不是账号掉线（2026-11-26 更正）**:

**一段被推翻的诊断，记下来防重犯**: 00:32Z `storage_alert.json` 记录两个挂载
`initialize user data: request failed with status: 403 Forbidden`，我曾据此判定「账号登录态失效、
必须人工重新登录」，并因此把目标标记为 blocked。**这个结论是错的。**

**用户实测（直连复刻驱动同协议 dispatcher）**:
- `/wopan175` token → `FamilyUserCurrentEncode` 返回 `0000`，解析账号 17575020502（家 id 86044881）
- `/wopan176` token → 同样 `0000`，账号 17675740502（家 id 80929434）
- 两个账号 `AppQueryUser` 均 `0000` 成功
- 线上实例当时已恢复: `/wopan175` `/wopan176` `/wopan176Crypt` 全部 `status=work`，
  `/wopan175` 列举 `total=7361`

⇒ token 有效、账号在线，403 来自 **WoPan 边缘 WAF 的瞬时拦截**，会自愈，**不需要重新登录**。
（重登反而有害: wopan 重抓登录会跨端互踢，可能把健康挂载踢下线。）

**自愈的独立佐证（本会话自行核对）**: 之后 `storage_alert.json` 已变回 `{}`（巡检自动销账，
说明失效条目消失），`wopan175` 的 `last_success` 已推进到 `2026-11-26T04:29Z`。
（`wopan176Crypt` 当时仍停在 11-25 09:23Z，但那是轮转尚未服务到，不是账号问题。）

**影响面与代码侧（事实部分保留）**: 16 个注册同步对里 14 个（87.5%）目标端在这两个后端，
所以 WAF 拦截期间本轮 2h20m 只写 14 个 marker（健康轮 61 个）。代码侧无需改动:
`_check_openlist_backend_connectivity`（`openlist_driver.sh:351`）做两层校验 + Crypt 底层 +
写探针，`_openlist_api_health_check` 对 `request failed` 返回 1 ⇒ 该对跳过本轮
（`sync_engine.sh:397`、`task_engine.sh:3035` 已接入），**不白传大文件**；恢复后自动继续。
该判定是弱证据，按 `_backend_dead_mark` 设计不写 `backend_dead.json`（防历史上
「弱信号把健康 wopan175 判死、6 个对整体被跳过」的误判重演），代价是每轮重探但不浪费带宽。

**教训（最重要）**: `storage_alert.json` 里的 403 **只说明「当时那次探测被拒」，不等于「账号掉线」**。
下结论前要区分三类: ① 凭据真失效（同协议 token 调用也失败 / 持续多天不恢复）；
② WAF 瞬时拦截（token 调用正常、短时自愈）；③ 路径特异性拒写（挂载根可写、个别目录不可写）。
**不要用 `storage_alert` 单项证据就把目标判成 blocked** —— 先按驱动同协议复验 token，
或等一轮看是否自动销账。本次就因为跳过这一步，错误地要求用户重登、并误判了 10 轮。

✅ **判断后端真状态: 三种「无新 last_success」要分开（2026-11-26 实测）**:
WAF 恢复后观察 `wopan176Crypt`: `last_success` 停在 11-25 09:23Z（22.8h 前），一度怀疑
「还没轮到」或「仍写不进」。核对 marker 后第三种解释才对:

- `task5_e6b6b1f4`（dest=`openlist:wopan176Crypt/5`）于 11-26 15:48 被**写入**;
- 它 `last_success=null`、但 `fixed_count=56`、`last_refusal=null` —— 这是**修复骨架 marker**:
  本轮真实修好 56 个文件（短哈希名直传如 `19fb67cc.mp4`，绕开长名/敏感字符拒收），
  但目标端文件数仍 < 源端 ⇒ 顶层精确校验不通过 ⇒ 不写成功戳。

⇒ **判断后端死活不能只看 `last_success`**。三层要分开:
  ① 有没有 marker 写入（有 = 在被服务）② 有没有 `fixed_count`（有 = 修复在产出且后端能写）
  ③ 有没有 `last_success`（有 = 整个对通过精确校验）。
「有①②无③」是**正常的收敛中状态**，不是卡死、更不是账号失效。
这正是 WAF 误诊的解药 —— 我此前把 ① 的缺失当成「账号掉线」、把 ③ 的缺失当成「后端不可写」，两次都错。

**优雅到站（P2）**：大任务常态撞 6h runner 上限被硬杀。现在同步 step 启动时设预算锚点
（`OPENLIST_SYNC_BUDGET_SECONDS`=320min），剩余预算不足最小工作片
（`OPENLIST_SYNC_MIN_SLICE_SECONDS`=10min）时不再开新同步对/子目录/最终完整同步，
做完当前即以 **success** 正常收场。跳过最终完整同步时不保存 pair 级成功 marker
（任务确实未完整）。被跳过的子目录 marker 已各自落盘，进度零回退。
🔒 **单批封顶（2026-11-04 补）**：批次 copy 的在途 timeout 此前只按「剩余预算 − 尾部预留」给值，
轮初可拿到 ~16166s（4.5h）—— run 41750655316 实证一个慢批次独占整轮，两个并行 worker
直到硬顶都没交回完成统计（收尾显示 0 个/0 B，却判 success）。现再对齐
`_batch_slice_effective()`（默认预算下 7200s，短轮等比缩放）封到单片上限；到点由 timeout
收掉后走巩固/修复/优雅收摊，剩余批次交下轮。硬顶放弃在途 worker 时同步对汇总行会显式
报出被截断的对数；收尾修复成效分母为 0 时打印「无可评估成效」而不再默认 100%。
⚖️ **单对份额（2026-11-10 补；2026-11-25 起分母按并行度折算）**：分发每个并行同步对时按
「剩余可用预算 ÷ ceil(尚需服务对数 ÷ OPENLIST_PAIR_PARALLEL)」给一份**公平份额**（下限
`OPENLIST_PAIR_MIN_SLICE_SECONDS`=25min，上限=剩余预算，并夹在平台硬顶之前）。为什么分母要折算：
份额公式里的预算口径是**墙钟**，而 par 路并行意味着同一分钟被 par 个对同时用掉 —— 按对数摊薄会把
整轮压成「每波(份额+宽限) × 波数」，轮末必然剩一段谁都派不出去的预算（run 45473411880 实证：
320min 预算 / 16 对 / 并行 2，收尾剩 35min 无处可派）。份额经环境变量 `OPENLIST_PAIR_DEADLINE_EPOCH`
传入 worker（子 shell 才可见），
由 `budget_deadline_epoch()` 与全局锚点取 min 后统一喂给**所有**预算闸（`sync_budget_stop`
/批次/子目录/修复管线/409 退避），在途单元的上限也夹到份额终点（`rc=124` 仍按部分成功）。
到点后该对收敛退出、把槽位交还调度器 ⇒ 一轮内所有同步对都能被服务到。
动因（run 42706236473 实测，sync step 322min）：21 个对只启动了 2 个，两者各自卡在停滞的
传输上（471.476 MiB 的流跑了 56min；12.323 GiB 的流 26min 只推进 17 MiB；**全轮 29% 的进度
样本是 0 B/s**），双双吃满预算被硬顶放弃 ⇒「本轮 0 个完成」、游标只前进 1 位；按每轮 2 个
对推算轮转一圈约 11 轮≈3 天，这是"同步完不成"的真实根因（该轮修复管线只占 7 次进入/22 次
方法尝试≈20-30min，不是主因）。份额到点交棒的对状态记为 `truncated`：既不算完成（不写
成功 marker），也不冒充后端失败。
⚠️ 尺度陷阱（已锁进单测 F 组）：批次闸要"够 2h 片长"、子目录闸要"够 25% 全局修复预留"
——若直接套用 25min 的份额终点，两闸恒真 ⇒ 连一个批次/子目录都开不起来、同步彻底停死。
故份额生效时各闸一律退到最小片(600s)当预留。

**自续触发（P2 接力）**：GitHub 对高频 cron 限流严重（*/5 实测曾 4.5h 零触发），
"常驻队列"假设不成立 → 本轮收场后「自续触发」step 用 GITHUB_TOKEN 立即 dispatch
下一轮（workflow_dispatch 是 GITHUB_TOKEN 可触发新 run 的例外事件，job permissions
含 `actions:write`）。三道护栏：仅同步模式且 `self_retrigger` 开启（默认开）；
人工取消不打架（同步 step 被 cancel 且 job 未到 6h 上限即 <5h50m → 判人工取消不接力）；
已有 queued/waiting 运行不重复触发。schedule cron 降为 `*/30` 只做兜底。

**全量冲刺期推荐**：`session_hold=false` + `self_retrigger=true` → 6h 窗口全部
让给同步，轮与轮之间零空窗；全量收敛后恢复默认。

> 开关读取口径（2026-09-12 修）：`session_hold` / `self_retrigger` **不能**在 `if:` 里写
> `inputs.x != false` —— cron 触发时 `inputs.*` 为空串、GitHub 松比较下 `'' == false` 成立，
> 条件恒为 false，两个 step 在所有定时运行里都是 skipped（run #12613~#12618 实测）。
> 现改为经 env 取默认值 `${{ github.event.inputs.x || 'true' }}`（字符串上下文，未触发时为
> null），再由 bash 字符串比较决定是否执行。

**后端级熔断（2026-09-12 加）**：同步预检原本只有读探针（`lsd` + `refresh=true` 的
API list），读得通但写不进的后端会被整轮放行——run #12616 实测 wopan175 读全正常、
写入恒定 `409 Conflict`，结果一轮 394 次修复全败、769 次「目录不可写」、231 次容器
重启/缓存刷新，5 小时零产出。现在两级拦截：

1. **写探针**（`openlist_driver.sh` `_backend_write_probe`）：按**「后端 × 路径」**分层缓存
   （2026-09-13 改；此前探在挂载根，而"挂载根能写 ≠ 任务子路径能写"，run 34728107625 实锤），
   探针落在**真实任务子路径**上（写几字节 → 刷服务端目录缓存 → 复核可见 → 删除），
   不可写即熔断该后端的全部同步对，把 6h 让给健康后端。
   ⚠️ 缓存键是**同步对路径**（如 `openlist:wopan176Crypt/2`），读取方必须用同一个键——
   曾按"后端根"读，键对不上导致判死信号**静默丢失**、死后端只能靠 8 次轮转上限脱身
   （≈44h）；2026-09-14 修（`sync_engine.sh` 两处读取 + `tests/test_backend_dead_signal.sh` 反向锁死）。
   ⏱ **探针结论有时效（2026-09-19 补，F22）**：探针只在同步**开跑前**跑一次，而「可写」
   结论**只对那一刻有效** —— 实测同一路径单文件顺序写 10 次全过、生产同路径 1034 文件
   全 405（失效随时间/量累积）。批次循环现已按时间（`OPENLIST_WRITE_REPROBE_INTERVAL`，
   默认 30min）`_backend_write_probe_invalidate` 清缓存再探（复用预检里那次探测，不新增次数）。
   🔪 **同时补上止损（F10）**：单批日志 `405 Method Not Allowed` 计数达
   `OPENLIST_405_FAST_FAIL_MIN`（默认 20）即判"该目录本轮写不进"，**先于批次巩固**中止
   剩余批次（历史一个坏目录逐文件烧 115min）。只数 405；**409 单列判据**（2026-11-03 起）:
   423 重试可自愈不判死，409 只在「计数达 `OPENLIST_409_FAST_FAIL_MIN` **且** 零字节零 Copied」
   时判死目录（超长名父目录确定性建不出；反例见 run 41568255043 逐月su 子目录 sync 2h 仅
   4 文件成功、487×409）。同一判据装在批次路径与子目录级 sync 两处。
   与 F5「后端写入全拒」（后端级、需触碰文件 100% 未落盘）互补：F10 目录级、更早更便宜。
   🔬 **F5 判死前的写探针反证（2026-11-05）**：F5 旧判据只看"重启复核后 100% 未落盘"，
   而"复核不到"有两种成因——后端真拒收，或**列表时滞**。后者已被两轮实锤：
   run `41863829407`（重传 70/70 → 复核全缺 → 判死，中止 14 批）与 `41892829794`
   （重传 9/9 → 141s 后复核仍全缺 → 判死），两轮的修复管线都在**判死后仅 26s**
   就把同样文件全部落盘成功（`✅ 落盘确认 尺寸匹配`）⇒ 当时后端完全可写，
   判死纯属假阳性，白烧整轮预算。现判死前必须真写一次 `_backend_write_probe`：
   只有 **`copyto` exit≠0**（405/423/网络）才算拒收并判死；"写成功但列表暂不可见"
   按**非全拒**放行（`_F5_PROBE_LENIENT=1`，仅 F5 调用点生效），真假成功交修复管线
   的落盘即时校验裁决。曾尝试的"等 120s 再复核一次"已被证明不足（141s 后仍全缺）
   且 15 批 ×120s ≈ 白吃 30min 预算（占 320min 的 9%），故移除。
   ☑️ **持久化复核三分口径（2026-11-25 补）**：容器重启后的逐文件复核不再把「列举报错」
   当「文件不存在」。探针输出三分——S=存在（带大小）/ M=确定不存在 / U=观测失败；
   U 既不算通过也不算失败、**不拉黑方法**（拉黑一个本来好用的方法 = run 45455001510 实证的
   445 文件批量误判）；复核 ≥5 条、0 通过、0 未定（rc=0 空列表的「成功的空」）整批判观测失真
   顺延下轮，不置 SYNC_PERSIST_FAIL。确定失败（M）才拉黑换方法。
2. **目录连续不可写计数**（`file_fix.sh` `_BACKEND_DEAD`）：开跑后才暴露的后端
   （预检偶发放行）由「同一挂载根连续 N 个目录被**重启确认**判不可写」捕获；判定后该后端
   剩余目录一律直接判不可写 —— 不探测、不重启、不跑 4 种方法。只认「已重启确认」的
   结论，缓存口径（预算耗尽/容器不可重启）不计入，避免误伤健康后端。

> **409 语义修正（2026-09-17，见上方「409 语义开关」）**：上面第 1 条提到的
> 「写入恒定 `409 Conflict`」**怀疑有相当一部分是误判** —— 409 在 MKCOL 语义下
> 常见含义是**资源已存在**（幂等成功），而旧代码一律归为「后端异常」并跳过整轮。
> run `35186977864` 复现同形态（2062 次 409、1088 次 `mkParentDir failed`、
> 成功率 0%、330min 超时），而**用户后台看驱动是正常的** —— 失败点在目录创建层，
> 预检与管理后台都不区分这一层。现已改为「409 先用 `lsd` 复核目录是否已存在，
> 存在即放行」，并给 409 补上与 423 同款的整轮重试、给目录层补上连续失败收手。
> ⚠️ **两点保留**：① 「409=已存在」**尚未被实测证实**（见上方开关段的诊断结论）；
> ② `35186977864` 的日志**现已过期、数值无法复查**，上述计数只作当时形态记录。

被熔断的同步对会让轮转游标**立即后移**（不等 `ROTATION_MAX_CONSECUTIVE_ATTEMPTS` 次），
死后端重试多少次都一样。收尾 step 打印 `本轮修复成效: 成功 X · 缺失 Y · 未修复 Z`，
`Y>0 且 X=0` 时额外输出 🚨 零成功告警 —— `conclusion=success` 不等于有数据落盘。

**删除语义（2026-11-02 镜像化）**：`rclone sync` 自带的清理阶段在 OpenList 上不可信——run 41196672258 /
41219905962 实锤两类误删：① 修复产物短哈希目录 `f27becd6` 被 `Deleted` + `Removing directory`（任务
拆分后旧 marker 记录孤儿化，filter 清单为空），同轮又重新折叠 97 文件；② WebDAV+crypt 超长文件名场景
同一条命令先 `Copied (new)` 后 `Deleted` 同一路径（幻影列举条目），84 分钟内 copy→删→copy 拉锯 3 轮。
故 2026-11-01 起 openlist: 目标端的 initial sync 改用 **`rclone copy`**（非 openlist 目标维持 sync）。
**2026-11-02 起目标端语义改为镜像源端**：copy 完成后由 `_sync_mirror_prune` 走**受控 delete 通道**——
双侧刚列举的新清单求差集找出"源端没有、目标端有"的候选，经三重保护后逐个 `rclone deletefile`。
**差集口径: 源端清单不加任务过滤**（镜像语义是「目标端 == 源端」，不是「目标端 == 源端∩本任务
--exclude」；用过滤口径会把 exclude 范围内的目标端文件误判成"源端没有"而越界删除）。保护:
① 排除清单（marker ∪ 本轮 ∪ 父级守卫）内的修复产物路径不删；② 顶层 8 位短哈希目录（折叠/短名
修复落点，还原链路唯一载体）不删；③ 单轮删除总量上限 `OPENLIST_MIRROR_PRUNE_MAX`（默认 200；
`OPENLIST_MIRROR_PRUNE=0` 整体关闭）。删除前对源端**再列一次**做复核（候选非空时才付这份成本；
逐候选各列一次的写法会让 200 个候选付 200 次全量列举，已禁止）。删除失败的候选下轮重试；清理是
附加能力，任何失败不置 SYNC_FAILED。marker/修复/还原链路不受影响；批次 copy、目录折叠、dropbox
镜像、灾难恢复 rebuild 的既有语义不变。

**吞吐调优（P1）**：`transfers`（**默认 6**）、`subdir_parallel`（**默认 2**）、
`pair_parallel`（**默认 2**）三者相乘即"单后端并发 PUT 数"（6×2=12，正好落在实测拐点；
跨后端那一路由 `pair_parallel` 另开一条挂载的额度）。三者都可按 run 调低：
若某轮出现 `object not found` / 假成功抬升，先降 `transfers` 或 `subdir_parallel` 回 1 观察一轮
"object not found" 率与修复管线触发量。2026-09-14 用户授权「transfers 可根据情况调整」，
但**前置依赖未解**：wopan176 当前驱动登录令牌失效（8005）、写入全拒，此时调 transfers
测不出吞吐差异——先解登录再调。

**后端可写性诊断（2026-09-14 加）**：主 run 单轮 5.5h、且被 `concurrency` 单例串行化，
"换个探针再跑一次"要排到几小时后；更要命的是主 run 日志里后端写失败只呈现为 OpenList
**包装后**的 `405 Method Not Allowed`（驱动层真实错误如 wopan 的 `8005 登录失败` 只落在
**容器日志**里，而容器日志从不进 run 日志）——于是「登录令牌失效」与「路径/名长被拒」
在 run 日志里长得一模一样。`openlist-diag.yml`（`workflow_dispatch`，**独立 concurrency
`openlist-diag`**，绝不与 `openlist-singleton` 互等）只做最小 setup：不装 cloudflared、
不接管隧道、不回传数据库，单次 ~4 分钟，跑四组探针：

1. **短名基线**（1 字节文件，写在真实任务子路径）；
2. **名长阶梯**（32/64/80/100/112/128 B，定位长度阈值）；
3. **覆盖写**（对应 rclone 的 `unchunked simple update`，与"新建文件"是不同代码路径）；
4. **子目录写**（验证"父目录名长连坐"假设）。

并把容器日志里的**原始 `rsp_code`/`rep_desc`** dump 出来。报告随 artifact `ol-diag-report` 上传。

**专项诊断（互斥，优先级从高到低；一次只跑一个，要的是"单一变量"的干净归因）**：
除常规 13 组探针外，`openlist-diag.yml` 还挂了 7 个专项入口，各自独立报告文件：

| 开关 | 脚本 | 回答什么 |
|---|---|---|
| `diag_l2` + `diag_l2_n=e` | `diag_escape_probe.sh` | 「兜底目录**跳出故障子树**是否真的可写」（E1 祖先层阶梯找最深可写层 / E2 同层对照**核心判决项** / E3 跳出层写文件 / E4 还原路径可行性） |
| `diag_l2` + `diag_l2_n=d` | `diag_depth_probe.sh` | **「层级/深度 vs 健康窗口」同构分离**（E1 同深度同形状对照：历史名 `5058f1af` vs 同深度全新名 / E2 沿生产真实故障路径的深度阶梯 / E3 **同轮内复测**历史名 → 窗口漂移自证 / E4 已存在目录可写性 / **E5 兜底落点真写入**：在真实落点 `dest_path/<hash8>` 写文件 + 全路径直读，判「建得出且写得进」vs「写不进」）|
| `diag_l2` | `diag_l2_probe.sh` | 新建顶层目录的 **mkdir 假成功**是通用缺陷还是个例（P1 普遍性矩阵 / P2 延迟落盘 / P3 重试自愈 / P4 已存在目录可写） |
| `diag_dirname` | `diag_dirname_probe.sh` | 「为什么这个特定目录建不出来」（D1 父层递进定位首失败层 / D2 末层名字 4 形态 / D3 同级兄弟） |
| `diag_writeprobe` | `diag_write_probe.sh` | 「探针写失败 == 目录不可写吗」（W1 复现 / W2 显式 API mkdir / W3 绕隐式 mkParentDir / W4 隔离目录） |
| `diag_409` | `diag_409_semantics.sh` | 409 是否等于「已存在」+ 改名回原名会不会蒸发 |
| `reject_src` | `diag_reject.sh` | 按内容拒收 vs 按文件名/状态拒收 |

⚠️ **`diag_escape_probe.sh` / `diag_depth_probe.sh` 的启动开关复用 `diag_l2_n`**
（分别填 `e`/`escape`、`d`/`depth`）：因为 inputs 已达 25 个硬上限（见下坑 1），
无法新增独立开关。其余取值仍按 L2 的"测试目录个数"解析，既有调用方式不变。

⚠️ **三个已踩过的坑（改本 workflow 前必读）**：
1. **`workflow_dispatch` 的 inputs 硬上限是 25 个** —— 超了不是"警告"而是派发直接
   `HTTP 422: you may only define up to 25 inputs`，即"加了开关却根本派不出去"。
   加新开关前先数一遍（当前**恰好 25**，新增必须靠复用既有位，如上面的 `diag_l2_n`）。
2. **不要在 step 级设全局 `DIAG_REPORT`** —— 它会被**所有**专项脚本继承，把专项报告
   统统写进 `report.txt`，而各分支收尾读的是 `<专项>_report.txt`，结果取不到文件
   （日志里表现为 `=========== <专项>报告尾部 =========== (无报告文件)`）⇒ **报告拿不到 =
   该轮白跑**。各脚本本就自带正确默认名，无需外部指定。
3. **专项脚本内的「可见性/存在性」判据必须带等待，且优先用直读** —— OpenList
   对**新建**目录/文件的列表有缓存延迟（实测首次可见 ~10s）。用"列列举里有没有"判
   "在不在"会把**成功误判成失败**（`diag_escape_probe.sh` 的 E4 首次就踩了这个坑：
   不带等待 ⇒ 误报"跨层 move 静默丢文件"；加 15s 等待仍不可见 ⇒ 最后改用
   **目标全路径 `lsjson` stat** 直读才翻案）。⇒ 凡"以列表为准"的判据，都要用一条
   **独立的直读判据**交叉验证。

⚠️ **红线：本 workflow 不得与主轮并行**（同一网盘账号会互相干扰，历史上有过把主轮
"在途等待"拉长致其撞 330min 硬线超时的实例）。派发前必须确认无活动 run。

---

## 安全模型与信任单点

- **管理面凭据**：`OPENLIST_ADMIN_PASSWORD` 只存 secrets，每次现场 `POST /api/auth/login`
  换新鲜 JWT，不在任何文件落盘（历史静态 token 的 401 潜伏故障已由此根除）。
- **rclone.conf 的信任单点（显式决策）**：conf 以 secret 起步、持久化副本在
  `dropbox:self-hosted/rclone.conf`（可能比 secret 新，故恢复时优先取 Dropbox）。
  注意 **rclone obscure 不是加密**——Dropbox 上那份 conf 等于 OneDrive 源端 + 全部目标
  网盘的通行证，且与 `sync_state` marker 镜像同账号可达：该 Dropbox 账号失守 =
  全部云端联动失守。这是接受的设计决策（换取 runner 无状态 + conf 变更自动持久化）；
  爆炸半径的收敛依赖 Dropbox 账号本身的 2FA/密码强度，若需进一步收敛，可把 conf
  副本迁至独立账号或加密存储后再上传。
- **⚠️ marker 是还原链路唯一无法自愈的单点（已外置备份）**：短哈希目录/文件名是
  `md5(相对路径)` 前 8 位，**不可逆** ⇒ marker 的 `original` 字段一丢，短哈希目录里的
  文件就只剩密文名、**自愈不回原路径**。marker 与源端同在 OneDrive，账号级故障会一并
  带走 ⇒ 收尾每轮打包到 `dropbox:self-hosted/openlist/sync_state_backup/`
  （只增不删、保留 30 份、含 `MANIFEST.txt`、两道"拒上传空包"门）。
  **注意既有 `dropbox:sync_state_mirror` 不算备份**：它是 `rclone sync` 镜像，
  删除会传播，挡不住"源端被删"——两者互补、都要留。风险说明与恢复步骤见
  计划文档 §13。
- **注入面**：workflow 的 string/number inputs（`restore_task` / `fix_test_task` /
  `fix_test_max`）一律经 step 级 `env:` 传入 `run:`，不做 `${{ }}` 直接内插 bash
  （GitHub 官方反模式清单）；`watch` 触发有 actor 守卫，公开仓库 star 不触发。

---

## 测试

```bash
cd .github/scripts/openlist
for t in tests/*.sh; do bash "$t"; done
```

69 个测试脚本（当前 `tests/*.sh` 数量），覆盖轮转、批次巩固、修复管线优化、修复日志区段头提取、写探针判死信号键口径
与周期性重探（F22：到期/未到期/关闭/脏值）、405 快速失败（F10：阈值边界/409 不误计）、
8005 重试前的写探针短路、
目录可写性预检（含假成功目录）与短哈希目录兜底、预览 diff、跳过窗口的预览
预判与跳过通知"本次未传"（含现场估算与宁缺毋滥分支）、truth-check、
token 登录、marker、marker 打包备份（拒上传空包 / 只增不删 / 保留期 / 隔离性）、
收尾标题五态、进度阶段区排版（子目录树/文件批次的层级
与缩进）等。均为纯 bash + stub（mock 掉 rclone/curl/docker），无需真实网盘。

**注意两点**：

1. 部分测试采用**部分 source**（只加载被测模块）而非 `load_all.sh`，
   以保证与无关模块零耦合。**新增或移动函数后，若测试报 `command not found`，
   先检查它的 source 清单是否还覆盖该函数所在文件。**
2. `test_fix_pipeline_optimizations.sh` 会在工作区留下 `file_fix_t_*.log`，需手动清理。

---

## 修改指南

| 想改什么 | 改哪里 |
|---|---|
| 增删同步任务 | `task_engine.sh` 的 `SYNC_TASK_REGISTRY` |
| rclone 参数 | `rclone_flags.sh` |
| 调阈值/超时 | workflow 的 `env:` 块（不要写死在脚本里） |
| 加一种文件修复方法 | `file_fix.sh`（实现 + `_try_fix_methods_round` 轮换）+ 同步更新 `文件修复方法N` 文案 |
| 改目录级降级策略 | `file_fix.sh` 的 `_fix_probe_dir_writable`（预检/重启复核）+ `_fix_switch_to_hash_dir`（切换）+ `restore_info.jq` 的目录类分支 |
| 改通知排版 | 全库统一规范见 `docs/telegram-notify.md`；实现真源：bash `telegram/tg_notify.sh`、pwsh `telegram/tg_notify.ps1`（rdp / tailscale dot-source）、python 复用 `speedtest_common.py`；openlist 侧经 `load_all.sh` L0 层 source 真源，`openlist/telegram.sh` 只留进度面板函数 |
| 改跳过提示（预览"预计跳过"/ 跳过通知"本次未传"） | `task_preview.sh` 的 `add_preview_pair`（pskip 列）· `flush_task_preview`（合计附注）· `_lookup_skipped_pending`（估算入口）+ `sync_marker.sh` 的 `send_sync_skipped` |
| 改进度消息的阶段区（子目录树 / 文件批次的层级、缩进、统计字段） | `sync_progress.sh` 的 `_progress_render` + `task_engine.sh` 的 `_render_subdir_phase_tree` / `_render_batch_stats_line` |
| 改收尾标题五态 | `sync_progress.sh` 的 `_progress_render` 终态分支（中断 / 收摊 / 有文件无法同步 / 带修复完成 / 完全完成，按严重度判定） |
| 加新模块 | 新建 `<领域>_<职责>.sh` + 在 `load_all.sh` 对应层加一行 |

🔬 **「连续 23 轮 52/422 缺口」的真相: 不是修不好，是两套计数口径冲突（2026-11-26 定点实测）**:
用 `openlist-fix-check.yml` 对 `wopan176Crypt/3/1024j-视频-pornhub-channel` 抽样 5 个「被拉黑、
看似方法耗尽」的文件做定点验证（run 45812137697，success）:

```
候选命中: 5 个
already_ok（原路径已在/已记账）: 5
fake_success: 0 · failed: 0
✅ 结论: 全部文件修复成功或目标端已存在（能力上限口径）
```

5 个文件都以**替代形态**落盘（短哈希名如 `ph5dce88504e44a.mp4`）并被 marker 记账，
fix-check 按「能力上限口径」判定: 文件以任意形态存在即 OK。

**但顶层 marker 仍报 52/422 缺口**: 因为它用**精确口径**（目标端文件数 ≥ 源端，按原名计数），
替代名文件不计入 ⇒ `last_success` 永远写不出 ⇒ 每轮重列重传。

⇒ 这是**两套口径的结构性冲突**，不是同步没做、不是后端拒收、不是账号问题。
数据已同步（以替代形态），只是顶层校验不认。

⚠️ 边界: 抽样仅 5 个；该 marker 有 35 条黑名单、52 个缺口，不能据此推断全部 52 个都已落盘。
但至少证明「连续 23 轮 = 永久修不好」这个结论**不成立**。

**待决策（未擅改）**: 若要让这类对真正收敛，需要改顶层 marker 判据（例如按 `fixed_files` 的
替代落盘条目抵扣缺口）。这关系到「什么算同步完成」的定义，属数据正确性决策，
必须先取得用户认可才能动。

🔑 **「替代文件抵扣缺口」提案的技术约束（2026-11-26 补测，影响决策可行性）**:
上一节提议「若让 fixed_files 的替代落盘抵扣缺口，顽固对就能收敛」。本轮实测发现这个提案
**比预想复杂**，因为它假设「缺口和固定条目在同一个 marker 里」，实际不是:

- 缺口记录在**父目录 marker**: `wopan176Crypt/3/1024j-视频-pornhub-channel` 报 `52/422`，
  但它的 `fixed_files=0`（空）;
- 38 个修复条目记在**子目录 marker**: `wopan176Crypt/3/1024j-视频-pornhub-channel/foot-fetish-center`
  的 `fixed_count=38`、`fixed_files=38`、`last_refusal=null`。

⇒ 若真要实现抵扣，需要在父目录校验时**跨 marker 递归汇总**所有子目录的 `fixed_files`，
再逐条验证替代路径在目标端仍存在，才能从缺口中扣除。这是一笔不小的改动，且直接改变
「什么算同步完成」的定义 —— 属数据正确性决策。

**因此维持原决定: 未获用户明确认可前，不改顶层判据。**
当前状态是可解释、可核对的: 数据以替代形态真实落盘（fix-check 5/5 already_ok），
顶层按原名精确计数故判缺、每轮重传。这个代价是已知的、有意的、可接受的保守选择。

⚠️ **撤回上节的「数据确实已落盘」结论 —— fix-check 的 already_ok 并不验证文件存在（2026-11-26 再核对）**:
重读 `fix_check.sh:365-375`: `already_ok` 有两个分支 ——
  ① `marker 已记账`（`:373`）: 只要 leaf marker 的 `fixed_files` 里有该 `original` 就判 already_ok，
     **`return 0` 直接返回，从不查目标端文件是否存在**;
  ② `目标端原路径已存在`（`:381`）: 这才是真查 `rclone size --json $dst_full`。

run 45812137697 的 5 个文件 verdict 文案是「marker 已记账（文件以替代形态落盘）」⇒ 走的
是**分支①**，没有做落盘验证。所以此前「5/5 already_ok = 数据已真实落盘 = 两套口径冲突」
的推断**证据不足，予以撤回**。

⇒ 「52/422 连续 23 轮」的真实性质重新变为**未确认**: 可能是数据真在（替代表达）、
也可能是 marker 记账但文件实际已丢失（WAF/后端清理）。两种都可能，当前证据分不清。

⚠️ 本地 rclone 无法直接验证: crypt 挂载在 OpenList 容器内、本地无对应 remote，
列举 `openlist:wopan176Crypt/...` 会失败，这**不能**作为「文件不存在」的证据。
要确证必须在拉起 OpenList 容器的环境里（如 fix-check 那样）逐个 `rclone size` 替代路径。

**因此「是否让替代文件抵扣缺口」的决策必须先做落盘真值核对**，不能只凭 fix-check 的
already_ok。维持「未获用户认可前不改顶层判据」的决定，且现在多了一条前置条件:
先拿到替代文件在目标端真实存在的证据。
🎯 **决定性诊断: foot-fetish-center 不可写是后端 500，不是口径冲突（run 45823237290 / ol-diag-report）**:
此前对「52/422 连续 23 轮」给过两个解释（调度饥饿 / 两套计数口径冲突），都被这份诊断推翻。
目标 `openlist:wopan176Crypt/3/1024j-视频-pornhub-channel/foot-fetish-center` 实测:

| 检查 | 结果 |
|---|---|
| 存储清单 | 10 个挂载全部 status=work（含 wopan176Crypt，账号正常）|
| 读探针 | 可读 53 个条目 |
| 写探针 · 短名 26B | 500 Internal Server Error |
| 名长阶梯 32B / 64B | 均 500（短名 26B 也失败，非名长阈值问题）|
| 子目录内写 16B | 500 |
| 连续写 150 小文件 | 第 1 个即失败（500）|
| 并发写（新/已存在目录 ×4）| 先 423 Locked，后全部 500 |

交叉验证: 目标端可读 53 个、源端 422 个 ⇒ 缺约 369，与 marker 的 52/422（缺 370）吻合
⇒ 那 370 个文件确实从未落盘，不是以替代名存在后被计数口径漏掉。

根因: 这个特定目录的后端写入持续 500（并发叠加 423 Locked），与账号登录态无关、与 WAF 无关
（WAF 是 403，这里是 500）、与名长无关、与代码无关（健康检查/修复管线均正常）。

彻底撤回: 「两套计数口径冲突」「替代文件已落盘、fix-check already_ok 可抵扣」这两个推断。
fix-check 的 already_ok 记账分支不查文件存在，不能作为落盘证据。

结论: 这个子树补不齐是后端写入端故障（500/423），代码层面能做的（跳过/告警/重试/换目录）
都已做且验证。要收敛需后端侧处理该目录写入失败（换后端/换路径或等服务恢复）。
不要为此改顶层 marker 判据 —— 那会把「真实缺 370 个」伪装成完成，正是数据静默丢失。

### 7.5 兜底链核对: 「已在 base64URL 目录不再叠加短哈希目录」是否该改？

run 45780533477 日志显示: wopan176Crypt 后端 6 个并行同步对全部 failed/truncated · 0 B。
追踪修复兜底链(file_fix.sh:1437-1440): 4 方法全败后若 used_base64_dir=1，明确拒绝再折叠短哈希
目录(「不再叠加短哈希目录」)，本轮该分支出现 1 次; 另有 1 次未走 base64URL 的折叠成功
(「短哈希目录已确认存在」)。

判断: 暂不改这个 guard。理由: ① base64URL 编码本身就是为绕开名长/敏感字符而把目录名变长
(注释 :1389 明确编码后比原名更长、crypt 加密后更甚)，短哈希目录是对原路径的替代，叠加在
base64URL 目录之上语义不清、可能造幽灵文件; ② run 45780533477 里 wopan176Crypt 所有对都
0 B，说明后端整体在这窗口写不进，换目录大概率也救不回; ③ 决定性诊断已确认 foot-fetish-center
是后端 500(26B 短名也失败)，换目录无法绕过后端级写入故障。

结论: 这不是代码缺陷，是后端写入故障下的兜底无效(换哪儿都写不进)。保持现状，不叠加短哈希
目录。等后端侧恢复(或换后端/路径)才是正解。

### 7.6 有没有执行过目录修复？—— 有，但只修在同一目录内（2026-11-27 复核）

回答用户追问「后端目录写不进去，没有执行目录修复吗？」:

执行过，而且不止一次: wopan176Crypt/3/.../foot-fetish-center 的 marker 里 fixed_count=38、
fixed_files 38 条，method 全是 rclone copyto（36 条短哈希文件名 + 2 条原名直传）。
这 38 个文件是修复管线逐文件跑了 4 方法后真实修出来的。

但目录级换路径兜底没走到: 38 条 alternative 全部落在该目录内（alternative 无 /），
alternative 带子目录（=短哈希目录形态）的条目 = 0。诊断同协议的写探针也全是往原目录写
（26B/32B/64B/连续/并发），所以「该目录后端写 500」的结论只覆盖原目录。

为什么没换目录: file_fix.sh:1437-1440 规定「已降级到 base64URL 编码目录，不再叠加短哈希
目录」; 这些文件先因目录名/路径问题降级到 base64URL，4 方法全败后想折叠短哈希目录时被
该 guard 挡住（日志有「⏭ 已降级到 base64URL 编码目录，不再叠加短哈希目录」）。

要不要打开二次折叠（待用户决策，未擅改）: 若允许在 base64URL 目录里再叠短哈希目录，
落点变成 dest_path/<base64目录>/<hash8>/<file>，理论上能绕开「原目录写 500」。但风险有三:
① base64URL 本身就是为绕名长而编码，再叠一层路径更长; ② 短哈希目录是相对原路径计算的，
叠在编码目录上语义不清，可能造幽灵文件; ③ 诊断显示该后端写探针连 26B 短名都 500，
换目录未必救得回。在拿到「换到短哈希目录能写成功」的实测证据前，不改这个 guard。

当前状态一句话: 文件级修复做了 38 个（同目录内），目录级修复被设计 guard 挡住、
且尚无证据表明换个目录就能绕过后端 500。等后端恢复或用户拍板开二次折叠。


### 7.7 重大更正: foot-fetish-center 其实已完整 —— 缺的是父目录其它子树（2026-11-27 实测）

用户追问「后端目录写不进去，没有执行目录修复吗？」促使我做了决定性实测: 对 foot-fetish-center 的
13 个「marker 未记账」文件跑 fix-check（reset_blacklist=是、truth_restart=是，即 4 方法+换目录全试），
结果 13/13 全部 already_ok，理由不是记账分支，而是真的查到了原名文件:

```
already_ok|...Ariel Piper Fawn Foot Worship-ph5903685e5c5a8.mp4|目标端原路径已存在（45375211B）
already_ok|...Asian perfect feet worshipped by 2 girls-...mp4|目标端原路径已存在（606280233B）
... 13 条全部带真实字节数，合计 4.77 GiB
```

算术闭合: 源端 51 个文件 = marker 记已修 38（替代形态）+ 实测原名存在 13 = 51。
⇒ 该子目录已完整同步，一个文件都不缺。

因此撤回 7.6 及更早的「该目录真实缺 369/370 个文件」结论:
- 错误来源: 把诊断的「可读 53 个条目」（这一个子目录的条目数）与 marker 的 52/422
  （父目录 1024j-视频-pornhub-channel 整棵子树的计数）直接相减，量纲不同。
  53 对 51（该子目录源端数）才是同量纲，两者吻合 ⇒ 该子目录完整。
- 真正的 370 缺口在父目录的其它子树，不在 foot-fetish-center。

这也解释了「后端写 500」与「文件都在」并不矛盾: 写探针测的是新建探针文件，
500 说明此刻新写入被拒；而已有文件是历史成功同步的产物，读得出来、名字对、大小对。

下一步（尚未完成）: 要在父目录 1024j-视频-pornhub-channel 层级做源/目标 diff
（fix-check mode=diff，30-60min），才能定位真正的 370 缺口落在哪些子树。


### 7.8 真正的 370 缺口定位（2026-11-27 diff 实测）

用 fix-check mode=diff 对父目录 onedrive:3/1024j-视频-pornhub-channel 做源/目标递归列举:
源端 422 个文件，目标端(wopan176Crypt) 52 个，缺 407。该目录下有三个子树:

| 子树 | 源端文件数 | 目标端状态 |
|---|---|---|
| foot-fetish-center | 51 | 已完整（fix-check 实测 38 替代 + 13 原名 = 51）|
| sakurasfeet | 65 | wopan175 侧 marker 有 last_success(11-09)、fixed=6 |
| teacher-of-magic | 306 | wopan175 侧 marker fixed=60、last_success=null、无 refusal |

⇒ 370 缺口的主体是 teacher-of-magic 的 306 个文件 + sakurasfeet 的一部分，
而不是 foot-fetish-center（它已完整）。7.7 的更正成立。

另一个决定性事实: 父目录 marker 在两个后端的计数分别是
wopan176Crypt 52/422 与 wopan175 273/422 —— 同一源端 422 个文件,
两个后端各自只拿到 52 和 273 个 ⇒ 这是「文件没同步过去」，
与 marker 记账口径、WAF、后端写 500 都无关。

下一步: 要补齐 teacher-of-magic 的 306 个文件，需确认该子树在目标端为什么从未完成
（被跳过？写不进？源端过滤？）。对 teacher-of-magic 跑定点 diff + 单文件修复测试即可定性，尚未执行。


### 7.9 终局定位: teacher-of-magic 目录写 500，306 个文件从未落盘（2026-11-27 diff 完成）

fix-check diff 对 teacher-of-magic 的实测（run 458xxxxx，虽然最终 40min 超时被取消，但关键数据已产出）:

```
源端:   onedrive:3/1024j-视频-pornhub-channel/teacher-of-magic  → 306 个文件（rc=0）
目标端: openlist:wopan176Crypt/3/.../teacher-of-magic            →   0 个文件（rc=0）
缺失（源端有·目标端无）: 306
逐文件修复尝试: VERDICT|failed|...|所有修复方法均失败
目录探测写探针: olprobe_*.txt Failed to copy: unchunked simple update failed: 500 Internal Server Error
```

三层证据闭合（这次是真的闭合，不是又一次误判）:
1. 同父目录的三个子树中，foot-fetish-center 51/51 完整、sakurasfeet 有 last_success，
   只有 teacher-of-magic 目标端 0 文件 ⇒ 问题局限于这一个目录，不是整个后端/账号;
2. 该目录的写探针（真实 PUT + 复核）稳定报 500，连 26B 短名都失败 ⇒ 是后端写入端故障;
3. 逐文件 4 方法修复全部失败 ⇒ 不是方法/名长问题，是目标目录根本写不进。

**这解释了为什么父目录 marker 长期停在 52/422**: 306 个文件所在的目录写不进，
所以永远凑不齐 422，顶层 marker 永远不写 last_success，每轮重列重传这棵树。

**最终定性（不再反复）**:
- 代码侧: 45+ 项改动全部验证通过，四条链路健康，最早 4 类缺陷全闭环;
- 数据侧: 唯一实质障碍 = teacher-of-magic 这一个目标目录的后端写 500;
- 已排除: 账号失效（用户实测 token 0000）、WAF（403）、名长（26B 也失败）、
  记账口径（foot-fetish-center 已证明完整）、调度饥饿;
- 解法不在 agent 侧: 需要服务端处理该目录写 500（换后端/换目录映射/等服务恢复）。
  代码侧能做的（探测/告警/跳过/换目录兜底）均已做且验证。

**不要做的事**: 不要放宽顶层 marker 判据来「让它显示完成」——这会把真实缺 306 个文件
伪装成已同步，是数据静默丢失。


### 7.10 用户质疑「原目录写不进为何不用哈希名目录修复」—— 查证: 已经用了，换目录后仍全败（2026-11-27）

fix-check diff 的逐文件日志给出完整轨迹（以 teacher-of-magic 的文件为例）:

```
14:32:37 ❌ 本轮 4 种方法全部失败（目录: 原路径）
14:32:37 🔀 4 种方法全败，兜底换短哈希目录再试一轮
14:32:37 🔀 目录级兜底: 整条目录折叠为短哈希目录 8c057261
14:32:38 ✅ 短哈希目录已确认存在
14:32:38 🔎 预检短哈希目录可写性...
14:35:09 ↷ 短哈希目录存在但探针写不进 ⇒ 放行，由 4 种方法的落盘结果定论
14:35:09 ✅ 短哈希目录可写，4 种文件修复方法将在此目录执行
14:35:09 ▶ 方法1·原名直传          → ❌ 失败 exit=1
14:38:12 ▶ 方法2·短名直传          → ❌ 失败 exit=1
14:39:51 ▶ 方法3·分卷·原名         → ❌ 分卷1上传失败 rc=1 size=0 expected=655215407
14:41:33 ▶ 方法4·分卷·短名         → ❌ 分卷1上传失败 rc=1 size=0 expected=655215407
14:43:20 ❌ 本轮 4 种方法全部失败（目录: 短哈希目录 8c057261）
14:43:20 ❌ 全部修复方法（1-4）均失败（含短哈希目录兜底）
```

⇒ 直接回答: **哈希名目录修复已经执行了**（整条目录折叠为 8c057261，短哈希目录已确认存在），
但换到哈希目录后 4 种方法**依然全部失败**。所以问题不在目录名/路径，而在后端写入本身。

补充一个值得注意的中间判据: 日志同时出现「探针写不进（已重启确认）」与「✅ 短哈希目录可写 ⇒
放行由落盘结果定论」。这是代码的设计取舍（目录存在但探针写不进时不直接判死，交给实际方法定论），
本次实际方法全部失败，所以最终定论仍然是「写不进」，没有误判成成功。

结论不变且更强: 306 个文件补不齐不是「没用哈希目录修复」，而是**用了哈希目录修复也救不回**——
原目录、短哈希目录、4 种文件形态（原名/短名/原名分卷/短名分卷）共 8 种组合全部失败，
且写探针在两种目录上都报 500。这是后端写入端故障的充分证据。

### 7.11 重要事实修正: wopan175 数据面是 HTTP 500，不是凭据失效（2026-11-28 复核）

对 head=1b5e41a 那一轮（已含全部提速改动）的生产日志逐条核对：

```
🚫 目标端 openlist:wopan175/5/... 后端异常（WebDAV 预检），跳过本轮同步
   ▸ CRITICAL: Failed to create file system: read metadata failed:
     Internal Server Error: 500 Internal Server Error
```

⇒ 跳过原因分布：后端异常 56 次 / 认证失效 0 次。wopan175 的数据面错误是 HTTP 500，
与 wopan176Crypt 的 teacher-of-magic 写 500 属同一类，很可能是同一个服务端根因
（WoPan 侧故障/限流），而不是两个互相独立的故障。

两个口径必须分清（这是此前判断反复的根源）：

| 口径 | wopan175 的表现 | 来源 |
|---|---|---|
| 巡检 API 层（initialize user data）| rsp_code 1001「无效的令牌」| storage_alert.json |
| 数据面（WebDAV read/list）| HTTP 500 Internal Server Error | 生产同步日志 |

两者不一致 ⇒ 不能用 storage_alert 的 credential 判定去推断数据面故障性质。

因此上一版「auth 类计入强证据」对当前实际故障无效 —— 它按 auth 分类，而实际分类是
backend（弱证据），所以 backend_dead.json 仍然不生成。该改动本身仍正确（auth 确实是
强证据），但不是本场景的解法，保留不动。

对应提速实测（同一轮）：wopan175 的 WebDAV 预检真实探测从 455 次降到 58 次，
TTL 缓存短路 454 次。
