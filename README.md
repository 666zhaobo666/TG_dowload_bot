# TG_dowload_bot

Telegram 频道/群组资源归档 Bot。

它支持：

- 通过 `/message` 下载单条主贴或指定评论链接
- 通过 `/channel` 批量下载频道消息
- 自动抓主消息和 discussion/comment 里的图片、视频资源
- 每条消息单独建目录，目录名为 `频道名-消息ID`
- 在 TG 内显示下载进度、百分比、网速、文件计数
- 支持暂停、恢复、停止当前任务
- 支持 Linux 一键安装、配置、systemd 后台运行和卸载

## 目录结构

每条消息一个目录，例如：

```text
downloads/
  花园月下 怡红院-913/
    README.md
    meta.json
    main/
    comments/
```

其中：

- `main/` 保存主消息资源
- `comments/` 保存评论区资源
- `README.md` 只保留主消息简介和文件清单

## Bot 命令

- `/start`
  显示帮助

- `/message <t.me消息链接>`
  下载一条主贴资源和评论区资源

- `/message <t.me消息链接?comment=评论ID>`
  下载主贴资源和指定评论资源组

- `/message <t.me消息链接?single>`
  只下载该条消息本身，不扩相册，不抓评论

- `/channel <频道链接>`
  让 Bot 弹出按钮供你选择：
  - `全部`
  - `最新200`
  - `最新100`
  - `最新50`

- `/channel <频道链接> <数量>`
  直接下载最新 N 条消息

- `/pause`
  暂停当前任务

- `/resume`
  恢复当前任务，并重新回显最新进度

- `/stop`
  停止当前任务

## 运行规则

- 同一时间只允许一个下载任务运行
- 如果当前已有任务在运行，新任务会被拒绝
- 频道批量下载支持跳过已归档消息，便于断点续跑

## 环境变量

参考 [.env.example](C:/AAA/Projects/TG_download/.env.example)：

- `TG_API_ID`
- `TG_API_HASH`
- `TG_BOT_TOKEN`
- `TG_USER_SESSION`
- `TG_PROXY`
- `OUTPUT_DIR`
- `INCLUDE_COMMENTS`
- `DEFAULT_CHANNEL_LIMIT`
- `MAX_DOWNLOAD_WORKERS`
- `DOWNLOAD_DIR_ALIASES`
- `DEFAULT_DOWNLOAD_ALIAS`
- `SILENT_DOWNLOAD_MODE`

说明：

- `MAX_DOWNLOAD_WORKERS`
  - 最小 `1`
  - 最大 `10`
  - 超过 `10` 自动按 `10` 处理

- `TG_PROXY`
  例如：
  ```text
  TG_PROXY=socks5://127.0.0.1:10808
  ```

- `DOWNLOAD_DIR_ALIASES`
  用于配置多个下载目录别名，格式：
  ```text
  DOWNLOAD_DIR_ALIASES=default=/data/tg/default;disk2=/mnt/disk2/tg
  ```

- `DEFAULT_DOWNLOAD_ALIAS`
  例如：
  ```text
  DEFAULT_DOWNLOAD_ALIAS=default
  ```

- `SILENT_DOWNLOAD_MODE`
  例如：
  ```text
  SILENT_DOWNLOAD_MODE=true
  ```

注意：`DOWNLOAD_DIR_ALIASES`、`DEFAULT_DOWNLOAD_ALIAS`、`SILENT_DOWNLOAD_MODE` 目前是为后续目录选择/静默目录模式预留的配置项；当前版本仍默认使用 `OUTPUT_DIR` 作为实际输出目录。

## Linux 一键管理

项目附带一个 Linux 管理脚本：[linux_manager.sh](C:/AAA/Projects/TG_download/linux_manager.sh)

这个脚本适合通过 `curl` 下载后直接执行，支持：

- 安装
- 配置/重配 `.env`
- 自动创建 virtualenv
- 自动安装依赖
- 自动创建并启动 `systemd` 服务
- 启动服务
- 重启服务
- 停止服务
- 查看服务状态
- 卸载

### 使用方式

下载并执行：

```bash
curl -fsSL <RAW_SCRIPT_URL> -o linux_manager.sh
chmod +x linux_manager.sh
./linux_manager.sh
```

安装完成后：

- 默认安装到 `/opt/TG_dowload_bot`
- 默认服务名：`tg-download-bot.service`
- 安装完成后会自动启动服务

### systemd 服务管理

也可以手动用 systemd：

```bash
sudo systemctl start tg-download-bot
sudo systemctl restart tg-download-bot
sudo systemctl stop tg-download-bot
sudo systemctl status tg-download-bot
```

## Windows / 本地开发

本地运行：

```powershell
python tg_archiver_bot.py
```

如果你需要先生成 `TG_USER_SESSION`：

```powershell
python generate_string_session.py
```

## 说明

- 只能抓取你的 Telegram 账号有权限访问的频道/群组
- discussion/comment 抓取依赖 Telegram 的 discussion 线程结构
- 某些消息的 forward 元数据不会暴露给 bot，这时请优先使用 `/message <链接>`
- 频道批量下载在超大评论线程下会比较耗时，属于正常现象
