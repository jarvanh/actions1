---
name: telegram-notify-send
description: 在本仓库新增或修改一条 Telegram 通知时使用——给 workflow/脚本加通知、写新的汇总通知、改通知内容或版式。覆盖接线（env 注入 + always）、选哪套实现（bash/pwsh/python）、按规范搭消息（标题/kv/分节/条目/pre/收尾区）、发送与写后自检。只核对已有通知版式是否统一、做全库审计时，改用 telegram-notify-audit。
agent_created: true
---

# 发送 Telegram 通知

本仓库所有 Telegram 通知共用一套版式。写新通知时**不要自创格式**——照真源的构件拼。

## 真源（动笔前必看）

| 用途 | 路径 |
|---|---|
| 版式规范 | `docs/telegram-notify.md`（版式构件、发送层硬约束） |
| 通知清单 | `bash skills/telegram-notify-audit/scripts/list_notify.sh`（现场枚举发送点/标题/档位）；域级出口与档位规则在 `docs/telegram-notify-registry.md` |
| bash 实现（最全） | `.github/scripts/telegram/tg_notify.sh` |
| pwsh 实现（**只有 5 个成员**） | `.github/scripts/telegram/tg_notify.ps1` |
| python 实现（镜像函数） | `.github/scripts/proxy-speedtest/speedtest_common.py` |

写之前先读 `docs/telegram-notify.md` 的「版式构件」与「发送层」两章。只有四处是**硬约束**（收尾区、接线、发送层、验证与交付），其余是「建议 + 为什么 + 反例」——不要把风格建议说成军规，但硬约束没有例外条款。

## 第 1 步：选实现

| 场景 | 用哪套 | 有什么 / 没什么 |
|---|---|---|
| Linux / macOS runner 的 bash step | `source .../telegram/tg_notify.sh` | 助手最全：`tg_add_*` / `tg_entry*` / `tree_*` 全都有 |
| Windows runner（pwsh） | `. ...\telegram\tg_notify.ps1` | **只有** `Esc-Html` / `Format-TgDuration` / `Get-TgFooter` / `Send-TgMessage` / `$TG_SEP`。**没有** kv 助手、条目助手、树形助手、分片发送——全部手拼 |
| python 脚本 | `from speedtest_common import ...` | 有 `tg_entry` / `tg_entry_pair` / `tg_entry_codes` / `tg_pre_block` / `tg_footer_line` / `tg_format_elapsed` / `send_telegram(env, text, tier)`（tier 与 bash 同语义：alert 无回落、凭据缺失留痕）；**没有** `tg_add_*`（全是返回字符串，自己 `'\n'.join`） |
| bash 里内嵌的 python 段（`python3 - <<'PY'`） | 不能 import 共享层 | 必须在本文件内同义实现 `esc` / `tg_entry` / `tg_pre_block`，漏实现会 `NameError` → 整轮通知丢失 |

## 第 2 步：接线（漏了 = 通知静默消失，最常被忽略）

每个发通知的 step 都要有：

```yaml
      - name: "Notify: xxx 结果"
        if: ${{ always() }}          # 否则任务失败时反而收不到通知
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
          TG_RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
```

- **只注入 `TG_RUN_URL`**。不要注入 `TG_RUN_STARTED_AT: ${{ github.run_started_at }}`——
  平台没有该上下文（官方属性表只有 `run_id` / `run_number` / `run_attempt`），表达式对
  不存在的属性求值为空串；时长由助手侧的 `/proc/1` 开机时刻兜底，无需注入。
- 凭据校验在**调用方**、且要放在 `source` **之前**：`if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then echo "未配置，跳过"; exit 0; fi`。真源本身不校验。
- bash 真源有 `TG_BOT_TOKEN` / `TG_CHAT_ID` 别名回退（变量定义处搜 `TELEGRAM_BOT_TOKEN:=`）；**pwsh 没有**，必须注入 `TELEGRAM_*`。
- **告警/入口/凭据类通知（alert 档）还要多注两行**：`TELEGRAM_BOT_TOKEN_ALERT` / `TELEGRAM_CHAT_ID_ALERT`（照上面主 bot 两行的格式换成 `_ALERT` 后缀）。alert 档**无回落**：凭据缺失直接发送失败留痕，通知静默丢失——不传 tier 的通知不需要这两行。哪些通知走 alert 见台账档位列。
- python：凭据从传入的 `env` dict 读，但 `TG_RUN_URL` **只读 `os.environ`**，只给 dict 不够。
- pwsh step 要 `shell: pwsh`。
- **汇总类通知建议独立成 step**：业务步骤里常有 `exit 1` 早退（预检失败 / 磁盘不足），
  写在步骤末尾的通知会被一起跳过；跨 step 传结果只能落临时文件（两个 step 不共享 shell
  作用域）。范例：`openclaw.yml` 的 `Notify OpenClaw final archive result` 读
  `/tmp/openclaw-final-archive-results.tsv`。

## 第 3 步：搭消息

**最小骨架（bash）**——七个调用覆盖绝大多数场景：

```bash
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

msg=""
tg_add_title msg "✅ 某任务完成"                 # 必：emoji + 短语
tg_add_kv   msg "状态" "完成"                    # 自然语言值 → 裸文本
tg_add_path msg "文件" "$name"                   # 机器值 → <code>
tg_add_section msg "📋 明细 · ${count}"          # 列表分节必须带 " · N"
tg_add_block msg "$(tree_fold "${items%$'\n'}")" # 已构建条目流 → tree_fold
tg_add_note  msg "如确认无误，可忽略本条"         # 可选；段内不能带 HTML
tg_add_footer msg                                # 必：唯一收尾形态，自带空行

send_tg "$msg" || echo "::warning::TG 通知发送失败（不影响任务）"
```

清单的标准管线：`tg_add_entry`（逐条累积，已转义、已含 `<code>`）→ `tree_fold`（只截断 + 加折叠行）→ `tg_add_block`。

**区块顺序**：标题 → kv → 〔分节 → 条目 | pre〕× N → 说明段 → 收尾区。收尾区**必须唯一且在最后**。

**取值行口径**（最易混）：

| 值的性质 | 用哪个 | 例 |
|---|---|---|
| 机器返回：路径/文件名/命令/密码/IP/ID/端口/版本/原始异常串 | `tg_add_path` → `<code>` | `文件：<code>a.tar.gz</code>` |
| 自然语言：状态/结论/原因/备注 | `tg_add_kv` → 裸文本 | `状态：部分失败` |

**其余关键规则**（详见 `references/api-reference.md`）：

- 只有三种标签：`<code>` 机器值、`<pre>` 多行块、`<a>` 链接。**全库禁用 `<b>` / `<i>`**。
- 条目一律 `├─/└─` 树形，不用 `• ` 平铺。
- 空清单、零计数分节**整段跳过**——`✅ 已同步 · 0` 是图标与计数自相矛盾。
- 分节后跟**条目列表**才带 ` · N`；后跟 `<pre>` 或单段说明**不带**。
- 状态 emoji 必须随结论降级：0 成功 / 数据缺失 → ⚠️ 或 ❌，不要恒 ✅（规范 · 状态图标）。

## 第 4 步：发送

| 函数 | 适用 |
|---|---|
| `send_tg "$msg"` | 短消息单条（>3900 UTF-16 码元自动转分片） |
| `send_tg_chunked "$msg"` | 长消息（按 3800 UTF-16 码元分片，断在换行处、分片边界自动闭合/重开 HTML 标签）。**依赖 runner 上有 python3**，且分片失败被 `|| true` 吞掉 |
| `send_tg "$msg" alert` | **重要通知**（告警 + 信息：备份失败、归档告警、网关启动失败、入口/凭据等，档位清单见台账）。step 必须注入 `_ALERT` 凭据（第 2 步），否则失败留痕、通知丢失 |

- 失败**不许吞**：用 `|| echo "::warning::..."` 或 `|| true`，**不要** `>/dev/null 2>&1`。
- 已 source 发送层就**不得 curl 直发**。唯一例外是需要 `message_id` 的进度面板原地刷新（`openlist/telegram.sh`）。
- 真源**没有**文件发送函数。`sendDocument`/`sendVideo` 是媒体固有例外，caption 同样必须转义。
- pwsh `Send-TgMessage` **无分片**，超长会被 API 直接拒——pwsh 侧消息要自己控制长度。

## 第 5 步：写完自检

> 用户报某条通知「坏了」并贴出内容时：先**本地复现**那条通知再动手改，别凭代码推断——
> mock 掉协作者、把渲染结果捕获下来，自相矛盾的行会自己浮出来。手法见
> `skills/telegram-notify-audit/SKILL.md` 的「复现」一节。

1. **渲染预览**（能抓到纯代码审查漏掉的问题）：
   `bash skills/telegram-notify-audit/scripts/render_preview.sh`
   它会跑 16 项校验（分隔线 18 条、转义是否二次处理、树形前缀、折叠行、说明段空行、二层列表子行是否与条目正文同列等）。
2. **逐条过这 8 项**：
   - [ ] 标题 emoji 与结论一致？
   - [ ] 机器值走 `tg_add_path`、自然语言走 `tg_add_kv`？
   - [ ] 列表分节带 ` · N`，且空清单已跳过？
   - [ ] 条目累积用 `tg_add_entry`（不是 `$(tg_entry …)`）？
   - [ ] 折叠助手选对（见下）？
   - [ ] `tg_add_footer` 直接对**正文变量**原地追加？
   - [ ] 发送失败有留痕（没被 `>/dev/null` 吞）？
   - [ ] step 有 `if: always()` + 四项 env？
3. 改到 openlist 域的脚本 → 跑回归（见 `references/api-reference.md` 末节）。

## 必踩的坑

全库坑清单的**唯一真源**在 `references/api-reference.md` 第 4 节（按真实事故排序，
含二次转义、`exit 1` 早退、pwsh 自检、python 吞异常、`while read` 丢末条等 12 条），
写完自检时逐条对照，此处不再重复维护第二份。

## 参考文件

- `references/api-reference.md`——构件速查（三套实现对照、签名、折叠规则、时长/大小格式、状态图标）+ **全库唯一坑清单**（第 4 节）
- `references/examples.md`——5 类真实范例（均摘自本仓库，用函数名/标题锚点定位）
- `scripts/scaffold_notify.sh`——按场景生成骨架，省得手写
