import asyncio
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import parse_qs, urlparse

from telethon import TelegramClient, functions
from telethon.errors import FileReferenceExpiredError, MsgIdInvalidError
from telethon.tl.custom.forward import Forward
from telethon.tl.types import Message


INVALID_FS_CHARS = r'[<>:"/\\|?*\x00-\x1F]'
MAX_FOLDER_NAME = 80
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?。！？])\s*|\n+")
MESSAGE_LINK_RE = re.compile(
    r"https?://t\.me/(?:(?P<username>[A-Za-z0-9_]+)/(?P<msg_id>\d+)|c/(?P<chat_id>\d+)/(?P<private_msg_id>\d+))/?"
)


@dataclass
class ArchiveResult:
    folder: Path
    source_chat: str
    message_id: int
    title: str
    main_files: list[str]
    comment_files: list[str]
    comment_notes: list[str]


@dataclass
class ArchiveFailure:
    message_id: int
    error_type: str
    error_message: str


@dataclass
class ChannelArchiveSummary:
    source_chat: str
    target_messages: int | None
    scanned_messages: int
    archived_messages: int
    skipped_messages: int
    failed_messages: int
    main_files: int
    comment_files: int
    results: list[ArchiveResult]
    failures: list[ArchiveFailure]


@dataclass
class ParsedMessageLink:
    chat_ref: str | int
    message_id: int
    comment_id: int | None = None
    single: bool = False


@dataclass
class DownloadOptions:
    max_concurrency: int = 1


class ArchiveStoppedError(Exception):
    pass


class TaskControl:
    def __init__(self) -> None:
        self._pause_event = asyncio.Event()
        self._pause_event.set()
        self._stop_requested = False

    def pause(self) -> None:
        self._pause_event.clear()

    def resume(self) -> None:
        self._pause_event.set()

    def stop(self) -> None:
        self._stop_requested = True
        self._pause_event.set()

    @property
    def is_paused(self) -> bool:
        return not self._pause_event.is_set()

    @property
    def is_stopped(self) -> bool:
        return self._stop_requested

    async def checkpoint(self) -> None:
        await self._pause_event.wait()
        if self._stop_requested:
            raise ArchiveStoppedError("The current archive task was stopped by user command.")


class DownloadProgressTracker:
    def __init__(self, progress_callback, base_info: dict, total_bytes: int):
        self.progress_callback = progress_callback
        self.base_info = dict(base_info)
        self.total_bytes = max(0, total_bytes)
        self.start_time = time.monotonic()
        self.last_emit = 0.0
        self.completed_bytes = 0
        self.active_bytes: dict[str, int] = {}
        self.total_files = 0
        self.completed_files = 0
        self.lock = asyncio.Lock()

    async def update_file(self, file_key: str, current: int) -> None:
        if not self.progress_callback:
            return
        async with self.lock:
            self.active_bytes[file_key] = max(0, current)
            await self._emit_locked(force=False)

    async def finish_file(self, file_key: str, file_size: int) -> None:
        if not self.progress_callback:
            return
        async with self.lock:
            self.active_bytes.pop(file_key, None)
            self.completed_bytes += max(0, file_size)
            self.completed_files += 1
            await self._emit_locked(force=True)

    async def add_total_bytes(self, extra_bytes: int) -> None:
        if not self.progress_callback:
            return
        async with self.lock:
            self.total_bytes += max(0, extra_bytes)
            await self._emit_locked(force=True)

    async def add_total_files(self, extra_files: int) -> None:
        if not self.progress_callback:
            return
        async with self.lock:
            self.total_files += max(0, extra_files)
            await self._emit_locked(force=True)

    async def _emit_locked(self, force: bool) -> None:
        now = time.monotonic()
        if not force and now - self.last_emit < 1.0:
            return
        downloaded = self.completed_bytes + sum(self.active_bytes.values())
        elapsed = max(now - self.start_time, 0.001)
        speed_bps = downloaded / elapsed
        percent = 0.0
        if self.total_bytes > 0:
            percent = min(100.0, downloaded * 100.0 / self.total_bytes)
        info = dict(self.base_info)
        info.update(
            {
                "downloaded_bytes": downloaded,
                "total_bytes": self.total_bytes,
                "percent": percent,
                "speed_bps": speed_bps,
                "completed_files": self.completed_files,
                "total_files": self.total_files,
            }
        )
        self.last_emit = now
        await self.progress_callback(info)


def sanitize_name(value: str, fallback: str) -> str:
    value = re.sub(r"\s+", " ", value or "").strip()
    value = re.sub(INVALID_FS_CHARS, "_", value)
    value = value.rstrip(". ")
    if not value:
        value = fallback
    return value[:MAX_FOLDER_NAME].strip() or fallback


def first_sentence(text: str | None) -> str | None:
    if not text:
        return None
    normalized = text.strip()
    if not normalized:
        return None
    parts = [part.strip() for part in SENTENCE_SPLIT_RE.split(normalized) if part.strip()]
    if parts:
        return parts[0]
    return normalized.splitlines()[0].strip() or None


def build_folder_name(source_name: str, message_id: int) -> str:
    fallback = f"message_{message_id}"
    return sanitize_name(f"{source_name}-{message_id}", fallback)


def meta_file_for(output_dir: Path, source_name: str, message_id: int) -> Path:
    folder_name = build_folder_name(source_name, message_id)
    return output_dir / folder_name / "meta.json"


def is_message_archived(output_dir: Path, source_name: str, message_id: int) -> bool:
    return meta_file_for(output_dir, source_name, message_id).exists()


def clamp_concurrency(value: int) -> int:
    return max(1, min(10, int(value)))


def media_size(message: Message) -> int:
    return int(getattr(getattr(message, "file", None), "size", 0) or 0)


def write_readme(
    archive_dir: Path,
    title: str,
    source_name: str,
    message_id: int,
    published_at: str,
    raw_text: str,
    main_files: list[str],
    comment_files: list[str],
    single_mode: bool = False,
    selected_comment_id: int | None = None,
) -> None:
    lines = [
        f"- Source chat: `{source_name}`",
        f"- Original message ID: `{message_id}`",
        f"- Published at (UTC): `{published_at}`",
        f"- Main media count: `{len(main_files)}`",
        f"- Comment media count: `{len(comment_files)}`",
        f"- Single mode: `{'true' if single_mode else 'false'}`",
    ]
    if selected_comment_id is not None:
        lines.append(f"- Selected comment ID: `{selected_comment_id}`")
    # Markdown 中单换行会被合并成空格，加两个空格强制换行，保留原始格式。
    raw_text_md = raw_text.replace("\n", "  \n") if raw_text else raw_text
    lines.extend(
        [
            "## Description",
            raw_text_md,
            "## Files",
            *[f"- `{name}`" for name in main_files],
            *[f"- `{name}`" for name in comment_files],
        ]
    )
    md = format_message_md(title=title, lines=lines)
    (archive_dir / "README.md").write_text(md, encoding="utf-8")


def has_media(message: Message) -> bool:
    return bool(message and message.media)


def format_message_md(title: str, lines: Iterable[str]) -> str:
    filtered = [line for line in lines if line.strip()]
    body = "\n\n".join(filtered).strip()
    return f"# {title}\n\n{body}\n"


def ensure_unique_dir(path: Path) -> Path:
    if not path.exists():
        return path
    index = 2
    while True:
        candidate = path.with_name(f"{path.name}_{index}")
        if not candidate.exists():
            return candidate
        index += 1


def parse_message_link(link: str) -> ParsedMessageLink:
    parsed = urlparse(link.strip())
    comment_id: int | None = None
    single = False
    if parsed.query:
        params = parse_qs(parsed.query)
        comment_values = params.get("comment")
        if comment_values:
            try:
                comment_id = int(comment_values[0])
            except ValueError as exc:
                raise ValueError("Unsupported comment link format. The comment id must be an integer.") from exc
        single = "single" in params or parsed.query == "single" or "single&" in parsed.query or "&single" in parsed.query

    normalized = f"{parsed.scheme}://{parsed.netloc}{parsed.path}" if parsed.scheme and parsed.netloc else link.strip()
    match = MESSAGE_LINK_RE.fullmatch(normalized)
    if not match:
        raise ValueError("Unsupported message link format. Please use a standard t.me message link.")
    if match.group("username"):
        return ParsedMessageLink(
            chat_ref=match.group("username"),
            message_id=int(match.group("msg_id")),
            comment_id=comment_id,
            single=single,
        )
    internal_id = int(match.group("chat_id"))
    return ParsedMessageLink(
        chat_ref=int(f"-100{internal_id}"),
        message_id=int(match.group("private_msg_id")),
        comment_id=comment_id,
        single=single,
    )


async def resolve_entity_name(client: TelegramClient, entity) -> str:
    if isinstance(entity, str):
        return entity
    resolved = await client.get_entity(entity)
    title = getattr(resolved, "title", None)
    username = getattr(resolved, "username", None)
    return title or username or str(getattr(resolved, "id", "unknown"))


async def normalize_entity_for_fetch(client: TelegramClient, entity):
    try:
        return await client.get_input_entity(entity)
    except Exception:
        return entity


async def get_discussion_info(client: TelegramClient, entity, message_id: int):
    discussion_data = await client(
        functions.messages.GetDiscussionMessageRequest(
            peer=entity,
            msg_id=message_id,
        )
    )
    discussion_messages = getattr(discussion_data, "messages", None) or []
    if not discussion_messages:
        return None, None, discussion_data
    discussion = discussion_messages[0]
    discussion_peer = getattr(discussion, "peer_id", None)
    return discussion, discussion_peer, discussion_data


async def fetch_all_replies(client: TelegramClient, discussion_peer, root_msg_id: int) -> list[Message]:
    replies: list[Message] = []
    offset_id = 0
    while True:
        batch = await client(
            functions.messages.GetRepliesRequest(
                peer=discussion_peer,
                msg_id=root_msg_id,
                offset_id=offset_id,
                offset_date=None,
                add_offset=0,
                limit=100,
                max_id=0,
                min_id=0,
                hash=0,
            )
        )
        messages = getattr(batch, "messages", None) or []
        page = [msg for msg in messages if isinstance(msg, Message)]
        if not page:
            break
        replies.extend(page)
        if len(page) < 100:
            break
        offset_id = page[-1].id
    return replies


async def fetch_replies_via_channel_reply_to(
    client: TelegramClient,
    entity,
    root_msg_id: int,
) -> list[Message]:
    replies: list[Message] = []
    async for reply in client.iter_messages(entity, reply_to=root_msg_id, reverse=True):
        if isinstance(reply, Message):
            replies.append(reply)
    return replies


def group_thread_messages(messages: list[Message]) -> list[list[Message]]:
    grouped: dict[int, list[Message]] = {}
    singles: list[list[Message]] = []
    for message in messages:
        if not isinstance(message, Message):
            continue
        group_id = getattr(message, "grouped_id", None)
        if group_id:
            grouped.setdefault(group_id, []).append(message)
        else:
            singles.append([message])
    groups = list(grouped.values()) + singles
    for group in groups:
        group.sort(key=lambda item: item.id)
    groups.sort(key=lambda group: group[0].id)
    return groups


async def count_channel_message_groups(client: TelegramClient, entity) -> int:
    grouped_ids: set[int] = set()
    total_groups = 0
    async for message in client.iter_messages(entity, reverse=True):
        if not isinstance(message, Message):
            continue
        group_id = getattr(message, "grouped_id", None)
        if group_id:
            if group_id in grouped_ids:
                continue
            grouped_ids.add(group_id)
        total_groups += 1
    return total_groups


async def collect_album_messages(
    client: TelegramClient,
    entity,
    message: Message,
) -> list[Message]:
    if not getattr(message, "grouped_id", None):
        return [message]

    fetch_entity = await normalize_entity_for_fetch(client, entity)
    siblings: list[Message] = []
    candidates = await client.get_messages(
        fetch_entity,
        limit=25,
        min_id=max(0, message.id - 12),
        max_id=message.id + 12,
        reverse=True,
    )
    for candidate in candidates:
        if not isinstance(candidate, Message):
            continue
        if getattr(candidate, "grouped_id", None) == message.grouped_id:
            siblings.append(candidate)
    if not siblings:
        fallback_ids = list(range(max(1, message.id - 12), message.id + 13))
        fallback_candidates = await client.get_messages(fetch_entity, ids=fallback_ids)
        for candidate in fallback_candidates:
            if not isinstance(candidate, Message):
                continue
            if getattr(candidate, "grouped_id", None) == message.grouped_id:
                siblings.append(candidate)
    if not siblings:
        async for candidate in client.iter_messages(
            fetch_entity,
            offset_id=message.id + 20,
            max_id=message.id + 20,
            min_id=max(0, message.id - 20),
            reverse=True,
            limit=60,
        ):
            if not isinstance(candidate, Message):
                continue
            if getattr(candidate, "grouped_id", None) == message.grouped_id:
                siblings.append(candidate)
    siblings.sort(key=lambda item: item.id)
    print(
        "Album collect:",
        {
            "anchor_message_id": message.id,
            "grouped_id": getattr(message, "grouped_id", None),
            "entity": str(fetch_entity),
            "sibling_ids": [item.id for item in siblings],
            "media_types": [type(getattr(item, "media", None)).__name__ for item in siblings],
        },
    )
    return siblings or [message]


async def _refresh_message_for_download(client: TelegramClient, message: Message) -> Message:
    """重新拉取单条消息以获取新的 file_reference（约 1 小时过期）。

    下载遇到 FileReferenceExpiredError 时用于重试。利用消息自身的 chat_id 重新查询，
    不依赖外部 entity 变量，对主消息和评论消息都通用。
    """
    try:
        chat_id = getattr(message, "chat_id", None)
        if chat_id is not None:
            refreshed = await client.get_messages(chat_id, ids=message.id)
            if isinstance(refreshed, Message):
                return refreshed
    except Exception:
        pass
    return message


async def download_messages_media(
    client: TelegramClient,
    messages: list[Message],
    target_dir: Path,
    download_options: DownloadOptions | None = None,
    progress_tracker: DownloadProgressTracker | None = None,
    task_control: TaskControl | None = None,
) -> list[str]:
    saved_files: list[str] = []
    download_options = download_options or DownloadOptions()
    target_dir.mkdir(parents=True, exist_ok=True)
    semaphore = asyncio.Semaphore(clamp_concurrency(download_options.max_concurrency))

    async def download_one(item: Message) -> list[str]:
        if not has_media(item):
            return []
        if task_control:
            await task_control.checkpoint()
        async with semaphore:
            file_key = f"{item.id}:{id(item)}"
            file_size = media_size(item)

            async def on_progress(current: int, total: int) -> None:
                if task_control:
                    await task_control.checkpoint()
                if progress_tracker:
                    await progress_tracker.update_file(file_key, current)

            media_item = item
            try:
                downloaded = await client.download_media(
                    media_item,
                    file=str(target_dir),
                    progress_callback=on_progress if progress_tracker else None,
                )
            except FileReferenceExpiredError:
                # file_reference 是短命令牌（约 1 小时过期）。频道批量下载时消息可能在很久
                # 之前拉取，引用已过期。重新获取该消息拿到新引用后重试一次。
                refreshed = await _refresh_message_for_download(client, media_item)
                if refreshed is media_item:
                    raise
                media_item = refreshed
                downloaded = await client.download_media(
                    media_item,
                    file=str(target_dir),
                    progress_callback=on_progress if progress_tracker else None,
                )
            if progress_tracker:
                await progress_tracker.finish_file(file_key, total if (total := file_size) else 0)
            if not downloaded:
                return []
            if isinstance(downloaded, list):
                return [str(Path(path).name) for path in downloaded if path]
            return [Path(downloaded).name]

    batches = await asyncio.gather(*(download_one(item) for item in messages))
    for names in batches:
        saved_files.extend(names)
    return saved_files


async def download_single_message_media(
    client: TelegramClient,
    message: Message,
    target_dir: Path,
    download_options: DownloadOptions | None = None,
    progress_tracker: DownloadProgressTracker | None = None,
    task_control: TaskControl | None = None,
) -> list[str]:
    if not has_media(message):
        return []
    return await download_messages_media(
        client,
        [message],
        target_dir,
        download_options=download_options,
        progress_tracker=progress_tracker,
        task_control=task_control,
    )


async def collect_comment_media(
    client: TelegramClient,
    entity,
    message: Message,
    archive_dir: Path,
    download_options: DownloadOptions | None = None,
    progress_tracker: DownloadProgressTracker | None = None,
    prepared_groups: list[list[Message]] | None = None,
    task_control: TaskControl | None = None,
) -> tuple[list[str], list[str]]:
    saved_files: list[str] = []
    comment_notes: list[str] = []
    seen_saved_names: set[str] = set()

    async def save_files(messages: list[Message], target_subdir: str) -> list[str]:
        if not messages:
            return []
        if len(messages) <= 1:
            names = await download_single_message_media(
                client,
                messages[0],
                archive_dir / target_subdir,
                download_options=download_options,
                progress_tracker=progress_tracker,
                task_control=task_control,
            )
        else:
            names = await download_messages_media(
                client,
                messages,
                archive_dir / target_subdir,
                download_options=download_options,
                progress_tracker=progress_tracker,
                task_control=task_control,
            )
        unique_paths: list[str] = []
        for name in names:
            rel = f"{target_subdir}/{name}"
            if rel in seen_saved_names:
                continue
            seen_saved_names.add(rel)
            unique_paths.append(rel)
        return unique_paths

    if prepared_groups is None:
        prepared_groups, prepared_notes = await prepare_comment_groups(client, entity, message)
        comment_notes.extend(prepared_notes)
    thread_groups = prepared_groups or []
    fallback_iter_count = sum(len(group) for group in thread_groups)
    for group in thread_groups:
        anchor = group[0]
        preview = (anchor.message or "").strip().replace("\n", " ")
        if preview:
            comment_notes.append(f"- Comment {anchor.id}: {preview}")
        print(
            "Discussion comment debug:",
            {
                "anchor_id": anchor.id,
                "grouped_id": getattr(anchor, "grouped_id", None),
                "group_size": len(group),
                "media_types": [type(getattr(item, "media", None)).__name__ for item in group],
            },
        )
        files = await save_files(group, "comments")
        saved_files.extend(files)

    print(
        "Discussion fallback result:",
        {
            "source_message_id": message.id,
            "iterated_replies": fallback_iter_count,
            "downloaded_comment_files": len(saved_files),
        },
    )
    return saved_files, comment_notes


async def prepare_comment_groups(
    client: TelegramClient,
    entity,
    message: Message,
) -> tuple[list[list[Message]], list[str]]:
    comment_notes: list[str] = []
    try:
        discussion, discussion_peer, _discussion_data = await get_discussion_info(client, entity, message.id)
    except Exception as exc:
        comment_notes.append(f"- Failed to read discussion thread: `{type(exc).__name__}: {exc}`")
        return [], comment_notes

    if not discussion or not discussion_peer:
        return [], comment_notes

    print(
        "Discussion fallback:",
        {
            "discussion_id": getattr(discussion, "id", None),
            "discussion_peer": str(discussion_peer),
            "reply_to_msg_id": getattr(getattr(discussion, "reply_to", None), "reply_to_msg_id", None),
        },
    )
    reply_fetch_mode = "getReplies"
    try:
        all_replies = await fetch_all_replies(client, discussion_peer, getattr(discussion, "id", 0))
    except MsgIdInvalidError as exc:
        comment_notes.append(
            f"- getReplies failed for discussion root `{getattr(discussion, 'id', None)}`; falling back to channel reply lookup: `{type(exc).__name__}: {exc}`"
        )
        reply_fetch_mode = "channel.reply_to"
        all_replies = await fetch_replies_via_channel_reply_to(client, entity, message.id)
    print(
        "Discussion replies fetched:",
        {
            "discussion_root_id": getattr(discussion, "id", None),
            "total_replies": len(all_replies),
            "mode": reply_fetch_mode,
        },
    )
    return group_thread_messages(all_replies), comment_notes


async def archive_message(
    client: TelegramClient,
    entity,
    message: Message,
    output_dir: Path,
    include_comments: bool = True,
    progress_callback=None,
    force_single: bool = False,
    download_options: DownloadOptions | None = None,
    task_control: TaskControl | None = None,
    prepared_album: list[Message] | None = None,
) -> ArchiveResult | None:
    if task_control:
        await task_control.checkpoint()
    album = prepared_album if prepared_album is not None else ([message] if force_single else await collect_album_messages(client, entity, message))
    main_has_media = any(has_media(item) for item in album)
    # 先准备评论区分组，用于判断「主消息无媒体但评论区有媒体」的情况。
    # 某些频道主贴只有文字，图片/视频全在评论区——这类消息也要归档（main 目录留空，
    # 仅下载评论区资源），而不是直接跳过。
    prepared_comment_groups: list[list[Message]] = []
    prepared_comment_notes: list[str] = []
    if include_comments:
        if task_control:
            await task_control.checkpoint()
        prepared_comment_groups, prepared_comment_notes = await prepare_comment_groups(client, entity, message)
    comments_have_media = any(has_media(item) for group in prepared_comment_groups for item in group)
    # 纯文字消息（无媒体、无评论媒体）也归档：保留简介文字到 README，只是不下载媒体文件。
    # 仅当既无媒体又无文字时才跳过。
    has_text = bool(message.message and message.message.strip())
    if not main_has_media and not comments_have_media and not has_text:
        return None

    source_name = await resolve_entity_name(client, entity)
    # 相册（album）的命名锚点：取最小 id 那条（最旧，通常是带 caption 的第一张），
    # 这样文件夹名、README、meta 都以「帖子的第一条」为准，与 t.me/<channel>/<min_id> 一致。
    # 单条消息时 anchor 即 message 本身。
    anchor = album[0] if album else message
    folder_name = build_folder_name(source_name, anchor.id)
    archive_dir = ensure_unique_dir(output_dir / folder_name)
    archive_dir.mkdir(parents=True, exist_ok=False)
    download_options = download_options or DownloadOptions()
    # 相册的 caption 通常只在其中一条消息上，从相册里取有文字的那条，避免 channel
    # 模式遍历到非 caption 项时 README 丢失简介文字。
    text_source = next((item for item in album if item.message and item.message.strip()), anchor)
    raw_text = text_source.message.strip() if text_source.message else "(no text)"
    write_readme(
        archive_dir=archive_dir,
        title=folder_name,
        source_name=source_name,
        message_id=anchor.id,
        published_at=anchor.date.isoformat(),
        raw_text=raw_text,
        main_files=[],
        comment_files=[],
        single_mode=force_single,
    )
    total_bytes = sum(media_size(item) for item in album)
    total_files = len([item for item in album if has_media(item)])
    if include_comments:
        total_bytes += sum(media_size(item) for group in prepared_comment_groups for item in group)
        total_files += sum(1 for group in prepared_comment_groups for item in group if has_media(item))
    progress_tracker = DownloadProgressTracker(
        progress_callback,
        {
            "stage": "downloading",
            "source_chat": source_name,
            "message_id": anchor.id,
            "title": folder_name,
            "folder": str(archive_dir),
            "single": force_single,
        },
        total_bytes=total_bytes,
    )
    if progress_callback:
        await progress_tracker.add_total_files(total_files)

    if progress_callback:
        await progress_callback(
            {
                "stage": "main_start",
                "source_chat": source_name,
                "message_id": anchor.id,
                "title": folder_name,
                "folder": str(archive_dir),
                "single": force_single,
            }
        )
    main_files = await download_messages_media(
        client,
        album,
        archive_dir / "main",
        download_options=download_options,
        progress_tracker=progress_tracker,
        task_control=task_control,
    )
    if progress_callback:
        await progress_callback(
            {
                "stage": "main_done",
                "source_chat": source_name,
                "message_id": anchor.id,
                "title": folder_name,
                "folder": str(archive_dir),
                "main_count": len(main_files),
                "single": force_single,
            }
        )
    comment_files: list[str] = []
    comment_notes: list[str] = []
    if include_comments:
        if progress_callback:
            await progress_callback(
                {
                    "stage": "comments_start",
                    "source_chat": source_name,
                    "message_id": anchor.id,
                    "title": folder_name,
                    "folder": str(archive_dir),
                    "main_count": len(main_files),
                    "single": force_single,
                }
            )
        comment_files, comment_notes = await collect_comment_media(
            client,
            entity,
            message,
            archive_dir,
            download_options=download_options,
            progress_tracker=progress_tracker,
            prepared_groups=prepared_comment_groups,
            task_control=task_control,
        )
        comment_notes = prepared_comment_notes + [note for note in comment_notes if note not in prepared_comment_notes]
        if progress_callback:
            await progress_callback(
                {
                    "stage": "comments_done",
                    "source_chat": source_name,
                    "message_id": anchor.id,
                    "title": folder_name,
                    "folder": str(archive_dir),
                    "main_count": len(main_files),
                    "comment_count": len(comment_files),
                    "single": force_single,
            }
        )

    write_readme(
        archive_dir=archive_dir,
        title=folder_name,
        source_name=source_name,
        message_id=anchor.id,
        published_at=anchor.date.isoformat(),
        raw_text=raw_text,
        main_files=main_files,
        comment_files=comment_files,
        single_mode=force_single,
    )

    meta = {
        "source_chat": source_name,
        "message_id": anchor.id,
        "title": folder_name,
        "main_files": main_files,
        "comment_files": comment_files,
    }
    (archive_dir / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return ArchiveResult(
        folder=archive_dir,
        source_chat=source_name,
        message_id=anchor.id,
        title=folder_name,
        main_files=main_files,
        comment_files=comment_files,
        comment_notes=comment_notes,
    )


async def archive_channel(
    client: TelegramClient,
    chat: str | int,
    output_dir: Path,
    limit: int | None,
    include_comments: bool = True,
    progress_callback=None,
    download_options: DownloadOptions | None = None,
    task_control: TaskControl | None = None,
    offset: int = 0,
    range_mode: bool = False,
) -> ChannelArchiveSummary:
    if task_control:
        await task_control.checkpoint()
    entity = await client.get_entity(chat)
    source_name = await resolve_entity_name(client, entity)
    total_available = None
    # 这里的“数量 / 序号”统一按 message group 计算：
    # - 单条普通消息 = 1 group
    # - 一个 album / grouped_id = 1 group
    # 也就是最终归档后生成的文件夹数量。
    #
    # 自定义区间（序号模型）：offset 表示跳过最新的 offset 个 group，limit 取其后 limit 个 group。
    # range_mode 由调用方显式传入：True=区间模式（从旧到新，1=频道第一个 group），
    # False=普通模式（最新 N 个 group，从新到旧）。不再从 offset 推断，避免 offset=0 的
    # 区间（如 1 5）被误判为普通模式。
    if limit is None:
        try:
            total_available = await count_channel_message_groups(client, entity)
        except Exception:
            total_available = None
    if range_mode and limit is not None:
        target_messages = limit
    elif limit is None:
        target_messages = total_available if isinstance(total_available, int) and total_available > 0 else None
    else:
        target_messages = limit
    processed_group_ids: set[int] = set()
    failures: list[ArchiveFailure] = []
    scanned = 0
    skipped = 0
    archived_count = 0
    failed_count = 0
    main_files = 0
    comment_files = 0
    # 懒迭代 + group 级序号截断。
    # 普通模式（range_mode=False）：reverse=False 从新到旧，取最新 limit 个 group。
    # 区间模式（range_mode=True）：reverse=True 从旧到新，position 1=频道第一个 group（最旧）。
    iter_kwargs: dict = {}
    if range_mode:
        iter_kwargs["reverse"] = True
    else:
        iter_kwargs["reverse"] = False
    # range_mode 下 offset=start_seq-1, limit=区间长度；position 从 1=最旧开始。
    range_start = offset + 1
    range_end = offset + limit if limit is not None else None
    position = 0
    async for message in client.iter_messages(entity, **iter_kwargs):
        if not isinstance(message, Message):
            continue
        group_id = getattr(message, "grouped_id", None)
        if group_id and group_id in processed_group_ids:
            continue
        if group_id:
            processed_group_ids.add(group_id)
        position += 1
        if range_mode:
            if position < range_start:
                continue
            if range_end is not None and position > range_end:
                break
        elif limit is not None and scanned >= limit:
            break

        if task_control:
            await task_control.checkpoint()
        scanned += 1
        album = [message] if not group_id else await collect_album_messages(client, entity, message)
        anchor = album[0] if album else message

        if is_message_archived(output_dir, source_name, anchor.id):
            skipped += 1
            if progress_callback:
                await progress_callback(
                    {
                        "source_chat": source_name,
                        "target_messages": target_messages,
                        "scanned": scanned,
                        "archived": archived_count,
                        "skipped": skipped,
                        "failed": failed_count,
                        "main_files": main_files,
                        "comment_files": comment_files,
                        "event": "skipped",
                        "message_id": anchor.id,
                    }
                )
            continue

        try:
            async def item_progress(item_info: dict) -> None:
                if progress_callback:
                    merged = {
                        "source_chat": source_name,
                        "target_messages": target_messages,
                        "scanned": scanned,
                        "archived": archived_count,
                        "skipped": skipped,
                        "failed": failed_count,
                        "main_files": main_files,
                        "comment_files": comment_files,
                        "event": "item_progress",
                    }
                    merged.update(item_info)
                    await progress_callback(merged)

            result = await archive_message(
                client,
                entity,
                message,
                output_dir,
                include_comments=include_comments,
                progress_callback=item_progress,
                download_options=download_options,
                task_control=task_control,
                prepared_album=album,
            )
        except Exception as exc:
            failed_count += 1
            # 仅保留前 50 条失败明细用于汇总展示，避免大频道归档时 failures 列表无限增长。
            if len(failures) < 50:
                failures.append(
                    ArchiveFailure(
                        message_id=message.id,
                        error_type=type(exc).__name__,
                        error_message=str(exc),
                    )
                )
            if progress_callback:
                await progress_callback(
                    {
                        "source_chat": source_name,
                        "target_messages": target_messages,
                        "scanned": scanned,
                        "archived": archived_count,
                        "skipped": skipped,
                        "failed": failed_count,
                        "main_files": main_files,
                        "comment_files": comment_files,
                        "event": "failed",
                        "message_id": anchor.id,
                        "error": f"{type(exc).__name__}: {exc}",
                    }
                )
            continue

        if result:
            archived_count += 1
            main_files += len(result.main_files)
            comment_files += len(result.comment_files)
            if progress_callback:
                await progress_callback(
                    {
                        "source_chat": source_name,
                        "target_messages": target_messages,
                        "scanned": scanned,
                        "archived": archived_count,
                        "skipped": skipped,
                        "failed": failed_count,
                        "main_files": main_files,
                        "comment_files": comment_files,
                        "event": "archived",
                        "message_id": result.message_id,
                        "title": result.title,
                        "main_count": len(result.main_files),
                        "comment_count": len(result.comment_files),
                    }
                )
        # result 不再保留到列表：大频道归档时避免 ArchiveResult 对象无限累积导致内存膨胀。
        await asyncio.sleep(0)
    return ChannelArchiveSummary(
        source_chat=source_name,
        target_messages=target_messages,
        scanned_messages=scanned,
        archived_messages=archived_count,
        skipped_messages=skipped,
        failed_messages=failed_count,
        main_files=main_files,
        comment_files=comment_files,
        results=[],
        failures=failures,
    )


async def archive_message_by_link(
    client: TelegramClient,
    link: str,
    output_dir: Path,
    include_comments: bool = True,
    progress_callback=None,
    download_options: DownloadOptions | None = None,
    task_control: TaskControl | None = None,
) -> ArchiveResult | None:
    if task_control:
        await task_control.checkpoint()
    parsed = parse_message_link(link)
    entity = await client.get_entity(parsed.chat_ref)
    if parsed.comment_id is not None:
        discussion, discussion_peer, _discussion_data = await get_discussion_info(client, entity, parsed.message_id)
        if not discussion or not discussion_peer:
            return None
        try:
            if task_control:
                await task_control.checkpoint()
            all_replies = await fetch_all_replies(client, discussion_peer, getattr(discussion, "id", 0))
        except MsgIdInvalidError:
            if task_control:
                await task_control.checkpoint()
            all_replies = await fetch_replies_via_channel_reply_to(client, entity, parsed.message_id)
        thread_groups = group_thread_messages(all_replies)
        selected_group: list[Message] | None = None
        for group in thread_groups:
            if any(item.id == parsed.comment_id for item in group):
                selected_group = group
                break
        if not selected_group:
            return None
        root_message = await client.get_messages(entity, ids=parsed.message_id)
        if not isinstance(root_message, Message):
            return None

        source_name = await resolve_entity_name(client, entity)
        folder_name = build_folder_name(source_name, root_message.id)
        archive_dir = ensure_unique_dir(output_dir / folder_name)
        archive_dir.mkdir(parents=True, exist_ok=False)
        download_options = download_options or DownloadOptions()
        main_album = [root_message] if parsed.single else await collect_album_messages(client, entity, root_message)
        # 相册 caption 通常只在其中一条，取有文字的那条
        text_source = next((item for item in main_album if item.message and item.message.strip()), root_message)
        raw_text = text_source.message.strip() if text_source.message else "(no text)"
        write_readme(
            archive_dir=archive_dir,
            title=folder_name,
            source_name=source_name,
            message_id=root_message.id,
            published_at=root_message.date.isoformat(),
            raw_text=raw_text,
            main_files=[],
            comment_files=[],
            single_mode=parsed.single,
            selected_comment_id=parsed.comment_id,
        )

        if progress_callback:
            await progress_callback(
                {
                    "stage": "main_start",
                    "source_chat": source_name,
                    "message_id": root_message.id,
                    "title": folder_name,
                    "folder": str(archive_dir),
                    "selected_comment_id": parsed.comment_id,
                    "single": parsed.single,
                }
            )
        total_bytes = sum(media_size(item) for item in main_album) + sum(media_size(item) for item in selected_group)
        progress_tracker = DownloadProgressTracker(
            progress_callback,
            {
                "stage": "downloading",
                "source_chat": source_name,
                "message_id": root_message.id,
                "title": folder_name,
                "folder": str(archive_dir),
                "selected_comment_id": parsed.comment_id,
                "single": parsed.single,
            },
            total_bytes=total_bytes,
        )
        if progress_callback:
            await progress_tracker.add_total_files(len([item for item in main_album if has_media(item)]))
            await progress_tracker.add_total_files(len([item for item in selected_group if has_media(item)]))
        main_files = await download_messages_media(
            client,
            main_album,
            archive_dir / "main",
            download_options=download_options,
            progress_tracker=progress_tracker,
            task_control=task_control,
        )
        if progress_callback:
            await progress_callback(
                {
                    "stage": "main_done",
                    "source_chat": source_name,
                    "message_id": root_message.id,
                    "title": folder_name,
                    "folder": str(archive_dir),
                    "main_count": len(main_files),
                    "selected_comment_id": parsed.comment_id,
                    "single": parsed.single,
                }
            )
            await progress_callback(
                {
                    "stage": "comments_start",
                    "source_chat": source_name,
                    "message_id": root_message.id,
                    "title": folder_name,
                    "folder": str(archive_dir),
                    "main_count": len(main_files),
                    "selected_comment_id": parsed.comment_id,
                    "single": parsed.single,
                }
            )
        comment_names = await download_messages_media(
            client,
            selected_group,
            archive_dir / "comments",
            download_options=download_options,
            progress_tracker=progress_tracker,
            task_control=task_control,
        )
        comment_files = [f"comments/{name}" for name in comment_names]
        if progress_callback:
            await progress_callback(
                {
                    "stage": "comments_done",
                    "source_chat": source_name,
                    "message_id": root_message.id,
                    "title": folder_name,
                    "folder": str(archive_dir),
                    "main_count": len(main_files),
                    "comment_count": len(comment_files),
                    "selected_comment_id": parsed.comment_id,
                    "single": parsed.single,
                }
            )
        comment_notes = []
        anchor = selected_group[0]
        preview = (anchor.message or "").strip()
        if preview:
            comment_notes.append(f"- Comment {anchor.id}: {preview}")

        write_readme(
            archive_dir=archive_dir,
            title=folder_name,
            source_name=source_name,
            message_id=root_message.id,
            published_at=root_message.date.isoformat(),
            raw_text=raw_text,
            main_files=main_files,
            comment_files=comment_files,
            single_mode=parsed.single,
            selected_comment_id=parsed.comment_id,
        )
        meta = {
            "source_chat": source_name,
            "message_id": root_message.id,
            "title": folder_name,
            "main_files": main_files,
            "comment_files": comment_files,
            "selected_comment_id": parsed.comment_id,
            "single": parsed.single,
        }
        (archive_dir / "meta.json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        return ArchiveResult(
            folder=archive_dir,
            source_chat=source_name,
            message_id=root_message.id,
            title=folder_name,
            main_files=main_files,
            comment_files=comment_files,
            comment_notes=comment_notes,
        )

    message = await client.get_messages(entity, ids=parsed.message_id)
    if not isinstance(message, Message):
        return None
    return await archive_message(
        client,
        entity,
        message,
        output_dir,
        include_comments=include_comments and not parsed.single,
        progress_callback=progress_callback,
        force_single=parsed.single,
        download_options=download_options,
        task_control=task_control,
    )


async def archive_forwarded_message(
    client: TelegramClient,
    forward: Forward | None,
    output_dir: Path,
    include_comments: bool = True,
    progress_callback=None,
    download_options: DownloadOptions | None = None,
    task_control: TaskControl | None = None,
) -> ArchiveResult | None:
    if not forward or not getattr(forward, "chat", None) or not getattr(forward, "channel_post", None):
        return None
    entity = await client.get_entity(forward.chat)
    message = await client.get_messages(entity, ids=forward.channel_post)
    if not isinstance(message, Message):
        return None
    return await archive_message(
        client,
        entity,
        message,
        output_dir,
        include_comments=include_comments,
        progress_callback=progress_callback,
        download_options=download_options,
        task_control=task_control,
    )


def describe_forward(forward: Forward | None) -> dict:
    if not forward:
        return {"has_forward": False}
    return {
        "has_forward": True,
        "chat": bool(getattr(forward, "chat", None)),
        "channel_post": getattr(forward, "channel_post", None),
        "saved_from_peer": bool(getattr(forward, "saved_from_peer", None)),
        "saved_from_msg_id": getattr(forward, "saved_from_msg_id", None),
        "from_name": getattr(forward, "from_name", None),
        "date": str(getattr(forward, "date", None)),
    }
