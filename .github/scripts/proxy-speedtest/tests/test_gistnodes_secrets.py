#!/usr/bin/env python3
"""gistnodes 的显式 secrets 必须被被调 workflow 逐个声明（2026-11-14 回归）。

事故：commit 5cefe6df（2026-11-13）把 proxy-speedtest-gistnodes 三个 `uses:` job 的
`secrets: inherit` 改成显式映射（least-privilege），但被调的 gitee/cdn/taier 三个
workflow 的 `on.workflow_call` 里没有 `secrets:` 声明 ⇒ GitHub 在**启动阶段**直接判
startup_failure（run 43457889463 / 43561712476，jobs 为空、页面无细节）。

本测试把「显式映射 ⊆ 被调声明」钉成静态判据：以后改任一侧而漏改另一侧，这里先红，
不用等下一轮定时（2 次/天）才发现整条 gist 抓节点路径根本没启动。

跑法：`python3 .github/scripts/proxy-speedtest/tests/test_gistnodes_secrets.py`
退出码 0 = 全过。
"""
import pathlib
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parents[4]
WORKFLOWS = REPO / '.github' / 'workflows'
GISTNODES = WORKFLOWS / 'proxy-speedtest-gistnodes.yml'

FAILURES = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


def workflow_on(doc):
    """PyYAML 按 YAML 1.1 会把裸 `on:` 解析成布尔 True，两种键都认。"""
    return doc.get('on') if 'on' in doc else doc.get(True)


def declared_call_secrets(doc):
    on = workflow_on(doc) or {}
    call = on.get('workflow_call') or {}
    return set((call.get('secrets') or {}).keys())


def main():
    gist_doc = yaml.safe_load(GISTNODES.read_text(encoding='utf-8'))
    jobs = gist_doc.get('jobs') or {}
    callers = []
    for job_name, job in jobs.items():
        uses = str(job.get('uses') or '')
        if uses.startswith('./.github/workflows/proxy-speedtest-'):
            callers.append((job_name, job))

    print('== 1. 编排层三个测速 job 都还在、都走显式 secrets 映射 ==')
    check(len(callers) == 3,
          f'找到 3 个被复用的测速 job（实际 {len(callers)}：{[n for n, _ in callers]}）')

    for job_name, job in callers:
        uses = str(job['uses'])
        called_path = REPO / uses[2:]
        check(called_path.exists(), f'{job_name}: 被调文件存在（{uses}）')
        if not called_path.exists():
            continue
        declared = declared_call_secrets(
            yaml.safe_load(called_path.read_text(encoding='utf-8')))
        passed = set((job.get('secrets') or {}).keys())
        print(f'-- {job_name}: 传入 {len(passed)} 个 / 声明 {len(declared)} 个 --')
        check(bool(passed), f'{job_name}: 使用显式 secrets 映射（不是 inherit）')
        check(bool(declared),
              f'{job_name}: 被调 workflow 有 on.workflow_call.secrets 声明')
        undeclared = sorted(passed - declared)
        check(not undeclared,
              f'{job_name}: 传入的 secret 全部已声明（未声明：{undeclared}）')
        missing = sorted(declared - passed)
        if missing:
            # 只是提示：声明了但本轮不传是合法的（空值），不判失败
            print(f'     提示：{job_name} 声明了但未传入：{missing}')

    print('== 2. 反向：声明不许被删成空壳（否则「未声明」会从 startup_failure 变成空值）==')
    for job_name, job in callers:
        called_path = REPO / str(job['uses'])[2:]
        if not called_path.exists():
            continue
        declared = declared_call_secrets(
            yaml.safe_load(called_path.read_text(encoding='utf-8')))
        check(len(declared) >= 8,
              f'{job_name}: 声明数量与工作流实际依赖同量级（实际 {len(declared)}）')

    print()
    if FAILURES:
        print(f'FAILED: {len(FAILURES)} 项未通过')
        for f in FAILURES:
            print(f'  - {f}')
        return 1
    print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
