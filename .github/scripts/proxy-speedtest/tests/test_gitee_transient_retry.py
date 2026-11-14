#!/usr/bin/env python3
"""gitee 瞬时错误重试 + 上下行解耦的自检（2026-11-14）。

背景（run 43539525606）：336 个节点 **168 个失败**——87 个 GnuTLS recv -110、
12 个 push 60s 超时、6 个 TLS 握手失败、clone 90s 超时、HTTP 502 等。且旧实现里
clone 抛异常会让整条结果 `ok=False`，把已经测出的 `upload_mibs` 一起丢掉。

本文件钉住三件事：

  1. 瞬时错误判据只命中真正的网络抖动；鉴权失败（could not read Username）不重试；
  2. `retry_transient_git`：瞬时错误重试一次后成功；非瞬时/次数耗尽原样抛出，
     绝不吞异常（main 的仓库重建判据与失败落账都靠异常）；
  3. `speedtest_single_item` 解耦：push 成功 + clone 失败 ⇒ ok=True 且保留 upload；
     push 失败 + clone 成功 ⇒ ok=True 且保留 download；两个方向全失败 ⇒ 抛异常。

跑法：`python3 .github/scripts/proxy-speedtest/tests/test_gitee_transient_retry.py`
退出码 0 = 全过。
"""
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import speedtest_gitee as G  # noqa: E402

FAILURES = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


TRANSIENT_SAMPLES = [
    "error: RPC failed; curl 56 GnuTLS recv error (-110): "
    "The TLS connection was non-properly terminated.",
    "Command '['git', 'push', '-f', 'origin', 'HEAD:refs/heads/master']' "
    "timed out after 60 seconds",
    "error: RPC failed; curl 35 Recv failure: Connection reset by peer",
    "fatal: early EOF",
    "fetch-pack: unexpected disconnect while reading sideband packet",
    "error: RPC failed; HTTP 502 curl 22 The requested URL returned error: 502",
    "fatal: unable to access 'https://gitee.com/x/y.git/': GnuTLS, handshake failed: "
    "The TLS connection was non-properly terminated.",
]

AUTH_ERROR = ("fatal: could not read Username for 'https://gitee.com': "
              "No such device or address")


def test_pattern():
    print('== 1. 瞬时错误判据（命中真实失败 / 不命中鉴权失败）==')
    for text in TRANSIENT_SAMPLES:
        check(bool(G._TRANSIENT_GIT_ERROR_RE.search(text)),
              f'命中瞬时错误：{text[:56]}')
    check(not G._TRANSIENT_GIT_ERROR_RE.search(AUTH_ERROR),
          '鉴权失败（could not read Username）不判瞬时')


def test_retry():
    print('== 2. retry_transient_git 的三种路径 ==')
    calls = []

    def flaky():
        calls.append(1)
        if len(calls) < 2:
            raise RuntimeError(TRANSIENT_SAMPLES[1])
        return 'ok'

    check(G.retry_transient_git('upload_push', flaky, backoff_seconds=0) == 'ok',
          '瞬时错误：重试一次后成功')
    check(len(calls) == 2, f'总尝试 2 次（实际 {len(calls)}）')

    auth_calls = []

    def broken():
        auth_calls.append(1)
        raise RuntimeError(AUTH_ERROR)

    raised = False
    try:
        G.retry_transient_git('upload_push', broken, backoff_seconds=0)
    except RuntimeError:
        raised = True
    check(raised and len(auth_calls) == 1, '非瞬时错误：不重试、直接抛')

    expired_calls = []

    def always():
        expired_calls.append(1)
        raise RuntimeError(f'timed out after 60 seconds (call {len(expired_calls)})')

    raised, last = False, ''
    try:
        G.retry_transient_git('download_clone', always, backoff_seconds=0)
    except RuntimeError as e:
        raised, last = True, str(e)
    check(raised and 'call 2' in last,
          f'次数耗尽：抛最后一次异常（实际 {last!r}）')
    check(len(expired_calls) == 2, f'总尝试 2 次（实际 {len(expired_calls)}）')


class _Stub:
    """临时替换 speedtest_single_item 的外部依赖，退出时原样恢复。"""

    ATTRS = ('switch_proxy', 'latency_probe', '_proxied_egress_ip',
             'retry_transient_git', 'upload_speedtest', 'git_clone_testbranch')

    def __enter__(self):
        self.saved = {name: getattr(G, name) for name in self.ATTRS}
        G.switch_proxy = lambda *a, **k: None
        G.latency_probe = lambda *a, **k: {
            'ok': True, 'min_ms': 10.0, 'median_ms': 12.0,
            'samples': 4, 'error': None,
        }
        G._proxied_egress_ip = lambda *a, **k: '203.0.113.9'
        # 解耦语义与重试语义分开测：这里让重试层直通，只验结果聚合
        G.retry_transient_git = lambda label, func, **kw: func()
        return self

    def __exit__(self, *exc):
        for name, value in self.saved.items():
            setattr(G, name, value)
        return False


def _item():
    return {'name': 'node-1', 'provider': 'p', 'type': 'ss',
            'proxy_obj': {'type': 'ss', 'server': 'x', 'port': 443}}


def test_decoupled_results():
    print('== 3. speedtest_single_item：上下行独立记账 ==')
    with _Stub():
        G.upload_speedtest = lambda **kw: (8.0, 10 * 1024 * 1024)

        def clone_fail(**kw):
            raise RuntimeError(TRANSIENT_SAMPLES[0])

        G.git_clone_testbranch = clone_fail
        res = G.speedtest_single_item(
            {}, {'remote_with_token': 'https://x/y.git'}, _item(),
            pathlib.Path('/tmp/unused.bin'), 60, 90, 0, 'both', True, '')
        check(res['ok'] is True, 'push 成功 + clone 失败 ⇒ 节点仍算可用')
        check(res.get('upload_mibs') == 1.25,
              f'10MiB / 8s = 1.25 MiB/s 保留（实际 {res.get("upload_mibs")}）')
        check('download_mibs' not in res, 'clone 失败 ⇒ 不带 download_mibs')
        check('GnuTLS' in (res.get('download_error') or ''),
              'download_error 记录真实原因')

    with tempfile.TemporaryDirectory() as td:
        fake = pathlib.Path(td) / 'proxy_speedtest.bin'
        fake.write_bytes(b'x' * (1024 * 1024))  # 1MiB，stat 用
        with _Stub():
            def push_fail(**kw):
                raise RuntimeError(AUTH_ERROR)

            G.upload_speedtest = push_fail
            G.git_clone_testbranch = lambda **kw: (16.0, fake)
            res = G.speedtest_single_item(
                {}, {'remote_with_token': 'https://x/y.git'}, _item(),
                pathlib.Path('/tmp/unused.bin'), 60, 90, 0, 'both', True, '')
        check(res['ok'] is True, 'push 失败 + clone 成功 ⇒ 节点仍算可用')
        check('upload_mibs' not in res, 'push 失败 ⇒ 不带 upload_mibs')
        check(res.get('upload_error') == AUTH_ERROR, 'upload_error 记录真实原因')
        check(res.get('download_mibs') == 0.06,
              f'1MiB / 16s = 0.06 MiB/s（实际 {res.get("download_mibs")}）')

    with _Stub():
        def push_fail(**kw):
            raise RuntimeError(AUTH_ERROR)

        def clone_fail(**kw):
            raise RuntimeError(TRANSIENT_SAMPLES[0])

        G.upload_speedtest = push_fail
        G.git_clone_testbranch = clone_fail
        raised, text = False, ''
        try:
            G.speedtest_single_item(
                {}, {'remote_with_token': 'https://x/y.git'}, _item(),
                pathlib.Path('/tmp/unused.bin'), 60, 90, 0, 'both', True, '')
        except RuntimeError as e:
            raised, text = True, str(e)
        check(raised and 'could not read Username' in text and 'GnuTLS' in text,
              f'两个方向全失败 ⇒ 合并原因抛异常（实际 {text!r}）')

    print('== 4. push-only 模式跳过 clone ==')
    with _Stub():
        G.upload_speedtest = lambda **kw: (8.0, 10 * 1024 * 1024)

        def should_not_call(**kw):
            raise AssertionError('push-only 不应调用 clone')

        G.git_clone_testbranch = should_not_call
        res = G.speedtest_single_item(
            {}, {'remote_with_token': 'https://x/y.git'}, _item(),
            pathlib.Path('/tmp/unused.bin'), 60, 90, 0, 'push-only', True, '')
        check(res['ok'] is True and 'download_mibs' not in res,
              'push-only：只记上行、不测下载')


if __name__ == '__main__':
    test_pattern()
    test_retry()
    test_decoupled_results()
    print()
    if FAILURES:
        print(f'FAILED: {len(FAILURES)} 项未通过')
        for f in FAILURES:
            print(f'  - {f}')
        sys.exit(1)
    print('全部通过')
    sys.exit(0)
