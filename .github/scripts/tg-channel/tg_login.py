#!/usr/bin/env python3
"""交互式生成 Telethon StringSession 并直写 GitHub Secret TG_SESSION。

用法：
    python3 tg_login.py        # 二维码登录（默认，回车即选）
    python3 tg_login.py 2      # 手机号 + 验证码登录

凭据解析顺序（TG_API_ID / TG_API_HASH）：
    1. 环境变量
    2. ~/.tg_creds（KEY=VALUE 格式，缺省路径见 CREDS_FILE）
    3. ~/.openclaw/.env（OpenClaw 持久凭据文件）
    4. 交互输入（API HASH 不回显）

session 全程不打印、不落盘，生成后直接 `gh secret set` 写入
jarvanh/actions1 的 TG_SESSION。运行环境需已有 gh 凭据
（GH_TOKEN 环境变量或 `gh auth login`），或 ~/.openclaw/.env
已配置 GH_TOKEN。

二维码过期自动刷新重印，无需重跑；两步验证出现提示时输入密码即可。
"""
import asyncio
import os
import sys
import getpass
import subprocess
from pathlib import Path

REPO = "jarvanh/actions1"
SECRET = "TG_SESSION"
CREDS_FILES = (Path.home() / ".tg_creds", Path.home() / ".openclaw" / ".env")

try:
    from telethon import TelegramClient, errors
    from telethon.sessions import StringSession
except ImportError:
    print("缺少依赖：pip install telethon qrcode")
    sys.exit(1)

try:
    import qrcode
except ImportError:
    print("缺少依赖：pip install telethon qrcode")
    sys.exit(1)


def load_creds():
    """优先级：环境变量 > ~/.tg_creds > ~/.openclaw/.env > 交互输入。"""
    creds = {}
    for path in CREDS_FILES:
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                creds[key.strip()] = value.strip()

    api_id = os.environ.get("TG_API_ID") or creds.get("TG_API_ID")
    api_hash = os.environ.get("TG_API_HASH") or creds.get("TG_API_HASH")
    if not api_id or not api_hash:
        print("未找到 TG_API_ID / TG_API_HASH（环境变量、~/.tg_creds、~/.openclaw/.env），请手动输入：")
    api_id = api_id or input("API ID: ").strip()
    api_hash = api_hash or getpass.getpass("API HASH: ").strip()

    if not api_id or not api_hash:
        sys.exit("❌ API ID / API HASH 缺失，无法登录")
    try:
        return int(api_id), api_hash
    except ValueError:
        sys.exit("❌ API ID 必须是数字")


def write_secret(session: str):
    """session 经 **stdin** 写入 GitHub Secret；不进 argv、不打印、不落盘。

    为什么不用 --body：`gh secret set --body <value>` 会把 session 明文放进进程参数，
    同机其它进程读 /proc/<pid>/cmdline 即可拿到（2026-11-26 审查发现）。gh 在未指定
    --body 时从标准输入读取，等价且不可见于 argv；这里用 input= 直接喂字符串，
    既不经临时文件也不进 shell。"""
    env = os.environ.copy()
    if "GH_TOKEN" not in env:
        # 尝试从 ~/.openclaw/.env 取 GH_TOKEN
        for path in CREDS_FILES:
            if not path.exists():
                continue
            for line in path.read_text().splitlines():
                line = line.strip()
                if line.startswith("GH_TOKEN="):
                    env["GH_TOKEN"] = line.split("=", 1)[1].strip()

    result = subprocess.run(
        ["gh", "secret", "set", SECRET, "--repo", REPO],
        input=session + "\n", capture_output=True, text=True, env=env,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        sys.exit(f"❌ gh secret set 失败（检查 gh 凭据或 GH_TOKEN 配置）：{detail}")


async def qr_login(client: TelegramClient):
    """二维码登录：过期自动 recreate 并重印，直到扫码确认或用户中断。"""
    qr = await client.qr_login()
    print("手机 Telegram → 设置 → 设备 → 扫描二维码：")
    while True:
        code = qrcode.QRCode(border=1)
        code.add_data(qr.url)
        code.print_ascii(invert=True)
        print(f"有效期至 {qr.expires:%H:%M:%S}，过期自动刷新 ↓")
        try:
            return await qr.wait()
        except errors.SessionPasswordNeededError:
            # 二维码授权一般不触发两步验证；保留兜底以防服务端要求
            return await client.sign_in(password=getpass.getpass("两步验证密码: "))
        except (asyncio.TimeoutError, TimeoutError):
            await qr.recreate()


async def phone_login(client: TelegramClient):
    """手机号 + 验证码登录，两步验证时追加密码（不回显）。"""
    phone = input("手机号（含国际区号，如 +8613800000000）: ").strip()
    await client.send_code_request(phone)
    code = input("收到的验证码: ").strip()
    try:
        return await client.sign_in(phone, code)
    except errors.SessionPasswordNeededError:
        return await client.sign_in(phone=phone, code=code,
                                   password=getpass.getpass("两步验证密码: "))


async def main():
    if sys.argv[1:] and sys.argv[1] not in ("1", "2"):
        sys.exit("用法：python3 tg_login.py [1=二维码(默认) | 2=手机号验证码]")
    mode = sys.argv[1] if sys.argv[1:] else (
        input("登录方式 [1]二维码（回车默认） [2]手机号验证码: ").strip() or "1")
    api_id, api_hash = load_creds()

    client = TelegramClient(StringSession(), api_id, api_hash)
    await client.connect()
    try:
        if mode == "2":
            user = await phone_login(client)
        else:
            user = await qr_login(client)
        session = client.session.save()
        me = await client.get_me()
    except KeyboardInterrupt:
        sys.exit("\n已取消登录")
    finally:
        await client.disconnect()

    who = f"@{me.username}" if me.username else me.first_name
    write_secret(session)
    print(f"✅ 已登录：{who}")
    print(f"✅ 已写入 {REPO} 的 {SECRET}（长度 {len(session)}，值未打印、未落盘）")


if __name__ == "__main__":
    asyncio.run(main())
