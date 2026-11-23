# ===== Windows runner (pwsh) — Telegram 通知发送层 + 排版助手 =====
# 规范唯一真源: docs/telegram-notify.md。与 bash 版 telegram/tg_notify.sh 同语义:
#   - 统一 HTML parse_mode，动态内容必须经 Esc-Html 转义
#   - 429 限流按 API 响应里的 retry_after 重试（最多 5 次，等待钳到 60s 上限）；
#     5xx / 网络错误同样退避重试（attempt×2 秒）
#   - HTML 解析失败（400 can't parse entities）不重发、直接抛出:
#     消息本就没被 Telegram 接收，退化纯文本只会把版式 bug 藏起来
# 用法（workflow 中 dot-source，函数与变量进入当前作用域）:
#   . "$env:GITHUB_WORKSPACE\.github\scripts\telegram\tg_notify.ps1"
# 提供（5 个成员，与 api-reference「三套实现边界」一致）:
#   $TG_SEP                统一分隔线（18 个全角横线，勿手写）
#   Esc-Html <s>           HTML 实体转义（& < >）
#   Format-TgDuration <s>  秒数 → 中文三段式（X 小时 Y 分 / X 分钟 / X.XX 秒）
#   Get-TgFooter           收尾区字符串（⏱ 已运行 X · 🔗 运行日志；降级链见函数注释）
#   Send-TgMessage <text> [tier]  单条发送（HTML；校验响应 ok=true；失败 throw，
#                             错误含响应体前 200 字符；tier=alert 走 @SaberFuckBot，
#                             凭据缺失不回落主 bot）
# 无分片（bash 有）：超过 4096 UTF-16 码元整条会被 API 拒绝，pwsh 侧由调用方控制长度。

$TG_SEP = [string][char]0x2501 * 18   # 先转 [string] 再乘：char * int 未定义，别改成 ([char]… * 18)

# job 生命周期起点（Get-TgFooter 时长兜底用）：首次 dot-source 时记录，与 bash /
# python 的 /proc/1 兜底同口径（略晚于 job 启动，时长只少不多）。不要用机器整机
# 开机时刻——持久化 / self-hosted runner 上会把机器 uptime 误报成 run 时长。
if (-not $script:TG_T0) { $script:TG_T0 = Get-Date }

function Esc-Html([string]$s) {
  if (-not $s) { return $s }
  return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
}

# 秒数 → 中文三段式（X 小时 Y 分 / X 分钟 / X.XX 秒两位小数，与 bash tg_add_footer 逐字一致）
function Format-TgDuration([int]$totalSec) {
  $hh = [int][math]::Floor($totalSec / 3600)
  $mm = [int][math]::Floor(($totalSec % 3600) / 60)
  $ss = $totalSec % 60
  if ($hh -gt 0) { return "$hh 小时 $mm 分" }
  elseif ($mm -gt 0) { return "$mm 分钟" }
  else {
    # 秒统一两位小数，且强制 InvariantCulture（避免某些区域把小数点渲染成逗号）
    return ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.00}', $ss)) + " 秒"
  }
}

# 收尾区（与 bash tg_add_footer 同形态同降级链）:
#   ① TG_RUN_STARTED_AT（仅兼容本地测试覆写）—— 平台不提供
#      github.run_started_at 表达式上下文，workflow 注入恒为空串（规范 · 接线）；
#   ② 本次 job 生命周期起点兜底（dot-source 时记录的 $script:TG_T0；hosted runner
#      上与 job 启动同刻，误差秒级）；
#   ③ 仍取不到 → 无时长；TG_RUN_URL 缺失 → 无链接；两者皆无 → 空串
# ① 算得 ≤0（空值 / 解析失败 / 未来时间）都继续往 ② 走——不得出现「有值但算出 0
# 就把时长显示成 0.00 秒」，与 bash/python 侧口径一致
function Get-TgFooter {
  $startedSec = 0
  try {
    # 无偏移的 ISO 串按 UTC 解释（workflow / 本地测试注入的都是 UTC），
    # 避免 Kind=Unspecified 被 ToUniversalTime 当作本地时间而算错 delta
    $started = [DateTime]::Parse($Env:TG_RUN_STARTED_AT, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    $startedSec = [int][math]::Round(((Get-Date).ToUniversalTime() - $started).TotalSeconds)
  } catch { $startedSec = 0 }
  $dur = ""
  if ($startedSec -gt 0) { $dur = Format-TgDuration $startedSec }
  if (-not $dur) {
    try {
      if (-not $script:TG_T0) { $script:TG_T0 = Get-Date }
      $up = [int][math]::Round(((Get-Date) - $script:TG_T0).TotalSeconds)
      if ($up -gt 0) { $dur = Format-TgDuration $up }
    } catch { }
  }
  $footer = ""
  if ($dur) { $footer = "⏱ 已运行 $dur" }
  if ($Env:TG_RUN_URL) {
    if ($footer) { $footer += " · " }
    $footer += "🔗 <a href=""$(Esc-Html $Env:TG_RUN_URL)"">运行日志</a>"
  }
  return $footer
}

# 单条发送（HTML parse_mode；429 按 retry_after 重试最多 5 次；5xx / 网络错误退避重试；
# 其余失败 throw 并带响应体前 200 字符）
function Send-TgMessage([string]$text, [ValidateSet('', 'alert')][string]$tier) {
  # 档位路由（与 bash 发送层同语义）: alert → 告警 bot（@SaberFuckBot，无回落）
  $token = $Env:TELEGRAM_BOT_TOKEN
  $chat = $Env:TELEGRAM_CHAT_ID
  if ($tier -eq 'alert') {
    $token = $Env:TELEGRAM_BOT_TOKEN_ALERT
    $chat = $Env:TELEGRAM_CHAT_ID_ALERT
  }
  # 凭据缺失在发网络请求前显式失败（alert 档不回落主 bot），别把空 chat_id
  # 送成一个难以排查的 API 报错
  if (-not $token -or -not $chat) {
    throw "❌ Telegram 凭据缺失（$(if ($tier -eq 'alert') { 'TELEGRAM_BOT_TOKEN_ALERT / TELEGRAM_CHAT_ID_ALERT，不回落主 bot' } else { 'TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID' })），通知未发送"
  }
  $body = @{ chat_id = $chat; text = $text; disable_web_page_preview = 'true'; parse_mode = 'HTML' }
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
      # TimeoutSec 对齐 bash 的 curl -m 15，避免默认 100s 把重试窗口拖穿
      $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" `
        -Method Post -Body $body -TimeoutSec 15
    } catch {
      $resp = $_.Exception.Response
      $status = 0
      if ($resp -and $resp.StatusCode) { $status = [int]$resp.StatusCode }
      # 响应体先取：429 解析 retry_after 与最终报错都要用（如 "can't parse entities"）
      $detail = [string]$_.ErrorDetails.Message
      if ($status -eq 429) {
        # retry_after 优先读 API 响应体 JSON（bash 发送层同款）；PS7 的
        # HttpResponseMessage.Headers 没有字符串索引器，只能 TryGetValues 兜底；
        # 都拿不到退 5s。等待钳到 60s，防异常值把整个 step 拖死
        $wait = 5
        try {
          $ra = ($detail | ConvertFrom-Json).parameters.retry_after
          if ($ra) { $wait = [int]$ra }
        } catch { Write-Host "ℹ️ 429 响应体未解析出 retry_after，走头部/默认: $detail" }
        if ($wait -le 5 -and $resp -and $resp.Headers) {
          try {
            $hv = $null
            if ($resp.Headers.TryGetValues('Retry-After', [ref]$hv) -and $hv) {
              $wait = [int]($hv | Select-Object -First 1)
            }
          } catch { Write-Host "ℹ️ Retry-After 头读取失败，维持默认 5s: $($_.Exception.Message)" }
        }
        $wait = [Math]::Min($wait, 60)
        Write-Host "⚠️ Telegram 限流 (429)，等待 ${wait}s 后重试 ($attempt/5)..."
        Start-Sleep -Seconds $wait
        continue
      }
      if ($status -ge 500 -or $status -eq 0) {
        # 5xx / 网络错误（连不上时 status=0）是瞬时故障：退避重试，避免就绪通知直接丢失
        if ($attempt -lt 5) {
          $w = $attempt * 2
          Write-Host "⚠️ Telegram 5xx/网络错误 (HTTP $status)，${w}s 后重试 ($attempt/5)..."
          Start-Sleep -Seconds $w
          continue
        }
      }
      if ($detail) { throw "Telegram 通知发送失败 (HTTP $status): $($detail.Substring(0, [Math]::Min(200, $detail.Length)))" }
      throw
    }
    # 200 且 ok=true 才算成功：代理 / 门户页返回 200 但非 Telegram 正文时要留痕，
    # 不能静默当成已发送
    if ($r -isnot [pscustomobject] -or -not $r.ok) {
      $bad = ($r | ConvertTo-Json -Compress -Depth 3)
      throw "Telegram 响应异常（ok≠true，疑似代理拦截）: $($bad.Substring(0, [Math]::Min(200, $bad.Length)))"
    }
    return
  }
  throw "Telegram 通知发送失败（重试 5 次仍失败）"
}
