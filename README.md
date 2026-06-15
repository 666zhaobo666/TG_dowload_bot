# TG_download_bot

> Telegram 媒体 / 消息归档 Bot —— 把频道或单条消息里的图片、视频、文档等媒体资源，连同评论区一起打包下载到服务器本地。

---

## 功能特性

- 支持 `/message <链接>` 一键归档单条消息（含评论区）。
- 支持 `/channel <链接> [数量]` 批量归档频道历史消息。
- 直接把频道消息**转发**给 Bot 即可自动归档原消息 + 评论区。
- 归档结果自动生成 `README.md` 元信息与 `meta.json`，按 `<频道名>-<消息ID>` 分目录。
- 多线程并发下载，并发数可在 `1 ~ 10` 之间调整。
- 支持下载目录**别名**管理，可一键切换多个磁盘 / 挂载点。
- 支持「**静默模式**」：下载完成后不再把文件回传到 Telegram，节省带宽。
- 任务级**暂停 / 恢复 / 停止**控制，随时接管长任务。
- 兼容 SOCKS5 / HTTP 代理，适配国内网络环境。

---

## 快速开始

### 一键安装（仅支持 Linux）

脚本会自动：安装依赖、克隆仓库、创建 `python3 venv` 虚拟环境、注册 `systemd` 服务并设置开机自启。

**国内加速地址（推荐）**

```bash
curl -sSL https://proxy.cccg.top/raw.githubusercontent.com/666zhaobo666/TG_dowload_bot/master/TG_dowload.sh -o TG_dowload.sh && chmod +x TG_dowload.sh && sudo ./TG_dowload.sh
```

**不加速地址**

```bash
curl -sSL https://raw.githubusercontent.com/666zhaobo666/TG_dowload_bot/master/TG_dowload.sh -o TG_dowload.sh && chmod +x TG_dowload.sh && sudo ./TG_dowload.sh
```

安装过程中会依次提示输入：

1. 安装目录（默认 `/root/TG_download`，按回车使用默认值）。
2. `TG_API_ID`：从 [my.telegram.org](https://my.telegram.org) 获取。
3. `TG_API_HASH`：同上。
4. `TG_BOT_TOKEN`：从 [@BotFather](https://t.me/BotFather) 创建机器人获得。
5. `TG_PROXY`：代理地址，例如 `socks5://127.0.0.1:10808`，直连可留空。
6. `MAX_DOWNLOAD_WORKERS`：并发下载数，范围 `1 ~ 10`，默认 `5`。
7. `TG_USER_SESSION`：User 登录会话字符串，脚本会引导你输入手机号 + 验证码自动生成。

> 安装脚本默认通过加速地址 `https://proxy.cccg.top/github.com/...` 克隆仓库，国内主机无需额外配置即可拉取成功。

安装完成后，管理命令会自动注册到 `/usr/local/bin/tgd`：

```bash
sudo tgd
```

进入交互式管理菜单，可执行：**重新配置**、**启动 / 重启 / 停止服务**、**查看状态**、**一键卸载**等操作。

---

## Bot 命令

在 Telegram 中向 Bot 发送以下命令：

| 命令 | 说明 |
| --- | --- |
| `/start` | 查看帮助信息 |
| `/message <消息链接或评论链接>` | 归档单条消息 |
| `/channel <频道链接> [数量]` | 归档频道历史消息 |
| `/dir add <别名> <绝对路径>` | 新增下载目录别名 |
| `/dir del <别名>` | 删除下载目录别名 |
| `/dir list` | 查看所有已配置的别名 |
| `/default <别名>` | 设置默认下载目录 |
| `/silent on` / `/silent off` | 开启 / 关闭静默模式 |
| `/pause` | 暂停当前任务 |
| `/resume` | 恢复当前任务 |
| `/stop` | 停止当前任务 |

**链接使用示例**

- 单条消息链接：`/message https://t.me/<channel>/<msg_id>`
- 评论链接：`/message https://t.me/<channel>/<msg_id>?thread=<thread_id>`
- 频道批量归档：`/channel https://t.me/<channel> 100`

**使用提示**

- 直接把**频道主消息**转发给 Bot，即可触发自动归档（保留来源信息）。
- 转发**频道评论区里的消息**给 Bot，会尝试定位并归档对应的根消息 + 整组评论。
- `/channel` 不带数量时，Bot 会弹出 `full / 200 / 100 / 50` 按钮供你选择。
- 当存在多个下载目录别名时，Bot 会弹出按钮让你选择本次任务的下载位置。
- 任一时刻**只能运行一个任务**，新任务需要等待当前任务结束或被 `/stop` 终止。

---

## 环境变量

配置文件位于 `${安装目录}/.env`，由管理脚本在安装 / 重新配置时自动生成与维护。

| 变量 | 说明 | 示例 |
| --- | --- | --- |
| `TG_API_ID` | Telegram API ID（数字） | `123456` |
| `TG_API_HASH` | Telegram API Hash | `xxxxxxxxxxxxxxxxxxxxxxxx` |
| `TG_BOT_TOKEN` | Bot Token，@BotFather 颁发 | `123456:AAH...` |
| `TG_USER_SESSION` | User 登录会话字符串 | `1BVtsOKE...` |
| `TG_PROXY` | 代理地址，留空表示直连 | `socks5://127.0.0.1:10808` |
| `MAX_DOWNLOAD_WORKERS` | 并发下载数，范围 `1 ~ 10`，默认 `5` | `5` |

> 下列变量在 **Bot 运行后** 可由 `/dir`、`/default`、`/silent` 命令动态维护，无需手动编辑：
>
> - `DOWNLOAD_DIR_ALIASES`：以 `别名1=/path/1;别名2=/path/2` 形式存储目录别名。
> - `DEFAULT_DOWNLOAD_ALIAS`：默认下载目录别名。
> - `SILENT_DOWNLOAD_MODE`：`true` / `false`，控制是否在归档完成后把文件回传到 Telegram。

---

## 归档目录结构

归档结果按 `<频道名>-<消息ID>` 分目录存放：

```text
downloads/
  channel_name-12345/
    README.md       # 消息正文 + 媒体说明
    meta.json       # 原始消息元数据
    main/           # 主消息里的图片 / 视频 / 文档
    comments/       # 评论区所有消息的媒体
```

---

## 手动安装（Windows / macOS）

在不便使用 systemd 的环境下，可直接使用 Python 启动 Bot：

```bash
# 1. 安装依赖
pip install -r requirements.txt

# 2. 生成 User Session（会要求输入手机号 + 验证码）
python generate_string_session.py

# 3. 复制并填写环境变量
cp .env.example .env
# 使用编辑器打开 .env，填入 TG_API_ID / TG_API_HASH / TG_BOT_TOKEN / TG_USER_SESSION 等

# 4. 启动 Bot
python tg_archiver_bot.py
```

---

## 常见问题

- **Bot 没有任何反应 / 报 `FloodWaitError`？**
  多半是 User Session 失效或所在 IP 触发风控。可执行 `sudo tgd` → 选择「重新配置」→ 重置 `TG_USER_SESSION`。

- **下载很慢 / 一直失败？**
  请检查 `TG_PROXY` 是否可用，或在 VPS 上确认没有被 Telegram 限速。可适当调小 `MAX_DOWNLOAD_WORKERS`。

- **想让 Bot 静默工作，不回传文件到 Telegram？**
  发送 `/silent on` 即可。归档依旧完成，只是不会把文件再上传到 Telegram 对话里。

- **怎么换下载盘？**
  用 `/dir add disk2 /mnt/disk2/downloads` 添加新别名，任务发起时 Bot 会让你选择本次下载目录；也可以用 `/default disk2` 设为默认。

---

## 许可证

本项目仅供学习与个人使用，下载的内容版权归原作者所有，请勿用于非法用途。