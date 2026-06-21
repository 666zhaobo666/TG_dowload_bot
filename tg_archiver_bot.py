import asyncio
import os
from pathlib import Path
from time import time

from dotenv import load_dotenv
from telethon import Button, TelegramClient, events, functions, types
from telethon.errors import FloodWaitError
from telethon.sessions import StringSession

from archiver_core import (
    ArchiveResult,
    ArchiveStoppedError,
    archive_channel,
    archive_forwarded_message,
    archive_message_by_link,
    ChannelArchiveSummary,
    count_channel_message_groups,
    DownloadOptions,
    TaskControl,
    clamp_concurrency,
    describe_forward,
)
from proxy_config import get_proxy_from_env


channel_choices: dict[int, dict] = {}
pending_download_choices: dict[int, dict] = {}
pending_dir_add: dict[int, float] = {}
pending_channel_range: dict[int, dict] = {}
active_task: dict[str, object] = {
    "kind": None,
    "title": None,
    "control": None,
    "last_progress": None,
    "status_message": None,
    "progress_builder": None,
    "started_at": None,
    "display_task": None,
}

# 运行时可变配置：/dir、/silent 修改后直接更新这里，无需重启服务。
CFG: dict = {
    "download_dir_aliases": {},
    "default_download_alias": "",
    "silent_download_mode": False,
}


def build_channel_choice_buttons() -> list[list[Button]]:
    return [
        [Button.inline("全部", b"channel:full")],
        [Button.inline("🔢 自定义范围", b"channel:custom")],
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


def get_env_path() -> Path:
    return Path(__file__).parent / ".env"


def _strip_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def set_env_var(key: str, value: str) -> None:
    env_path = get_env_path()
    lines_env: list[str] = []
    found = False
    if env_path.exists():
        lines_env = env_path.read_text(encoding="utf-8").splitlines()
    new_lines_out: list[str] = []
    for line in lines_env:
        if line.startswith(key + "="):
            # 用单引号包裹，避免路径中含空格 / # / = 等字符被解析器误读。
            new_lines_out.append(key + "='" + value + "'")
            found = True
        else:
            new_lines_out.append(line)
    if not found:
        new_lines_out.append(key + "='" + value + "'")
    env_path.write_text("\n".join(new_lines_out) + "\n", encoding="utf-8")


def get_env_var(key: str, default: str = "") -> str:
    env_path = get_env_path()
    if not env_path.exists():
        return default
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith(key + "="):
            return _strip_quotes(line.split("=", 1)[1])
    return default


def reload_dir_config() -> None:
    """从 .env 重新读取下载目录相关配置到 CFG（修改后即时生效，无需重启服务）。"""
    CFG["download_dir_aliases"] = parse_download_dir_aliases(
        get_env_var("DOWNLOAD_DIR_ALIASES", "")
    )
    CFG["default_download_alias"] = get_env_var("DEFAULT_DOWNLOAD_ALIAS", "").strip()
    CFG["silent_download_mode"] = (
        get_env_var("SILENT_DOWNLOAD_MODE", "false").strip().lower() == "true"
    )


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


def build_dir_menu_buttons() -> list[list[Button]]:
    return [
        [Button.inline("➕ 添加目录", b"dirm:add"), Button.inline("🗑️ 删除目录", b"dirm:del")],
        [Button.inline("📋 查看列表", b"dirm:list")],
    ]


def build_dir_del_buttons(aliases: dict[str, str]) -> list[list[Button]]:
    rows: list[list[Button]] = []
    row: list[Button] = []
    for name in aliases:
        row.append(Button.inline(f"🗑️ {name}", f"dirm:rm:{name}".encode("utf-8")))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append([Button.inline("⬅️ 返回", b"dirm:back")])
    return rows


def build_silent_buttons(current_on: bool) -> list[list[Button]]:
    on_label = "✅ 开启" + ("（当前）" if current_on else "")
    off_label = "❌ 关闭" + ("（当前）" if not current_on else "")
    return [[Button.inline(on_label, b"silent:on"), Button.inline(off_label, b"silent:off")]]


def build_silent_dir_buttons(aliases: dict[str, str]) -> list[list[Button]]:
    rows: list[list[Button]] = []
    row: list[Button] = []
    for name in aliases:
        row.append(Button.inline(name, f"sdir:{name}".encode("utf-8")))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append([Button.inline("⬅️ 返回", b"silent:back")])
    return rows


def _dir_menu_text(aliases: dict[str, str]) -> str:
    lines = ["📂 下载目录管理", ""]
    if not aliases:
        lines.append("当前未配置任何下载目录。")
        lines.append("点击「➕ 添加目录」按钮进行添加。")
    else:
        lines.append("当前目录：")
        for name, path_alias in aliases.items():
            mark = " ⭐" if name == CFG.get("default_download_alias") else ""
            lines.append(f"  • {name} → {path_alias}{mark}")
    lines.append("")
    lines.append("点击下方按钮进行管理：")
    return "\n".join(lines)


async def sync_bot_commands(bot_client: TelegramClient) -> None:
    await bot_client(
        functions.bots.SetBotCommandsRequest(
            scope=types.BotCommandScopeDefault(),
            lang_code="zh",
            commands=[
                types.BotCommand(command="start", description="显示帮助"),
                types.BotCommand(command="message", description="下载消息或评论链接"),
                types.BotCommand(command="channel", description="下载频道消息"),
                types.BotCommand(command="dir", description="下载目录管理"),
                types.BotCommand(command="silent", description="静默下载模式"),
                types.BotCommand(command="pause", description="暂停当前任务"),
                types.BotCommand(command="resume", description="恢复当前任务"),
                types.BotCommand(command="stop", description="停止当前任务"),
            ],
        )
    )


def current_task_running() -> bool:
    control = active_task.get("control")
    return isinstance(control, TaskControl) and not control.is_stopped


def begin_task(kind: str, title: str, status_message, progress_builder) -> TaskControl:
    control = TaskControl()
    active_task["kind"] = kind
    active_task["title"] = title
    active_task["control"] = control
    active_task["last_progress"] = None
    active_task["status_message"] = status_message
    active_task["progress_builder"] = progress_builder
    active_task["started_at"] = time()
    old = active_task.get("display_task")
    if old and not old.done():
        old.cancel()
    active_task["display_task"] = asyncio.create_task(_progress_display_loop())
    return control


def clear_task() -> None:
    dt = active_task.get("display_task")
    if dt and not dt.done():
        dt.cancel()
    active_task["kind"] = None
    active_task["title"] = None
    active_task["control"] = None
    active_task["last_progress"] = None
    active_task["status_message"] = None
    active_task["progress_builder"] = None
    active_task["started_at"] = None
    active_task["display_task"] = None


async def _progress_display_loop() -> None:
    """独立于下载的进度刷新循环：把进度编辑与下载解耦，避免高频编辑触发 FloodWait
    后异常向上传播导致进度刷新中断。频率：开始 1 分钟内 2 秒一次，之后 5 秒一次。
    """
    try:
        last_text: str | None = None
        while True:
            started = active_task.get("started_at")
            if not started:
                break
            elapsed = time() - started
            interval = 2.0 if elapsed < 60.0 else 5.0
            await asyncio.sleep(interval)

            msg = active_task.get("status_message")
            builder = active_task.get("progress_builder")
            info = active_task.get("last_progress")
            if msg is None or builder is None or info is None:
                continue
            try:
                text = builder(dict(info))
            except Exception:
                continue

            now_elapsed = int(time() - (active_task.get("started_at") or time()))
            control = active_task.get("control")
            if isinstance(control, TaskControl) and control.is_paused:
                text += f"\n⏸ 已暂停  ⏱ 已运行 {now_elapsed // 60}m{now_elapsed % 60}s"
            else:
                text += f"\n⏱ 已运行 {now_elapsed // 60}m{now_elapsed % 60}s"

            if text == last_text:
                continue
            last_text = text
            try:
                await msg.edit(text)
            except FloodWaitError as exc:
                last_text = None
                await asyncio.sleep(exc.seconds + 1)
            except Exception:
                # 编辑失败（如 MessageNotModifiedError / 网络抖动）绝不能中断下载。
                pass
    except asyncio.CancelledError:
        pass


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


def build_channel_progress(info: dict) -> str:
    latest = info.get("title") or f"message {info.get('message_id')}"
    lines = [
        "归档中...",
        f"Message group：{info.get('scanned', 0)}/{info.get('target_messages', '?') or 'full'}",
        f"已扫描 group：{info.get('scanned', 0)}",
        f"已归档：{info.get('archived', 0)}",
        f"已跳过：{info.get('skipped', 0)}",
        f"失败：{info.get('failed', 0)}",
        f"主消息文件：{info.get('main_files', 0)}",
        f"评论文件：{info.get('comment_files', 0)}",
        f"当前：{latest}",
    ]
    event_type = info.get("event")
    if event_type == "item_progress":
        lines.append(f"阶段：{info.get('stage', '-')}")
        if info.get("completed_files") is not None and info.get("total_files") is not None:
            lines.append(f"文件：{info.get('completed_files', 0)}/{info.get('total_files', 0)}")
        if info.get("percent") is not None:
            lines.append(f"进度：{info.get('percent', 0.0):.1f}%")
        if info.get("speed_bps") is not None:
            lines.append(f"速度：{info.get('speed_bps', 0.0) / 1024.0:.1f} KB/s")
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
    reload_dir_config()
    proxy = get_proxy_from_env()

    output_root.mkdir(parents=True, exist_ok=True)
    download_options = DownloadOptions(max_concurrency=max_download_workers)

    user_client = build_user_client(api_id, api_hash, user_session, proxy)
    bot_client = TelegramClient("tg_archiver_bot", api_id, api_hash, proxy=proxy)

    await user_client.start()
    await bot_client.start(bot_token=bot_token)
    await sync_bot_commands(bot_client)

    def resolve_output_dir(alias_name: str | None = None) -> Path:
        aliases = CFG["download_dir_aliases"]
        if alias_name and alias_name in aliases:
            return Path(aliases[alias_name]).resolve()
        default_alias = CFG["default_download_alias"]
        if default_alias and default_alias in aliases:
            return Path(aliases[default_alias]).resolve()
        return output_root

    async def run_message_task(status_message, link: str, output_dir: Path) -> None:
        task_control = begin_task("message", link.strip(), status_message, build_live_progress)
        try:
            async def progress(info: dict) -> None:
                active_task["last_progress"] = dict(info)

            result = await archive_message_by_link(
                user_client,
                link.strip(),
                output_dir,
                include_comments=include_comments,
                progress_callback=progress,
                download_options=download_options,
                task_control=task_control,
            )
            clear_task()
            if not result:
                await status_message.edit("这条消息没有可下载的媒体资源。")
                return
            await status_message.edit(result_summary(result))
        except ArchiveStoppedError as exc:
            clear_task()
            await status_message.edit(str(exc))
        except Exception as exc:
            clear_task()
            await status_message.edit(f"Archive failed: {type(exc).__name__}: {exc}")

    async def run_channel_task(status_message, link: str, limit: int | None, output_dir: Path, label: str, offset: int = 0, range_mode: bool = False) -> None:
        task_control = begin_task("channel", label, status_message, build_channel_progress)
        try:
            async def progress(info: dict) -> None:
                active_task["last_progress"] = dict(info)

            summary = await archive_channel(
                user_client,
                link,
                output_dir,
                limit=limit,
                include_comments=include_comments,
                progress_callback=progress,
                download_options=download_options,
                task_control=task_control,
                offset=offset,
                range_mode=range_mode,
            )
            failure_lines = ""
            if summary.failures:
                failure_preview = "\n".join(
                    f"- {item.message_id}: {item.error_type}"
                    for item in summary.failures[:5]
                )
                failure_lines = f"\nFailures:\n{failure_preview}"
            clear_task()
            await status_message.edit(
                "频道归档完成\n"
                f"来源：{summary.source_chat}\n"
                f"Message group：{summary.scanned_messages}/{summary.target_messages or 'full'}\n"
                f"已归档：{summary.archived_messages}\n"
                f"已跳过：{summary.skipped_messages}\n"
                f"失败：{summary.failed_messages}\n"
                f"主消息文件：{summary.main_files}\n"
                f"评论文件：{summary.comment_files}\n"
                f"输出目录：{output_dir}"
                f"{failure_lines}"
            )
        except ArchiveStoppedError as exc:
            clear_task()
            await status_message.edit(str(exc))
        except Exception as exc:
            clear_task()
            await status_message.edit(f"Channel archive failed: {type(exc).__name__}: {exc}")

    @bot_client.on(events.NewMessage(pattern=r"^/start$"))
    async def handle_start(event):
        await event.reply(
            "命令：\n"
            "/channel <频道链接> [数量] - 下载频道消息\n"
            "/message <消息链接或评论链接> - 下载消息\n"
            "/dir - 下载目录管理（按钮操作）\n"
            "/silent - 静默下载模式（按钮操作，开启时选择下载目录）\n"
            "/pause - 暂停任务\n"
            "/resume - 恢复任务\n"
            "/stop - 停止任务\n"
            "\n"
            "主贴链接会下载主消息加评论区资源。\n"
            "评论链接会下载主消息加指定评论资源组。\n"
            "如果 /channel 不带数量，会弹出 full / 200 / 100 / 50 按钮供你选择。\n"
            "你也可以直接把频道消息转发给我，我会尝试抓原消息和评论区资源。"
        )

    @bot_client.on(events.NewMessage(pattern=r"^/dir(?:\s+(.*))?$"))
    async def handle_dir(event):
        raw = event.pattern_match.group(1) or ""
        parts = raw.strip().split(maxsplit=1)
        op = parts[0] if parts else ""
        rest = parts[1] if len(parts) > 1 else ""

        reload_dir_config()
        aliases = CFG["download_dir_aliases"]

        # 无参数：弹出按钮菜单
        if op == "":
            await event.reply(_dir_menu_text(aliases), buttons=build_dir_menu_buttons())
            return

        # 文本子命令（按钮的等价快捷方式，同样有反馈）
        if op == "list":
            await event.reply(_dir_menu_text(aliases))
            return

        if op == "add":
            if " " not in rest or not rest.strip():
                await event.reply("用法：/dir add <别名> <绝对路径>\n示例：/dir add disk1 /mnt/disk1/downloads")
                return
            alias_name, alias_path = rest.split(" ", 1)
            alias_name = alias_name.strip()
            alias_path = alias_path.strip()
            if not alias_name or not alias_path:
                await event.reply("别名和路径都不能为空")
                return
            if not alias_path.startswith("/"):
                await event.reply("路径必须是绝对路径（以 / 开头）")
                return
            existed = alias_name in aliases
            aliases[alias_name] = alias_path
            combined = ";".join(k + "=" + v for k, v in aliases.items())
            set_env_var("DOWNLOAD_DIR_ALIASES", combined)
            reload_dir_config()
            action = "已更新" if existed else "已添加"
            await event.reply("✅ " + action + "下载目录：" + alias_name + " -> " + alias_path)
            return

        if op == "del":
            name = rest.strip()
            if not name:
                await event.reply("用法：/dir del <别名>")
                return
            if name not in aliases:
                await event.reply("别名 " + name + " 不存在")
                return
            del aliases[name]
            combined = ";".join(k + "=" + v for k, v in aliases.items()) if aliases else ""
            set_env_var("DOWNLOAD_DIR_ALIASES", combined)
            if CFG["default_download_alias"] == name:
                set_env_var("DEFAULT_DOWNLOAD_ALIAS", "")
            reload_dir_config()
            await event.reply("✅ 已删除下载目录：" + name)
            return

        await event.reply("未知操作，可用：/dir add | del | list")

    @bot_client.on(events.NewMessage(pattern=r"^/silent(?:\s+(.*))?$"))
    async def handle_silent(event):
        reload_dir_config()
        current_on = CFG["silent_download_mode"]
        raw = (event.pattern_match.group(1) or "").strip().lower()

        if raw in ("on", "off"):
            if raw == "off":
                set_env_var("SILENT_DOWNLOAD_MODE", "false")
                reload_dir_config()
                await event.reply("❌ 静默模式已关闭。")
                return
            # on：进入目录选择
            aliases = CFG["download_dir_aliases"]
            if not aliases:
                await event.reply("暂未配置任何下载目录。\n请先发送 /dir 添加下载目录，再开启静默模式。")
                return
            await event.reply("请选择静默模式使用的下载目录：", buttons=build_silent_dir_buttons(aliases))
            return

        # 无参数：按钮菜单
        status = "✅ 开启" if current_on else "❌ 关闭"
        text = (
            "🔇 静默下载模式\n\n"
            f"当前状态：{status}\n\n"
            "开启后会使用所选下载目录，下载时不再逐次询问目录。\n"
            "点击下方按钮切换："
        )
        await event.reply(text, buttons=build_silent_buttons(current_on))

    @bot_client.on(events.NewMessage(pattern=r"^/default(?:\s+(.*))?$"))
    async def handle_default(event):
        raw = event.pattern_match.group(1) or ""
        reload_dir_config()
        aliases = CFG["download_dir_aliases"]
        current = CFG["default_download_alias"]

        if not raw.strip():
            if current and current in aliases:
                await event.reply("当前静默下载目录：" + current + " -> " + aliases[current])
            else:
                await event.reply("当前未设置静默下载目录。使用 /silent 开启时选择即可。")
            return

        name = raw.strip()
        if name not in aliases:
            available = ", ".join(aliases.keys()) if aliases else "（无）"
            await event.reply("别名 " + name + " 不存在，可用别名：" + available)
            return
        set_env_var("DEFAULT_DOWNLOAD_ALIAS", name)
        reload_dir_config()
        await event.reply("✅ 静默下载目录已设为：" + name + " -> " + aliases[name])

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
            builder = active_task.get("progress_builder") or build_live_progress
            await event.reply(builder(last_progress))
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
        reload_dir_config()
        if CFG["silent_download_mode"] or not CFG["download_dir_aliases"]:
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
        await event.reply("请选择下载目录：", buttons=build_download_dir_buttons(CFG["download_dir_aliases"]))

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
        reload_dir_config()
        if CFG["silent_download_mode"] or not CFG["download_dir_aliases"]:
            target_dir = resolve_output_dir(None)
            target_dir.mkdir(parents=True, exist_ok=True)
            status = await event.reply(f"开始归档频道，准备扫描最新 {limit} 个 message group。\n输出目录：{target_dir}")
            await run_channel_task(status, link, limit, target_dir, f"{link} ({limit})")
            return

        pending_download_choices[event.chat_id] = {
            "kind": "channel",
            "payload": {"link": link, "limit": limit},
            "created_at": time(),
        }
        await event.reply("请选择下载目录：", buttons=build_download_dir_buttons(CFG["download_dir_aliases"]))

    @bot_client.on(events.CallbackQuery(pattern=rb"^channel:(full|custom)$"))
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
        if choice == "custom":
            # 自定义输入：支持两种格式。
            #   单数字 N：下载最新 N 个 message group（从新到旧）。
            #   区间 A B：从旧到新，1=频道第一个 message group（最旧），下载第 A~B 个 group。
            try:
                range_entity = await user_client.get_entity(link)
                range_total = await count_channel_message_groups(user_client, range_entity)
            except Exception:
                range_total = None
            if isinstance(range_total, int) and range_total > 0:
                total_str = str(range_total)
                hint = (
                    f"📊 该频道共 {total_str} 个 message group。\n\n"
                    "请发送数字，两种格式：\n\n"
                    "📌 区间（两个数字，从旧到新）：\n"
                    f"  序号 1 = 第一个 message group（最旧），{total_str} = 最新一个\n"
                    f"  例如：1 5   → 下载第 1~5 个 group\n"
                    f"  例如：50 150 → 下载第 50~150 个 group\n"
                    f"  最大序号 {total_str}\n\n"
                    "📌 单数字（最新 N 个 group）：\n"
                    "  例如：7   → 下载最新 7 个 group"
                )
            else:
                hint = (
                    "📊 无法获取频道 message group 总数。\n\n"
                    "请发送数字：\n"
                    "  区间（两个数字）：1 5 → 从旧到新下载第 1~5 个 group\n"
                    "  单数字：7 → 下载最新 7 个 group\n"
                    "（区间序号 1 = 频道第一个 group / 最旧）"
                )
            channel_choices.pop(chat_id, None)
            pending_channel_range[chat_id] = {"link": link, "created_at": time(), "total": range_total}
            await event.answer()
            await event.edit(hint)
            return
        limit = None if choice == "full" else int(choice)
        channel_choices.pop(chat_id, None)
        if current_task_running():
            await event.answer("当前已有任务在运行。", alert=True)
            return
        await event.answer()
        reload_dir_config()
        if CFG["silent_download_mode"] or not CFG["download_dir_aliases"]:
            await event.edit(
                f"开始归档频道，准备扫描{'全部可用' if limit is None else f'最新 {limit} 个 message group'}。"
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
        await event.edit("请选择下载目录：", buttons=build_download_dir_buttons(CFG["download_dir_aliases"]))

    @bot_client.on(events.NewMessage(func=lambda e: bool(e.message.forward)))
    async def handle_forward(event):
        print("Received forwarded message:", describe_forward(event.message.forward))
        if current_task_running():
            await event.reply(
                f"当前已有任务在运行：{active_task.get('title') or active_task.get('kind')}。\n请先使用 /pause、/resume 或 /stop。"
            )
            return
        reload_dir_config()
        if CFG["silent_download_mode"] or not CFG["download_dir_aliases"]:
            target_dir = resolve_output_dir(None)
        else:
            target_dir = output_root
        target_dir.mkdir(parents=True, exist_ok=True)
        status = await event.reply(f"已收到转发消息，开始归档原消息和评论区资源。\n输出目录：{target_dir}")
        task_control = begin_task("forward", "forwarded message", status, build_live_progress)
        try:
            async def progress(info: dict) -> None:
                active_task["last_progress"] = dict(info)

            result = await archive_forwarded_message(
                user_client,
                event.message.forward,
                target_dir,
                include_comments=include_comments,
                progress_callback=progress,
                download_options=download_options,
                task_control=task_control,
            )
            clear_task()
            if not result:
                await status.edit(
                    "这条转发消息没有暴露原频道来源信息，或者原消息没有可下载媒体。"
                )
                return
            await status.edit(result_summary(result))
        except ArchiveStoppedError as exc:
            clear_task()
            await status.edit(str(exc))
        except Exception as exc:
            clear_task()
            await status.edit(f"Forward archive failed: {type(exc).__name__}: {exc}")

    @bot_client.on(events.CallbackQuery(pattern=rb"^dir:(.+)$"))
    async def handle_download_dir_choice(event):
        alias_name = event.pattern_match.group(1).decode("utf-8")
        pending = pending_download_choices.get(event.chat_id)
        if not pending:
            await event.answer("当前没有待选择的下载任务。", alert=True)
            return
        reload_dir_config()
        if alias_name not in CFG["download_dir_aliases"]:
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
            limit = payload.get("limit")
            ch_offset = payload.get("offset", 0)
            ch_range_mode = payload.get("range_mode", False)
            if ch_range_mode and limit is not None:
                ch_label = f"{payload['link']} (序号 {ch_offset + 1}-{ch_offset + limit})"
            else:
                ch_label = f"{payload['link']} ({'full' if limit is None else limit})"
            await run_channel_task(
                status,
                payload["link"],
                limit,
                target_dir,
                ch_label,
                offset=ch_offset,
                range_mode=ch_range_mode,
            )
            return

    # ----- /dir 按钮回调 -----
    @bot_client.on(events.CallbackQuery(pattern=rb"^dirm:(add|del|list|back)$"))
    async def handle_dirm_menu(event):
        action = event.pattern_match.group(1).decode("utf-8")
        reload_dir_config()
        aliases = CFG["download_dir_aliases"]
        await event.answer()
        if action == "add":
            pending_dir_add[event.chat_id] = time()
            await event.edit(
                "➕ 添加下载目录\n\n"
                "请直接发送：\n"
                "别名 路径\n\n"
                "例如：disk1 /mnt/disk1/downloads\n"
                "（路径须为绝对路径，以 / 开头）"
            )
            return
        if action == "del":
            if not aliases:
                await event.edit("暂无下载目录可删除。", buttons=build_dir_menu_buttons())
                return
            await event.edit("🗑️ 点击要删除的目录：", buttons=build_dir_del_buttons(aliases))
            return
        if action == "list":
            await event.edit(_dir_menu_text(aliases), buttons=[Button.inline("⬅️ 返回", b"dirm:back")])
            return
        if action == "back":
            await event.edit(_dir_menu_text(aliases), buttons=build_dir_menu_buttons())
            return

    @bot_client.on(events.CallbackQuery(pattern=rb"^dirm:rm:(.+)$"))
    async def handle_dirm_rm(event):
        name = event.pattern_match.group(1).decode("utf-8")
        reload_dir_config()
        aliases = CFG["download_dir_aliases"]
        if name not in aliases:
            await event.answer("该目录已不存在。", alert=True)
            return
        del aliases[name]
        combined = ";".join(f"{k}={v}" for k, v in aliases.items())
        set_env_var("DOWNLOAD_DIR_ALIASES", combined)
        if CFG["default_download_alias"] == name:
            set_env_var("DEFAULT_DOWNLOAD_ALIAS", "")
        reload_dir_config()
        await event.answer(f"已删除 {name}")
        await event.edit(_dir_menu_text(CFG["download_dir_aliases"]), buttons=build_dir_menu_buttons())

    # ----- /silent 按钮回调 -----
    @bot_client.on(events.CallbackQuery(pattern=rb"^silent:(on|off|back)$"))
    async def handle_silent_cb(event):
        action = event.pattern_match.group(1).decode("utf-8")
        reload_dir_config()
        if action == "off":
            set_env_var("SILENT_DOWNLOAD_MODE", "false")
            reload_dir_config()
            await event.answer()
            await event.edit(
                "🔇 静默下载模式\n\n当前状态：❌ 关闭\n\n下载时将逐次询问下载目录。",
                buttons=build_silent_buttons(False),
            )
            return
        if action == "back":
            current_on = CFG["silent_download_mode"]
            status = "✅ 开启" if current_on else "❌ 关闭"
            await event.answer()
            await event.edit(
                "🔇 静默下载模式\n\n"
                f"当前状态：{status}\n\n"
                "开启后会使用所选下载目录，下载时不再逐次询问目录。\n"
                "点击下方按钮切换：",
                buttons=build_silent_buttons(current_on),
            )
            return
        # action == "on"：进入目录选择
        aliases = CFG["download_dir_aliases"]
        if not aliases:
            await event.answer()
            await event.edit(
                "暂未配置任何下载目录。\n请先发送 /dir 添加下载目录，再开启静默模式。",
                buttons=[Button.inline("⬅️ 返回", b"silent:back")],
            )
            return
        await event.answer()
        await event.edit("请选择静默模式使用的下载目录：", buttons=build_silent_dir_buttons(aliases))

    @bot_client.on(events.CallbackQuery(pattern=rb"^sdir:(.+)$"))
    async def handle_silent_dir(event):
        name = event.pattern_match.group(1).decode("utf-8")
        reload_dir_config()
        aliases = CFG["download_dir_aliases"]
        if name not in aliases:
            await event.answer("该目录已不存在。", alert=True)
            return
        set_env_var("SILENT_DOWNLOAD_MODE", "true")
        set_env_var("DEFAULT_DOWNLOAD_ALIAS", name)
        reload_dir_config()
        await event.answer()
        await event.edit(
            "✅ 静默模式已开启\n"
            f"下载目录：{name} → {aliases[name]}\n\n"
            "下载时将不再询问目录，直接下载到此处。"
        )

    @bot_client.on(events.NewMessage(incoming=True))
    async def handle_fallback(event):
        text = event.raw_text or ""

        # 拦截「频道自定义」的文本输入。两种格式：
        #   单数字 N：最新 N 个 message group（从新到旧，range_mode=False）。
        #   区间 A B：从旧到新，1=频道第一个 message group（最旧），第 A~B 个 group（range_mode=True）。
        range_pending = pending_channel_range.get(event.chat_id)
        if range_pending is not None:
            pending_channel_range.pop(event.chat_id, None)
            if time() - range_pending.get("created_at", 0) > 600:
                await event.reply("自定义输入已超时，请重新选择「自定义范围」。")
                return
            if text.startswith("/"):
                await event.reply("已取消自定义范围。")
                return
            parts = text.strip().split()
            range_link = range_pending["link"]
            range_total = range_pending.get("total")
            if current_task_running():
                await event.reply("当前已有任务在运行，请先停止或等待完成。")
                return
            reload_dir_config()
            if len(parts) == 1:
                # 单数字：最新 N 个 message group
                try:
                    single_n = int(parts[0])
                except ValueError:
                    await event.reply("请输入有效的整数，例如：7 或 1 5")
                    return
                if single_n < 1:
                    await event.reply("数量必须为正整数。")
                    return
                if isinstance(range_total, int) and range_total > 0 and single_n > range_total:
                    single_n = range_total
                range_label = f"{range_link} (最新 {single_n} 个 group)"
                if CFG["silent_download_mode"] or not CFG["download_dir_aliases"]:
                    target_dir = resolve_output_dir(None)
                    target_dir.mkdir(parents=True, exist_ok=True)
                    status = await event.reply(f"开始归档频道，最新 {single_n} 个 message group。\n输出目录：{target_dir}")
                    await run_channel_task(status, range_link, single_n, target_dir, range_label)
                else:
                    pending_download_choices[event.chat_id] = {
                        "kind": "channel",
                        "payload": {"link": range_link, "limit": single_n, "offset": 0, "range_mode": False},
                        "created_at": time(),
                    }
                    await event.reply("请选择下载目录：", buttons=build_download_dir_buttons(CFG["download_dir_aliases"]))
                return
            if len(parts) == 2:
                # 区间：从旧到新，1=频道第一个 message group（最旧）
                try:
                    start_seq = int(parts[0])
                    end_seq = int(parts[1])
                except ValueError:
                    await event.reply("请输入有效的整数，例如：1 5 或 7")
                    return
                if start_seq < 1 or end_seq < 1 or start_seq > end_seq:
                    await event.reply("区间无效：起始和结束须为正整数且 起始 ≤ 结束。")
                    return
                if isinstance(range_total, int) and range_total > 0 and end_seq > range_total:
                    await event.reply(f"结束序号 {end_seq} 超过频道总 message group 数 {range_total}，请重新输入。")
                    return
                # 序号 -> offset/limit：从旧到新迭代（reverse=True），offset=start_seq-1
                # 跳过最旧的前若干个 group，limit=end_seq-start_seq+1 取该区间。
                range_offset = start_seq - 1
                range_limit = end_seq - start_seq + 1
                range_label = f"{range_link} (序号 {start_seq}-{end_seq})"
                if CFG["silent_download_mode"] or not CFG["download_dir_aliases"]:
                    target_dir = resolve_output_dir(None)
                    target_dir.mkdir(parents=True, exist_ok=True)
                    status = await event.reply(f"开始归档频道，序号 {start_seq}-{end_seq}（共 {range_limit} 个 message group，从旧到新）。\n输出目录：{target_dir}")
                    await run_channel_task(status, range_link, range_limit, target_dir, range_label, offset=range_offset, range_mode=True)
                else:
                    pending_download_choices[event.chat_id] = {
                        "kind": "channel",
                        "payload": {"link": range_link, "limit": range_limit, "offset": range_offset, "range_mode": True},
                        "created_at": time(),
                    }
                    await event.reply("请选择下载目录：", buttons=build_download_dir_buttons(CFG["download_dir_aliases"]))
                return
            await event.reply("格式不对，请发送一个数字（如 7）或两个数字（如 1 5）。")
            return

        # 拦截「添加下载目录」的文本输入
        created = pending_dir_add.get(event.chat_id)
        if created is not None:
            pending_dir_add.pop(event.chat_id, None)
            if time() - created > 300:
                await event.reply("添加操作已超时，请重新点击「➕ 添加目录」。")
                return
            if text.startswith("/"):
                await event.reply("已取消添加目录。")
                return
            await _do_dir_add(event, text)
            return

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


async def _do_dir_add(event, text: str) -> None:
    parts = text.strip().split(maxsplit=1)
    if len(parts) < 2 or not parts[0] or not parts[1]:
        await event.reply("格式不对，请发送：别名 路径\n例如：disk1 /mnt/disk1/downloads")
        return
    alias_name = parts[0].strip()
    alias_path = parts[1].strip()
    if not alias_path.startswith("/"):
        await event.reply("路径必须是绝对路径（以 / 开头）。")
        return
    reload_dir_config()
    aliases = CFG["download_dir_aliases"]
    existed = alias_name in aliases
    aliases[alias_name] = alias_path
    combined = ";".join(f"{k}={v}" for k, v in aliases.items())
    set_env_var("DOWNLOAD_DIR_ALIASES", combined)
    reload_dir_config()
    action = "已更新" if existed else "已添加"
    await event.reply("✅ " + action + "下载目录：" + alias_name + " -> " + alias_path)


if __name__ == "__main__":
    asyncio.run(main())
