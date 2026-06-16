"""生成 TG_USER_SESSION 字符串。

调用方式：
    TG_API_ID=<id> TG_API_HASH=<hash> [TG_PROXY=<url>] \\
        python3 generate_string_session.py [--phone <phone>] --output <file>

行为：
- 从 stdin 读取手机号（如果未通过 --phone 传入）。
- 调用 telethon 进行交互式登录（要求输入验证码 / 2FA 密码）。
- 成功时把 StringSession 写入 --output 指定的文件（只含 session 字符串，无其他内容）。
- 失败时把错误信息打印到 stderr，并以非零 exit code 退出。

注意：
- 启用 telethon logging（WARNING 级别），方便排查「session 已存在 / 数据库被锁 / IP 风控」等问题。
- 不在工作目录下创建任何 .session 文件，避免污染安装目录。
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import logging
import os
import sys

from dotenv import load_dotenv
from telethon import TelegramClient, errors
from telethon.sessions import StringSession

from proxy_config import get_proxy_from_env


def _setup_logging() -> None:
    logging.basicConfig(
        format="[%(levelname)s %(asctime)s] %(name)s: %(message)s",
        level=logging.WARNING,
    )


def _prompt_phone(default: str | None) -> str:
    suffix = f" [{default}]" if default else ""
    raw = input(f"Please enter your phone (international format, e.g. +8613800138000){suffix}: ").strip()
    if not raw and default:
        return default
    if not raw:
        print("Phone number is required.", file=sys.stderr)
        sys.exit(2)
    return raw


def _code_callback() -> str:
    return input("Please enter the code you received: ").strip()


def _password_callback() -> str:
    return getpass.getpass("Please enter your 2FA password: ")


async def _run(api_id: int, api_hash: str, proxy, phone: str | None) -> str:
    client = TelegramClient(StringSession(), api_id, api_hash, proxy=proxy)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            phone_to_use = phone or _prompt_phone(None)
            await client.send_code_request(phone_to_use)
            try:
                await client.sign_in(phone_to_use, code=_code_callback())
            except errors.SessionPasswordNeededError:
                await client.sign_in(password=_password_callback())
        session_string = client.session.save()
        if not session_string:
            print("Telethon returned an empty session string.", file=sys.stderr)
            sys.exit(3)
        return session_string
    finally:
        await client.disconnect()


def main() -> None:
    _setup_logging()
    load_dotenv()

    parser = argparse.ArgumentParser(description="Generate Telegram StringSession for TG_download_bot.")
    parser.add_argument("--output", required=True, help="Path to write the session string to.")
    parser.add_argument(
        "--phone",
        default=os.environ.get("TG_PHONE"),
        help="Phone number in international format. If omitted, will prompt on stdin.",
    )
    args = parser.parse_args()

    api_id_raw = os.environ.get("TG_API_ID")
    api_hash = os.environ.get("TG_API_HASH")
    if not api_id_raw or not api_hash:
        print("TG_API_ID and TG_API_HASH environment variables are required.", file=sys.stderr)
        sys.exit(2)
    try:
        api_id = int(api_id_raw)
    except ValueError:
        print(f"TG_API_ID must be an integer, got: {api_id_raw!r}", file=sys.stderr)
        sys.exit(2)

    try:
        proxy = get_proxy_from_env()
    except ValueError as exc:
        print(f"Invalid TG_PROXY: {exc}", file=sys.stderr)
        sys.exit(2)

    try:
        session_string = asyncio.run(_run(api_id, api_hash, proxy, args.phone))
    except KeyboardInterrupt:
        print("\nAborted by user.", file=sys.stderr)
        sys.exit(130)
    except errors.PhoneCodeInvalidError:
        print("The login code is invalid.", file=sys.stderr)
        sys.exit(4)
    except errors.PhoneCodeExpiredError:
        print("The login code has expired. Please request a new one.", file=sys.stderr)
        sys.exit(4)
    except errors.PasswordHashInvalidError:
        print("The 2FA password is invalid.", file=sys.stderr)
        sys.exit(4)
    except errors.FloodWaitError as exc:
        print(f"Flood wait: please retry in {exc.seconds} seconds.", file=sys.stderr)
        sys.exit(5)
    except errors.RPCError as exc:
        print(f"Telegram RPC error: {exc}", file=sys.stderr)
        sys.exit(6)
    except Exception as exc:  # noqa: BLE001
        print(f"Unexpected error while generating session: {exc!r}", file=sys.stderr)
        sys.exit(1)

    output_path = args.output
    tmp_path = f"{output_path}.tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8") as fp:
            fp.write(session_string)
            fp.write("\n")
        os.replace(tmp_path, output_path)
    except OSError as exc:
        print(f"Failed to write session to {output_path}: {exc}", file=sys.stderr)
        sys.exit(7)

    # 这行只输出 session 本身，shell 通过 --output 读取，避免 grep tail 解析
    print(session_string)


if __name__ == "__main__":
    main()