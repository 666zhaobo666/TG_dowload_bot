import asyncio
import os

from dotenv import load_dotenv
from telethon import TelegramClient
from telethon.sessions import StringSession
from proxy_config import get_proxy_from_env


async def main() -> None:
    load_dotenv()
    api_id = int(os.environ["TG_API_ID"])
    api_hash = os.environ["TG_API_HASH"]
    proxy = get_proxy_from_env()

    async with TelegramClient(StringSession(), api_id, api_hash, proxy=proxy) as client:
        await client.start()
        session_string = client.session.save()
        print("Put the following value into TG_USER_SESSION in your .env file:")
        print(session_string)


if __name__ == "__main__":
    asyncio.run(main())
