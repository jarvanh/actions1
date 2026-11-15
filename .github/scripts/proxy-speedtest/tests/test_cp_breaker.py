#!/usr/bin/env python3
"""泰尔控制面连续失败熔断的自检（2026-11-15 引入）。

背景（2026-11-14 run 43618341804 实测）：gistnodes 编排轮交接 1692 个公开节点，
组延迟表只回来 23 个（覆盖 1.4%）→ 按 fail-open 契约全量放行；随后 920/920 个节点
全部卡在泰尔控制面 `getIpLocSP.php: EOF`，没有一个成功。脚本按「逐节点失败」记账，
一路烧到 5 小时预算才收摊，产出 qualified=0、job 仍 success——零产出 + 纯烧预算。

修复是在主循环加最后一道闸：开测至今**零成功** 且 连续 N 个失败都带控制面签名
（cnspeedtest.cn / duoweisoft.com）就提前收摊。这里钉四类边界：

  1. 判据阈值：streak < N 不收摊；streak ≥ N 且零成功收摊；threshold ≤ 0 恒不收摊
     （逃生阀）。
  2. 「零成功」是硬条件：中途哪怕测出 1 个成功节点，控制面抖动也不许收摊
     （收摊会把还可能测出更多节点的整轮提前砍掉，只在「确定全废」时才允许）。
  3. 签名匹配：EOF / context deadline exceeded / TLS 错三类控制面报错都算；
     「节点慢」「下行端点限频 403」「切换失败」这类正常失败**不算**——它们不该
     触发收摊（好节点在慢时段整轮失败是常态）。
  4. 主循环口径（直接驱动真实计数逻辑的等价序列）：成功重置连败、非控制面失败
     重置连败、控制面失败累计连败——线上 920 连败序列在 N=10 下应恰好在第 10 个
     失败后收摊。

跑法：`python3 .github/scripts/proxy-speedtest/tests/test_cp_breaker.py`
退出码 0 = 全过。
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from taier_speedtest import (
    is_control_plane_unreachable_error,
    should_break_control_plane,
)

FAILURES = []


def check(cond, label, detail=''):
    print(('  PASS  ' if cond else '  FAIL  ') + label + (f'  [{detail}]' if detail and not cond else ''))
    if not cond:
        FAILURES.append(label)


# ── 1. 阈值边界 ────────────────────────────────────────────────────────────
check(not should_break_control_plane(9, 0, 10), 'streak=9 阈值=10 不收摊')
check(should_break_control_plane(10, 0, 10), 'streak=10 阈值=10 零成功 → 收摊')
check(should_break_control_plane(15, 0, 10), 'streak 超过阈值仍收摊（≥ 语义）')
check(not should_break_control_plane(9, 0, 0), 'threshold=0 关闭（逃生阀）')
check(not should_break_control_plane(9999, 0, -3), 'threshold 负数同样关闭')

# ── 2. 零成功硬条件 ────────────────────────────────────────────────────────
check(not should_break_control_plane(50, 1, 10), '已有 1 个成功节点 → 不许收摊（控制面抖动≠全废）')
check(not should_break_control_plane(10, 3, 10), '成功数 > 0 且 streak 达标 → 仍不收摊')

# ── 3. 控制面签名匹配 ──────────────────────────────────────────────────────
CP_ERRORS = [
    '[X] Get "https://dlcv2.cnspeedtest.cn:8443/dataServer/getIpLocSP.php": EOF',
    '[X] Get "https://dlcv2.cnspeedtest.cn:8443/dataServer/getIpLocSP.php": '
    'context deadline exceeded (Client.Timeout exceeded while awaiting headers)',
    '[X] Get "http://dlcv2.duoweisoft.com:8088/dataServer/getIpLocSP.php": '
    'context deadline exceeded (Client.Timeout exceeded while awaiting headers)',
    'Get "https://dlcv2.cnspeedtest.cn:8443/dataServer/getIpLocSP.php": '
    'tls: first record does not look like a TLS handshake',
]
for i, e in enumerate(CP_ERRORS, 1):
    check(is_control_plane_unreachable_error(e), f'控制面签名 #{i} 命中', e[:60])

NON_CP_ERRORS = [
    # 下行端点限频 / 节点慢（不该触发收摊）
    '[debug-dl] proxied=403 body="rate limited" | url=http://1.2.3.4:8080/speed/...',
    'rc=124（无输出）',
    '切换失败：Resource not found',
    '连不上测速点 广东联通（延迟/上下行全空）',
    '',
    None,
]
for i, e in enumerate(NON_CP_ERRORS, 1):
    check(not is_control_plane_unreachable_error(e), f'非控制面失败 #{i} 不命中', str(e)[:60])

# ── 4. 主循环计数口径（等价序列驱动）──────────────────────────────────────
def simulate(errors, threshold=10):
    """按主循环同款规则重放失败序列：成功重置、非控制面失败重置、控制面失败累计。"""
    streak = 0
    ok_count = 0
    stop_at = None
    for idx, err in enumerate(errors, 1):
        if err is None:  # 成功节点
            ok_count += 1
            streak = 0
        elif is_control_plane_unreachable_error(err):
            streak += 1
        else:
            streak = 0
        if stop_at is None and should_break_control_plane(streak, ok_count, threshold):
            stop_at = idx
    return stop_at

# 线上 2026-11-14 gistnodes 轮的形态：920 个全是控制面 EOF，无成功
cp_eof = CP_ERRORS[0]
check(simulate([cp_eof] * 920, 10) == 10, '920 连败在 N=10 下第 10 个收摊')
# 定时轮形态（run 43582907303）：159 个里 7 个控制面失败、零散分布，永不收摊
mixed = [None] * 159
for pos in (3, 40, 77, 101, 122, 140, 155):
    mixed[pos] = cp_eof
check(simulate(mixed, 10) is None, '零散控制面失败（定时轮形态）不收摊')
# 抖动形态：8 连败后成功 1 个再 8 连败 → 计数被成功重置，不收摊
jitter = [cp_eof] * 8 + [None] + [cp_eof] * 8
check(simulate(jitter, 10) is None, '8 连败+1 成功+8 连败：成功重置计数，不收摊')
# 中途混入非控制面失败也重置
mixed_fail = [cp_eof] * 6 + ['403 rate limited'] + [cp_eof] * 6
check(simulate(mixed_fail, 10) is None, '非控制面失败重置计数，不收摊')

print()
if FAILURES:
    print(f'❌ {len(FAILURES)} 项失败:')
    for f in FAILURES:
        print('   -', f)
    sys.exit(1)
print('✅ 控制面熔断自检全过')
