# 通知构件速查

本文件是**助手签名与三套实现对照**的唯一真源（规范正文只写规则与示例，不再重复函数表）。
版式规则、折叠判据、时长 / 大小 / 日期口径、状态图标一律以
[`docs/telegram-notify.md`](../../../docs/telegram-notify.md) 为唯一真源，本文不重复。

定位函数用 grep，不记行号（行号必漂）：

```bash
grep -nE '^(函数名)\(\)|^def 函数名|^function 函数名|\$?TG_SEP *=' 真源文件
```

## 1. 三套实现边界

| | bash `tg_notify.sh` | pwsh `tg_notify.ps1` | python `speedtest_common.py` |
|---|---|---|---|
| 适用 | Linux / macOS runner | Windows runner | python 脚本 |
| 排版助手 | 全套 `tg_add_*` / `tg_entry*` / `tree_*` | 无，全部手拼 | 返回字符串的镜像函数，自己 `join` |
| 大小 / 耗时 | `format_bytes` / `tg_format_seconds` / `tg_format_duration` | `Format-TgDuration` | `tg_format_elapsed`；**无大小助手** |
| 发送 | `send_tg` / `send_tg_chunked`（可选 `tier`） | `Send-TgMessage <text> [tier]`，无分片 | `send_telegram` / `send_telegram_chunked`（可选 `tier`） |
| 分隔线 | `TG_SEP` | `$TG_SEP` | `TG_SEP` |
| 转义 | `escape_html` | `Esc-Html` | `html.escape` |

pwsh 只有 **5 个成员**：`$TG_SEP` / `Esc-Html` / `Format-TgDuration` / `Get-TgFooter` /
`Send-TgMessage`。全库 dot-source 它的只有 `rdp.yml` 与 `tailscale-windows.yml`。

## 2. bash 签名（公开助手全表）

```bash
# 标题 / 正文
tg_add_title      <变量名> <标题>              # 标题 + 分隔线，自带换行
tg_add_kv         <变量名> <标签> <值>         # 值转义，输出 "标签：值"
tg_add_path       <变量名> <标签> <值>         # 值转义 + <code>
tg_add_link       <变量名> <标签> <URL> <文本>  # <a href>，文本与 URL 都转义
tg_add_section    <变量名> <分节标题>          # 段前空行（紧跟分隔线 / 空消息除外）
tg_add_note       <变量名> <说明段>            # 段前空行；段内不能带 HTML
tg_add_block      <变量名> <已含标签的片段>     # 原样追加并保证尾换行
tg_add_pre        <变量名> <裸文本>            # 转义 + <pre> 包裹
tg_append         <变量名> <原始文本>          # 第一参是变量名不是值；不转义

# 条目 / 树形（条目一律不含尾换行）
tg_entry          <主体> [元数据...]           # 机器值主体，自动 <code>
tg_entry_text     <主体> [元数据...]           # 自然语言主体，不套 <code>
tg_entry_pair     <A> [B] [元数据...]          # 双机器值，A → B
tg_entry_codes    <A> [B] [元数据...]          # 双机器值，A · B
tg_add_entry        <变量名> <主体> [元数据...]
tg_add_entry_text   <变量名> <主体> [元数据...]
tg_add_entry_pair   <变量名> <A> [B] [元数据...]
tg_add_entry_codes  <变量名> <A> [B] [元数据...]
tree_conn         <0|1 是否末条>               # "  ├─ " / "  └─ "（已包 <code>）
tree_sub          <0|1 是否末条>               # 二层子行前缀（与 tree_conn 等宽）
tree_lines        <多行条目流>                 # 统一补树形前缀，末条 └─
tree_fold         <多行条目流> [上限=8]         # 只截断 + 折叠行
tree_code_fold    <多行裸文本> [上限=8]         # 转义 + <code> + 截断

# 格式化 / 收尾
format_bytes        <字节数>                   # 1.150 GiB（1024 进制 + 三位小数）
tg_format_seconds        <秒>                       # "27 毫秒" / "1.40 秒"
tg_format_duration  <秒>                       # "X 小时 Y 分" / "X 分钟" / "X.XX 秒"
tg_tail_safe        <文本> [字节=1200]         # UTF-8 安全的尾部截断
tg_tail_file_safe   <文件> [字节=1200]
tg_add_footer       <变量名> ["标签" "URL"]...  # 收尾区；附加链接对

# 转义 / 发送
escape_html     <文本>
send_tg         <文本> [tier]                  # >3900 UTF-16 码元自动分片
send_tg_chunked <文本> [tier]
```

- `tg_route` 是发送层内部路由（解析 tier → `_TG_TOKEN` / `_TG_CHAT`），调用方不用；
  新增内部函数一律用 `_` 前缀，机械校验只要求「非 `_` 前缀的公开助手」全部进本表。
- `tg_add_*` 的第一参都是**变量名**（内部 `printf -v` + `${!1}`），写 `tg_add_title "$msg"` 是错的。
- `tg_add_entry` / `tg_add_entry_text` 的主体收**裸文本**，内部才转义（前者还包 `<code>`）；
  预先包好会二次转义。
- `tg_add_footer` 必须对**已积累正文**的变量原地追加；附加链接只在 `TG_RUN_URL` 非空时追加。
- `send_tg` 空文本直接 `return 0`；`_tg_send_once` 返回 `2` 表示 HTML 解析失败（400，不重发）。

## 3. 两个折叠助手

| 助手 | 输入 | 做什么 |
|---|---|---|
| `tree_code_fold` | 裸文本（未转义、无标签） | 逐行转义 + `<code>` + 超上限折叠 |
| `tree_fold` | 已由 `tg_add_entry` / `tg_entry` 构建的条目流 | **只**截断 + 加折叠行 |

二者不可互换，误用会二次转义。折叠行并入条目流作末条（由 `tree_lines` 统一决定 `└─`），
不要单独补一行造成双 `└─`。折叠与否看清单性质（流水折叠、结构性全量），判据见规范 · 折叠行。

## 4. 高频坑（全库唯一坑清单真源）

按真实事故排序。send SKILL 的「写后自检」与 audit skill 的复核都以本节为准，
不在别处再维护第二份。

1. **二次转义**：`tree_code_fold` 收**裸文本**（一站式转义 + `<code>` + 折叠）；`tree_fold`
   收**已构建条目流**（只截断）。对已含 `<code>` 的条目流用 `tree_code_fold` →
   `&` 变 `&amp;amp;`、整条 400 丢失。同理，`tg_add_entry` 的主体收**裸文本**，预先包
   `<code>` 也会被二次转义。
2. **尾换行被吃掉**：`$(tg_entry …)` 不输出换行，命令替换还会吃掉它 → 累积多行一律用
   `tg_add_entry`。
3. **footer 两步写法**：`tg_add_footer` 必须原地追加到**已积累正文**的变量；先接在空变量上
   再拼正文 → 空行丢失（真源 `tg_add_footer` 上方注释）。
4. **通知写在业务块末尾且无 `always()`**：任务失败时反而收不到通知——全库最常被忽略的
   接线坑。
5. **通知写在会 `exit 1` 的步骤末尾**：步骤级 `always()` 挡不住步骤**内部**早退——业务步骤
   在通知之前 `exit 1`，通知整条不发。汇总类通知独立成 step，业务步骤只负责把结果落文件
   （`openclaw.yml` 的归档结果即此形态）。
6. **pwsh 不自检**：dot-source 后必须 `Get-Command Send-TgMessage`；调用未定义函数是终止
   错误，step 带 `continue-on-error` 时表现为**通知静默消失**。
7. **python 兜底吞异常**：`except: pass` 会同时吞掉异常和返回值，400/429 无痕迹。用
   `notify_best_effort(stage, msg)`。
8. **`<pre>` 超长**：原始输出取尾部 1200 字节，用 `tg_tail_safe` / `tg_tail_file_safe`，
   不要裸 `tail -c`（会切断 UTF-8）。
9. **内嵌 python 段**：无法 import 共享层，用到的助手必须在本文件同义实现，漏实现会
   `NameError` → 连整轮汇总通知一起丢。
10. **函数体内 source 真源**：子 shell 只改自己的函数表，调用点对 `send_tg` 的覆写会被还原。
11. **`while read` 读结果文件丢最后一条**：末行缺尾换行时 `read` 返回非 0（变量已赋值），
    写成 `while IFS=$'\t' read -r a b c d || [ -n "${a:-}" ]`。
12. **大小口径**：用真源 `format_bytes`（`1.150 GiB`，1024 进制 + 三位小数），不是 `du -h`
    的 `1G`，也不要裸字节；python 侧同义实现改口径时要同步。

回归基线（openlist 域）见
[`telegram-notify-audit/references/audit-checklist.md`](../../telegram-notify-audit/references/audit-checklist.md)。
