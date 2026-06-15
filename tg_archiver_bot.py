import asyncio
import os
from pathlib import Path
from time import time

from dotenv import load_dotenv
from telethon import Button, TelegramClient, events, functions, types
from telethon.sessions import StringSession

from archiver_core import (
    ArchiveResult,
    ArchiveStoppedError,
    archive_channel,
    archive_forwarded_message,
    archive_message_by_link,
    ChannelArchiveSummary,
    DownloadOptions,
    TaskControl,
    clamp_concurrency,
    describe_forward,
)
from proxy_config import get_proxy_from_env


channel_choices: dict[int, dict] = {}
pending_download_choices: dict[int, dict] = {}
active_task: dict[str, object] = {
    "kind": None,
    "title": None,
    "control": None,
    "last_progress": None,
}


def build_channel_choice_buttons() -> list[list[Button]]:
    return [
        [Button.inline("全部", b"channel:full"), Button.inline("最新200", b"channel:200")],
        [Button.inline("最新100", b"channel:100"), Button.inline("最新50", b"channel:50")],
    ]


def parse_download_dir_aliases(raw: str) -> dict[str, str]:
    aliases: dict[str, str] = {}
    for entry in raw.split(";"):
        entry = entry.strip()
        if not entry or "=" not in entry:
            continue
        alias_name, alias_path = entry.split("=", 1)
        alias_name = alias_name.strip()
        alias_path = alias_path.strip()
        if alias_name and alias_path:
            aliases[alias_name] = alias_path
    return aliases


def build_download_dir_buttons(alias_map: dict[str, str]) -> list[list[Button]]:
    rows: list[list[Button]] = []
    row: list[Button] = []
    for alias_name in alias_map.keys():
        row.append(Button.inline(alias_name, f"dir:{alias_name}".encode("utf-8")))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    return rows


async def sync_bot_commands(bot_client: TelegramClient) -> None:
    await bot_client(
        functions.bots.SetBotCommandsRequest(
            scope=types.BotCommandScopeDefault(),
            lang_code="zh",
            commands=[
                types.BotCommand(command="start", description="显示帮助"),
                types.BotCommand(command="message", description="下载消息或评论链接"),
                types.BotCommand(command="channel", description="下载频道消息"),
                types.BotCommand(command="pause", description="暂停当前任务"),
                types.BotCommand(command="resume", description="恢复当前任务"),
                types.BotCommand(command="stop", description="停止当前任务"),
            ],
        )
    )


def current_task_running() -> bool:
    control = active_task.get("control")
    return isinstance(control, TaskControl) and not control.is_stopped


def begin_task(kind: str, title: str) -> TaskControl:
    control = TaskControl()
    active_task["kind"] = kind
    active_task["title"] = title
    active_task["control"] = control
    active_task["last_progress"] = None
    return control


def clear_task() -> None:
    active_task["kind"] = None
    active_task["title"] = None
    active_task["control"] = None
    active_task["last_progress"] = None


def build_user_client(api_id: int, api_hash: str, session_value: str, proxy) -> TelegramClient:
    if session_value.startswith("1") or len(session_value) > 100:
        return TelegramClient(StringSession(session_value), api_id, api_hash, proxy=proxy)
    return TelegramClient(session_value, api_id, api_hash, proxy=proxy)


def result_summary(result: ArchiveResult) -> str:
    return (
        f"Archive finished\n"
        f"Title: {result.title}\n"
        f"Message ID: {result.message_id}\n"
        f"Main files: {len(result.main_files)}\n"
        f"Comment files: {len(result.comment_files)}\n"
        f"Folder: {result.folder}"
    )


def build_live_progress(info: dict) -> str:
    stage_map = {
        "main_start": "主消息资源",
        "main_done": "主消息资源完成",
        "comments_start": "评论区资源",
        "comments_done": "评论区资源完成",
        "downloading": "下载中",
    }
    stage = stage_map.get(info.get("stage"), info.get("stage", "working"))
    lines = [
        "归档中...",
        f"阶段：{stage}",
        f"标题：{info.get('title', '-')}",
        f"消息ID：{info.get('message_id', '-')}",
    ]
    if info.get("single"):
        lines.append("模式：single")
    if info.get("selected_comment_id") is not None:
        lines.append(f"评论ID：{info.get('selected_comment_id')}")
    if info.get("completed_files") is not None and info.get("total_files") is not None:
        lines.append(f"文件：{info.get('completed_files', 0)}/{info.get('total_files', 0)}")
    if info.get("percent") is not None:
        lines.append(f"进度：{info.get('percent', 0.0):.1f}%")
    if info.get("speed_bps") is not None:
        speed_kbps = info.get("speed_bps", 0.0) / 1024.0
        lines.append(f"速度：{speed_kbps:.1f} KB/s")
    if info.get("main_count") is not None:
        lines.append(f"主消息文件：{info.get('main_count')}")
    if info.get("comment_count") is not None:
        lines.append(f"评论文件：{info.get('comment_count')}")
    if info.get("folder"):
        lines.append(f"目录：{info.get('folder')}")
    return "\n".join(lines)


async def main() -> None:
    load_dotenv()

    api_id = int(os.environ["TG_API_ID"])
    api_hash = os.environ["TG_API_HASH"]
    bot_token = os.environ["TG_BOT_TOKEN"]
    user_session = os.environ["TG_USER_SESSION"]
    output_root = Path(os.environ.get("OUTPUT_DIR", "downloads")).resolve()
    include_comments = os.environ.get("INCLUDE_COMMENTS", "true").lower() != "false"
    default_limit = int(os.environ.get("DEFAULT_CHANNEL_LIMIT", "100"))
    max_download_workers = clamp_concurrency(int(os.environ.get("MAX_DOWNLOAD_WORKERS", "1")))
    download_dir_aliases = parse_download_dir_aliases(os.environ.get("DOWNLOAD_DIR_ALIASES", ""))
    default_download_alias = os.environ.get("DEFAULT_DOWNLOAD_ALIAS", "").strip()
    silent_download_mode = os.environ.get("SILENT_DOWNLOAD_MODE", "false").lower() == "true"
    proxy = get_proxy_from_env()

    output_root.mkdir(parents=True, exist_ok=True)
    download_options = DownloadOptions(max_concurrency=max_download_workers)

    user_client = build_user_client(api_id, api_hash, user_session, proxy)
    bot_client = TelegramClient("tg_archiver_bot", api_id, api_hash, proxy=proxy)

    await user_client.start()
    await bot_client.start(bot_token=bot_token)
    await sync_bot_commands(bot_client)

    def resolve_output_dir(alias_name: str | None = None) -> Path:
        if alias_name and alias_name in download_dir_aliases:
            return Path(download_dir_aliases[alias_name]).resolve()
        if default_download_alias and default_download_alias in download_dir_aliases:
            return Path(download_dir_aliases[default_download_alias]).resolve()
        return output_root

    async def run_message_task(status_message, link: str, output_dir: Path) -> None:
        task_control = begin_task("message", link.strip())
        try:
            async def progress(info: dict) -> None:
                active_task["last_progress"] = dict(info)
                await status_message.edit(build_live_progress(info))

            result = await archive_message_by_link(
                user_client,
                link.strip(),
                output_dir,
                include_comments=include_comments,
                progress_callback=progress,
                download_options=download_options,
                task_control=task_control,
            )
            if not result:
                await status_message.edit("这条消息没有可下载的媒体资源。")
                clear_task()
                return
            await status_message.edit(result_summary(result))
            clear_task()
        except ArchiveStoppedError as exc:
            await status_message.edit(str(exc))
            clear_task()
        except Exception as exc:
            await status_message.edit(f"Archive failed: {type(exc).__name__}: {exc}")
            clear_task()

    async def run_channel_task(status_message, link: str, limit: int | None, output_dir: Path, label: str) -> None:
        task_control = begin_task("channel", label)

        async def progress(info: dict) -> None:
            active_task["last_progress"] = dict(info)
            event_type = info.get("event")
            should_update = (
                event_type in {"failed", "skipped", "item_progress"}
                or info.get("archived", 0) % 5 == 0 and event_type == "archived"
            )
            if should_update:
                latest = info.get("title") or f"message {info.get('message_id')}"
                lines = [
                    "归档中...",
                    f"消息：{info.get('scanned', 0)}/{info.get('target_messages', '?') or 'full'}",
                    f"已扫描：{info.get('scanned', 0)}",
                    f"已归档：{info.get('archived', 0)}",
                    f"已跳过：{info.get('skipped', 0)}",
                    f"失败：{info.get('failed', 0)}",
                    f"主消息文件：{info.get('main_files', 0)}",
                    f"评论文件：{info.get('comment_files', 0)}",
                    f"当前：{latest}",
                ]
                if event_type == "item_progress":
                    lines.append(f"阶段：{info.get('stage', '-')}")
                    if info.get("completed_files") is not None and info.get("total_files") is not None:
                        lines.append(f"文件：{info.get('completed_files', 0)}/{info.get('total_files', 0)}")
                    if info.get("percent") is not None:
                        lines.append(f"进度：{info.get('percent', 0.0):.1f}%")
                    if info.get("speed_bps") is not None:
                        lines.append(f"速度：{info.get('speed_bps', 0.0) / 1024.0:.1f} KB/s")
                await status_message.edit("\n".join(lines))

        try:
            summary = await archive_channel(
                user_client,
                link,
                output_dir,
                limit=limit,
                include_comments=include_comments,
                progress_callback=progress,
                download_options=download_options,
                task_control=task_control,
            )
            failure_lines = ""
            if summary.failures:
                failure_preview = "\n".join(
                    f"- {item.message_id}: {item.error_type}"
                    for item in summary.failures[:5]
                )
                failure_lines = f"\nFailures:\n{failure_preview}"
            await status_message.edit(
                "频道归档完成\n"
                f"来源：{summary.source_chat}\n"
                f"消息：{summary.scanned_messages}/{summary.target_messages or 'full'}\n"
                f"已归档：{summary.archived_messages}\n"
                f"已跳过：{summary.skipped_messages}\n"
                f"失败：{summary.failed_messages}\n"
                f"主消息文件：{summary.main_files}\n"
                f"评论文件：{summary.comment_files}\n"
                f"输出目录：{output_dir}"
                f"{failure_lines}"
            )
            clear_task()
        except ArchiveStoppedError as exc:
            await status_message.edit(str(exc))
            clear_task()
        except Exception as exc:
            await status_message.edit(f"Channel archive failed: {type(exc).__name__}: {exc}")
            clear_task()

    @bot_client.on(events.NewMessage(pattern=r"^/start$"))
    async def handle_start(event):
        await event.reply(
            "命令：\n"
            "/channel <channel_link> [count]\n"
            "/message <message_link_or_comment_link>\n"
            "/pause\n"
            "/resume\n"
            "/stop\n"
            "主贴链接会下载主消息加评论区资源。\n"
            "评论链接会下载主消息加指定评论资源组。\n"
            "如果 /channel 不带数量，会弹出 full / 200 / 100 / 50 按钮供你选择。\n"
            "你也可以直接把频道消息转发给我，我会尝试抓原消息和评论区资源。"
        )

    @bot_client.on(events.NewMessage(pattern=r"^/pause$"))
    async def handle_pause(event):
        control = active_task.get("control")
        if not isinstance(control, TaskControl):
            await event.reply("当前没有任务。")
            return
        control.pause()
        await event.reply(f"已暂停：{active_task.get('title') or active_task.get('kind')}")

    @bot_client.on(events.NewMessage(pattern=r"^/resume$"))
    async def handle_resume(event):
        control = active_task.get("control")
        if not isinstance(control, TaskControl):
            await event.reply("当前没有任务。")
            return
        control.resume()
        last_progress = active_task.get("last_progress")
        if isinstance(last_progress, dict):
            await event.reply(build_live_progress(last_progress))
        else:
            await event.reply(f"已恢复：{active_task.get('title') or active_task.get('kind')}")

    @bot_client.on(events.NewMessage(pattern=r"^/stop$"))
    async def handle_stop(event):
        control = active_task.get("control")
        if not isinstance(control, TaskControl):
            await event.reply("当前没有任务。")
            return
        control.stop()
        await event.reply(f"正在停止：{active_task.get('title') or active_task.get('kind')}")

    @bot_client.on(events.NewMessage(pattern=r"^/(?:archive_message|message)(?:\s+(.+))?$"))
    async def handle_archive_message(event):
        link = event.pattern_match.group(1)
        if not link:
            await event.reply("请发送标准的 t.me 消息链接或评论链接。")
            return
        if current_task_running():
            await event.reply(
                f"当前已有任务在运行：{active_task.get('title') or active_task.get('kind')}。\n请先使用 /pause、/resume 或 /stop。"
            )
            return
        if silent_download_mode or not download_dir_aliases:
            target_dir = resolve_output_dir(None)
            target_dir.mkdir(parents=True, exist_ok=True)
            status = await event.reply(f"开始归档这条消息，输出目录：{target_dir}")
            await run_message_task(status, link.strip(), target_dir)
            return

        pending_download_choices[event.chat_id] = {
            "kind": "message",
            "payload": {"link": link.strip()},
            "created_at": time(),
        }
        await event.reply("请选择下载目录：", buttons=build_download_dir_buttons(download_dir_aliases))

    @bot_client.on(events.NewMessage(pattern=r"^/(?:archive_channel|channel)(?:\s+(.+))?$"))
    async def handle_archive_channel(event):
        raw_args = event.pattern_match.group(1)
        if not raw_args:
            await event.reply("用法：/channel <channel_link> [count]")
            return

        parts = raw_args.split()
        link = parts[0].strip()
        limit = default_limit
        if len(parts) == 1:
            channel_choices[event.chat_id] = {
                "link": link,
                "created_at": time(),
            }
            await event.reply(
                "请选择消息范围：",
                buttons=build_channel_choice_buttons(),
            )
            return
        if len(parts) > 1:
            try:
                limit = int(parts[1])
            except ValueError:
                await event.reply("数量必须是整数，例如：/channel https://t.me/xxx 200")
                return
        if current_task_running():
            await event.reply(
                f"当前已有任务在运行：{active_task.get('title') or active_task.get('kind')}。\n请先使用 /pause、/resume 或 /stop。"
            )
            return
        if silent_download_mode or not download_dir_aliases:
            target_dir = resolve_output_dir(None)
            target_dir.mkdir(parents=True, exist_ok=True)
            status = await event.reply(f"开始归档频道，准备扫描最新 {limit} 条消息。\n输出目录：{target_dir}")
            await run_channel_task(status, link, limit, target_dir, f"{link} ({'full' if limit is None else limit})")
            return

        pending_download_choices[event.chat_id] = {
            "kind": "channel",
            "payload": {"link": link, "limit": limit},
            "created_at": time(),
        }
        await event.reply("请选择下载目录：", buttons=build_download_dir_buttons(download_dir_aliases))

    @bot_client.on(events.CallbackQuery(pattern=rb"^channel:(full|200|100|50)$"))
    async def handle_channel_choice(event):
        choice = event.pattern_match.group(1).decode("utf-8").lower()
        chat_id = event.chat_id
        pending = channel_choices.get(chat_id)
        if not pending:
            await event.answer("当前没有待选择的频道任务。", alert=True)
            return
        if time() - pending.get("created_at", 0) > 600:
            channel_choices.pop(chat_id, None)
            await event.edit("待选择的频道任务已过期，请重新发送 /channel <link>。")
            return

        link = pending["link"]
        limit = None if choice == "full" else int(choice)
        channel_choices.pop(chat_id, None)
        if current_task_running():
            await event.answer("当前已有任务在运行。", alert=True)
            return
        await event.answer()
        if silent_download_mode or not download_dir_aliases:
            await event.edit(
                f"开始归档频道，准备扫描{'全部可用' if limit is None else f'最新 {limit}'}条消息。"
            )
            status = await event.get_message()
            target_dir = resolve_output_dir(None)
            target_dir.mkdir(parents=True, exist_ok=True)
            await run_channel_task(status, link, limit, target_dir, f"{link} ({choice})")
            return

        pending_download_choices[chat_id] = {
            "kind": "channel",
            "payload": {"link": link, "limit": limit},
            "created_at": time(),
        }
        await event.edit("请选择下载目录：", buttons=build_download_dir_buttons(download_dir_aliases))

    @bot_client.on(events.NewMessage(func=lambda e: bool(e.message.forward)))
    async def handle_forward(event):
        print("Received forwarded message:", describe_forward(event.message.forward))
        if current_task_running():
            await event.reply(
                f"当前已有任务在运行：{active_task.get('title') or active_task.get('kind')}。\n请先使用 /pause、/resume 或 /stop。"
            )
            return
        status = await event.reply("已收到转发消息，开始归档原消息和评论区资源。")
        task_control = begin_task("forward", "forwarded message")
        try:
            async def progress(info: dict) -> None:
                active_task["last_progress"] = dict(info)
                await status.edit(build_live_progress(info))

            result = await archive_forwarded_message(
                user_client,
                event.message.forward,
                output_root,
                include_comments=include_comments,
                progress_callback=progress,
                download_options=download_options,
                task_control=task_control,
            )
            if not result:
                await status.edit(
                    "这条转发消息没有暴露原频道来源信息，或者原消息没有可下载媒体。"
                )
                clear_task()
                return
            await status.edit(result_summary(result))
            clear_task()
        except ArchiveStoppedError as exc:
            await status.edit(str(exc))
            clear_task()
        except Exception as exc:
            await status.edit(f"Forward archive failed: {type(exc).__name__}: {exc}")
            clear_task()

    @bot_client.on(events.CallbackQuery(pattern=rb"^dir:(.+)$"))
    async def handle_download_dir_choice(event):
        alias_name = event.pattern_match.group(1).decode("utf-8")
        pending = pending_download_choices.get(event.chat_id)
        if not pending:
            await event.answer("当前没有待选择的下载任务。", alert=True)
            return
        if alias_name not in download_dir_aliases:
            await event.answer("目录别名不存在。", alert=True)
            return
        if current_task_running():
            await event.answer("当前已有任务在运行。", alert=True)
            return
        if time() - pending.get("created_at", 0) > 600:
            pending_download_choices.pop(event.chat_id, None)
            await event.edit("待选择的下载目录已过期，请重新发起任务。")
            return

        pending_download_choices.pop(event.chat_id, None)
        target_dir = resolve_output_dir(alias_name)
        target_dir.mkdir(parents=True, exist_ok=True)
        await event.answer()
        await event.edit(f"已选择下载目录：{alias_name}\n{target_dir}")
        status = await event.get_message()

        kind = pending["kind"]
        payload = pending["payload"]
        if kind == "message":
            await run_message_task(status, payload["link"], target_dir)
            return
        if kind == "channel":
            limit = payload["limit"]
            await run_channel_task(
                status,
                payload["link"],
                limit,
                target_dir,
                f"{payload['link']} ({'full' if limit is None else limit})",
            )
            return

    @bot_client.on(events.NewMessage(incoming=True))
    async def handle_fallback(event):
        text = event.raw_text or ""
        if text.startswith("/"):
            return
        if event.message.forward:
            return
        print(
            "Received non-forward message:",
            {
                "message_id": event.message.id,
                "chat_id": event.chat_id,
                "has_media": bool(event.message.media),
                "text_preview": text[:120],
            },
        )
        await event.reply(
            "我收到了你的消息，但 Telegram 没有把它暴露成带原始来源信息的标准转发。\n"
            "你可以这样做：\n"
            "1. 直接转发原频道主贴给我。\n"
            "2. 发送 /message <t.me 消息链接>。\n"
            "3. 发送 /channel <频道链接> [count]。"
        )

    print("Bot is running. Press Ctrl+C to stop.")
    await bot_client.run_until_disconnected()


if __name__ == "__main__":
    asyncio.run(main())
