# Telegram 通知版式核对清单

本文件是 `skills/telegram-notify-audit` 第 1、3、5 步的输入：机械扫描项、判据摘要、
易误判项、回归基线与 flake 名单。**只记录可复用的判据与基线**，不记录核对轮次。

## 1. 机械扫描项（Grep 工具，path 显式传 `.github`）

| # | 扫描项 | 模式 | 期望结果 |
|---|---|---|---|
| 1 | 粗体 / 斜体 | `<b>\|</b>\|<i>\|</i>` | 零使用，仅注释提及 |
| 2 | 平铺条目 | `•` | 零使用，仅注释提及 |
| 3 | 半角冒号 kv | `[一-龥]:[^/:= ]` | 仅非通知代码（echo / grep 表达式） |
| 4 | 紧凑时长 / 高精度浮点 / ISO 直出 | `[0-9]+h ?[0-9]+m\|[0-9]\.[0-9]{4,} 秒\|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}` | 仅注释、测试夹具、非通知数据 |
| 5 | curl 直发 | `curl .*(sendMessage\|/bot)`（行尾 `\` 续行先拼成逻辑行再匹配） | 只允许：发送层自身、进度面板（`openlist/telegram.sh` 的 `message_id` / `deleteMessage`）、`sendDocument`（`sync_notify.sh`）。`ensure-miniapp-menu.sh` 配置菜单不属通知。**新增直发点即偏差**，不按固定处数判 |
| 6 | 分隔线 | `TG_SEP *=\|━━━` | 四处同值 18 条（bash 真源 / pwsh `0x2501*18` / python `'━'*18` / `sync_to_tg.sh` 内嵌） |
| 7 | 收尾区覆盖 | 按文件统计 `tg_add_title` 与 `tg_add_footer\|Get-TgFooter\|tg_footer_line` | 计数不等时查是否分支汇聚或注释；每处标题分支都必须能走到 footer |
| 8 | 运行日志接线 | `grep -l TG_RUN_URL .github/workflows/*.yml` | **现场重数，不记固定数字**。判据是「每个发通知的 step 都有 `TG_RUN_URL`」；直接构造通知的 workflow 数与注入面不必相等。caption 场景也需注入 |
| 9 | 树形 / 折叠调用点 | `tree_lines\|tree_fold\|tree_code_fold` | 逐个确认折叠口径（第 2 节） |
| 10 | 分节计数 | `tg_add_section +[a-z_]+ +"[^"]*"` | 后跟列表的带 ` · N`；后跟 `<pre>` 或 kv 行的可不带 |
| 11 | 速查表函数存在性 | 对 `skills/telegram-notify-send/references/api-reference.md` 的三套实现对照表，逐列取函数名 `grep -nE '^(函数名)\(\)\|^def 函数名\|^function 函数名'` 对真源 | **双向**（脚本已实现）：①表里的名字必须在真源存在；②bash / pwsh 真源的非 `_` 前缀公开助手必须登记进表。python 只做①（文件内大量测速业务函数不是通知助手）。只记函数名不记行号 |
| 12 | **函数体内 `source` 真源** | `source .*tg_notify\.sh`，人工判断是否落在 `name() { … }` 之间 | 只允许在 step / heredoc 顶层。子 shell 内 source 只改子 shell 函数表，会还原调用点对 `send_tg` 的覆写、`local` 也失效（规范 · 通知函数的正确接法） |
| 13 | 接力轮重复通知 | 长跑 workflow 里按「服务已就绪」发通知的调用点 | 默认每轮都发（服务确实重启过）；按接力轮静默的必须有 `/tmp` 标记文件，且域文档与调用点同时写明（当前只有 zcode2api，降级轮仍每轮必报） |
| 14 | `🕒` 误用 | `🕒` | 只允许无 run 上下文的常驻服务收尾区（`health/system_health.sh`、`services.sh` 生成的 dropbox 守卫、`board.py`、`gateway-watchdog.py`）；正文分节 / 时间行不得使用 |
| 15 | 展示时间时区 | 通知字符串里的 `UTC`；无 `TZ=` 的 `date +%F` | 展示时间一律东八区（`YYYY-MM-DD HH:MM（东八区）`）；仅机器值可 UTC。取展示值必须 `TZ=Asia/Shanghai` |
| 16 | 分节计数形式 | `tg_add_section` 标题：分节后跟 `tree_` / `tg_add_entry` 时，` · ` 后必须是计数或变量 | 不出现「· 模型数量 N」这类文字 |
| 17 | 通知正文时间 | `tg_add_` / `tg_append` / `caption` 行里的 `YYYY-MM-DDTHH:MM` 或 `UTC` | 零使用；解析失败写「未知」，原始值只留日志 |
| 18 | caption 大小口径 | `PART_CAPTION=` / `CAPTION=` 行里的 `MiB`/`MB` 字面量 | 大小必须走 `format_bytes` |
| 19 | 文档示例大小 | `docs/telegram-notify.md` 与 send skill 参考里的 `1.7 GB` 式写法 | 只用 IEC 三位小数（`1.700 GiB`） |
| 20 | 通知清单枚举 / 一键校验 | `bash scripts/list_notify.sh`（清单）/ `--check`（全部机械项，FAIL 退出 1；项目数会变，别记数字） | 发送点 / 标题 / 档位三段可正常输出；档位为「动态」的必须逐个回文件确认取值。**清单不落文档** |
| 21 | 业务步内嵌通知 | 找「通知写在业务 step 末尾、该 step 无 `always()`」的调用点 | 按规范 · 接线的判据分类：依赖落盘产物的拆独立 step；依赖运行时变量的加失败兜底；「已就绪」与长驻循环**不拆**。别把「不拆」报成缺陷 |

## 2. 四域判据（派 worker 时写进 prompt 的摘要）

- 标题 = `{emoji} 标题` + 18 条全角横线 `━`，不空行
- 分节 `{emoji} 分节 · N`：后跟条目列表必须带计数
- kv 一律**全角冒号**；机器返回值（路径 / 文件名 / IP / ISP / ASN / 位置 / 域名 / 端口 /
  密码 / ID / 命令 / 版本 / 原始异常串）用 `<code>`，自然语言（原因 / 结论 / 状态 / 备注）裸文本
- **同一分节内口径一致**：一次查询返回的 IP / ISP / ASN / 位置整节同为等宽
- 外部可点 URL（运行日志 / 订阅源 / 直链 / run 链接 / 看板）用 `<a>`；本机回环接口
  `http://127.0.0.1:PORT/…` 读者点不开，走 `<code>`
- 条目一律 `├─/└─` 树形（前缀包 `<code>`），元数据 ` · ` 跟在主体后
- 折叠看**清单性质**：流水 / 日志类超 8 条折叠；结构性清单全量展示
- `tree_code_fold` 收裸文本、`tree_fold` 收已构建条目流，误用会二次转义
- 收尾区 `⏱ 已运行 X · 🔗 运行日志` 必须走 `tg_add_footer` / `Get-TgFooter` / `tg_footer_line`
- 时长五层；大小 1024 进制三位小数 IEC；展示时间东八区
- 动态内容必须转义，无豁免
- 读者要「看懂」的字段说人话；运行日志不搬进通知，尤其不搬成条目子行
- 空行只来自：section 前、note 前、footer 前、正文与动作行之间、多组列表组间（带「已有组」条件）

## 3. 易误判为偏差、实为合规

判据摘要表；同一域的多条合并归组，具体字段口径见对应域文档与代码注释。

### 3.1 折叠与清单

| 写法 | 为什么合规 |
|---|---|
| 结构性清单不折叠：进度面板五组任务、`task_preview` 同步对、归档明细、免费模型名单 | 折掉后半段会让读者误判（规范 · 折叠行）；规模靠分节计数交代 |
| 流水类清单走 `tree_fold`（如 `sync_to_tg.sh` 失败清单） | 单条价值低，与同通知「已上传」同口径 |
| 去重通知的组级折叠行单独成行、无树形前缀 | 组级折叠不是单条目流；空行隔开的说明行比再造一个顶层 `└─` 更清楚 |

### 3.2 计数、分节与文案

| 写法 | 为什么合规 |
|---|---|
| 后跟 `<pre>` 或 kv 行的分节不带计数；`📍 测速点网络` 单目标也带 ` · 1` | 规范允许前者；后者由共享层 `count_hint` 无条件拼 |
| 标题数与 footer 数不等 | 多为分支汇聚（如备份四态 4:2）或注释造成的计数差，逐分支查汇聚点 |
| 同一结论按真因分多种文案（如 taier「未更新订阅」分三种） | 达标不足 / 缺可导出配置 / 到点收摊是三回事，合并会把不同下一步写成同一句 |
| 一行多字段里的混合值不逐个套 `<code>`（如 emby 规格行 codec、`（缓存命中）` 括号说明） | 单独套会成斑马纹；括号说明属自然语言裸文本 |
| 测速节点指标串里的 `35ms` | 指标字段（与 `↑` / `↓` 并排），不走「毫秒」层 |
| 媒体 caption 无标题 / 分隔线 / 收尾区 | 收尾区固有例外，但必须转义 + 显式 parse_mode |
| 规范样例区的树形前缀是裸 `├─ `，实现渲染 `<code>  ├─ </code>` | 样例是抽象版式；核对以真源渲染为准，别照样例写断言 |

### 3.3 网关域（数据源与渲染口径）

| 写法 | 为什么合规 |
|---|---|
| `wb_notify` / `wb_stop_notify` 各存一份版式；`trae_notify` 同理 | 分处不同 step、shell 不共享；**改版式必须同组一起改** |
| 账号池子行用 `tree_sub` 手拼，不走 `tree_lines` | `tree_lines` 会把子行渲染成与条目平级的 `├─/└─` |
| 账号池 TSV 每列都不许为空（空值 `-`）；块后补空行 | `read` 折叠连续制表符，中段空列整体左移；`tg_add_block` 不补尾空行，否则下一个 kv 紧贴末条子行 |
| 数据缺失不编造：`quotaKnown=false` 写「额度未获取」、免费名单取不到整段降级、冷却拿不到时刻只给数量 | 0 / 编造的名字会与「额度耗尽」等真实状态混淆 |
| 收尾停止通知只有结论行、没有账号池 | 收尾 step 没有运行期变量，且网关已停，列账号池会让人以为服务还在跑 |
| trae2api 无「凭据」分节、「🧾 原始输出」非空才渲染 | 与 workbuddy 同源但数据来源不同；原始输出按 1200 字节截断 |

### 3.4 冒烟必须能抓的契约（不是规范）

- systemd 生成的 `dropbox-orphan-guard.sh` 从脚本同目录 source 安装时拷来的 `tg_notify.sh`，
  版式/发送都复用真源，不是第二套发送层；`services.sh` 里出现 `tg_add_title` 是生成守卫的模板，不是第二处通知实现。
- 资产段「📅 资产」节标题必须排在数据行之前（标题挂空即偏差）。
- `_DAYS_CACHE` 必须已定义；`board.log` 出现 `NameError` 即偏差。
- 空输出（任一源当日无数据、qingyan 回退快照）= 合法，非偏差。

## 4. 回归基线（改动触及 openlist 域时必跑）

```bash
cd .github/scripts/openlist/tests
bash -c 'rm -f /tmp/x_*.log 2>/dev/null; for t in test_*.sh; do bash "$t" </dev/null > "/tmp/x_${t%.sh}.log" 2>&1; echo "$t EXIT=$?"; done'
grep -l "command not found" /tmp/x_*.log   # 必须为空（硬要求）
```

- 全量约 5–12 分钟（随套件数与机器负载变化），后台跑；**跑期间不要并发跑单个测试**。
- 判定基线：**除环境假红外全部 `EXIT=0`**（套件数会变，别记数字）；已知环境假红：
  - `test_truth.sh`（依赖 docker / 真实 OpenList 服务）
  - `test_marker_skip_guards.sh` 1b（macOS BSD `date` 无 `-d`）
- `command not found` 扫描**必须为空**——套件 PASS 不等于通过。
- 新写测试不要再共用同一份 extracted.sh 式共享桩（串行跑会互相覆写，产生假 cnf）；每个测试自建最小桩。
- 修完 cnf 后必须 `grep -l "command not found" /tmp/x_*.log` 复验为空。

### flake 名单（单独复跑确认后再下结论）

- `test_progress_no_orphans.sh` T5「强杀路径有超时上限 <15s」：负载高即失败，
  单独复跑 `PASS=16 FAIL=0`
- `test_get_openlist_token_login.sh`：sandbox broker IPC `ETIMEDOUT`
- `test_batch_precheck_circuit_breaker.sh`：回归期间被并发跑过会出现假 `command not found`
- `test_pair_parallel.sh`：`wc` 前导空白使 `[: 0\n0: integer expression expected`，
  场景 3a 误报，单独复跑 `PASS=11 FAIL=0`
- `test_pair_share_slice.sh`：C4 份额秒数取整偶发差 1（期望 ≈16299、实得 16300），
  单独复跑 `PASS=56 FAIL=0`
