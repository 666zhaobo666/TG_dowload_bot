# TG_download_bot

> Telegram 媒体 / 消息归档 Bot —— 把频道或单条消息里的图片、视频、文档等媒体资源，连同评论区一起打包下载到服务器本地。

---

## 功能特性

- 支持 `/message <链接>` 一键归档单条消息（含评论区）。
- 支持 `/channel <链接> [数量]` 批量归档频道历史消息，并提供**自定义序号区间**下载。
- 直接把频道消息**转发**给 Bot 即可自动归档原消息 + 评论区。
- 归档结果自动生成 `README.md` 元信息与 `meta.json`，按 `<频道名>-<消息ID>` 分目录。
- 多线程并发下载，并发数可在 `1 ~ 10` 之间调整。
- 下载目录**别名**管理（按钮交互），可一键切换多个磁盘 / 挂载点。
- 「**静默模式**」（按钮交互）：开启时选择下载目录，下载时不再逐次询问。
- 任务级**暂停 / 恢复 / 停止**控制，进度实时刷新且长时间任务不会中断。
- 主消息无媒体但评论区有媒体的消息也会被归档（不再跳过）。
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

1. 安装目录（默认 `/opt/TG_download`，按回车使用默认值）。
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

---

## 管理菜单

运行 `sudo tgd` 进入交互式管理菜单：

```
1) 重新配置（全部参数）
2) 单独配置 TG API / Bot Token
3) 单独配置 TG 代理地址
4) 单独配置 TG User Session
5) 启动服务
6) 重启服务
7) 停止服务
8) 查看服务状态
9) 更新（拉取最新代码，保留配置）
10) 卸载
0) 退出
```

**选项 9 更新**：停止服务 → `git pull` 拉取最新代码 → 重装依赖 → 重启服务。会保留 `.env`、`*.session`、`downloads/`、`.venv/` 等用户数据，仅覆盖被跟踪的代码文件（`*.py` / `*.sh`）。

---

## Bot 命令

在 Telegram 中向 Bot 发送以下命令：

| 命令 | 说明 |
| --- | --- |
| `/start` | 查看帮助信息 |
| `/message <消息链接或评论链接>` | 归档单条消息 |
| `/channel <频道链接> [数量]` | 归档频道历史消息 |
| `/dir` | 下载目录管理（按钮交互：添加 / 删除 / 查看） |
| `/silent` | 静默下载模式（按钮交互：开启时选择下载目录） |
| `/default [别名]` | 查看或设置静默模式默认下载目录 |
| `/pause` | 暂停当前任务 |
| `/resume` | 恢复当前任务 |
| `/stop` | 停止当前任务 |

### `/channel` 下载范围

`/channel <频道链接>` 不带数量时，Bot 弹出按钮供你选择：

- **全部**：归档频道所有消息。
- **🔢 自定义范围**：先探测频道总消息数，再让你输入数字。支持两种格式：
  - **区间**（两个数字，从旧到新）：`1 5` 表示下载第 1~5 条（序号 `1` = 频道第一条 / 最旧，`N` = 最新一条）。
  - **单数字**：`7` 表示下载最新 7 条。
- `/channel <频道链接> 100` 直接带数量：归档最新 100 条。

### `/dir` 下载目录管理（按钮）

发送 `/dir` 弹出按钮菜单：

- **➕ 添加目录**：点击后按提示发送 `别名 路径`，例如 `disk1 /mnt/disk1/downloads`（路径须为绝对路径）。
- **🗑️ 删除目录**：点击要删除的目录别名。
- **📋 查看列表**：显示所有已配置别名（带 ⭐ 标记当前默认目录）。

> 也支持文本快捷方式：`/dir add <别名> <路径>`、`/dir del <别名>`、`/dir list`。

### `/silent` 静默模式（按钮）

发送 `/silent` 弹出按钮，显示当前状态（开启 / 关闭）：

- **开启**：进入目录选择，选定后该目录成为静默下载默认目录；之后下载不再逐次询问。若未配置任何目录会提示先 `/dir` 添加。
- **关闭**：下载时恢复逐次询问下载目录。

> 配置修改即时生效，无需重启服务。也支持 `/silent on` / `/silent off` 文本快捷方式。

### 链接使用示例

- 单条消息链接：`/message https://t.me/<channel>/<msg_id>`
- 评论链接：`/message https://t.me/<channel>/<msg_id>?thread=<thread_id>`
- 频道批量归档：`/channel https://t.me/<channel> 100`

### 使用提示

- 直接把**频道主消息**转发给 Bot，即可触发自动归档（保留来源信息）。
- 当存在多个下载目录别名且未开启静默模式时，Bot 会弹出按钮让你选择本次下载位置。
- 任一时刻**只能运行一个任务**，新任务需要等待当前任务结束或被 `/stop` 终止。
- 下载进度实时刷新：前 1 分钟每 2 秒一次，之后每 5 秒一次，长时间任务不会中断。

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

> 下列变量在 **Bot 运行后** 可由 `/dir`、`/silent`、`/default` 命令动态维护，无需手动编辑：
>
> - `DOWNLOAD_DIR_ALIASES`：以 `别名1=/path/1;别名2=/path/2` 形式存储目录别名。
> - `DEFAULT_DOWNLOAD_ALIAS`：静默模式默认下载目录别名。
> - `SILENT_DOWNLOAD_MODE`：`true` / `false`，控制下载时是否逐次询问目录。

---

## 归档目录结构

归档结果按 `<频道名>-<消息ID>` 分目录存放：

```text
downloads/
  channel_name-12345/
    README.md       # 消息正文 + 媒体说明
    meta.json       # 原始消息元数据
    main/           # 主消息里的图片 / 视频 / 文档（主消息无媒体时为空）
    comments/       # 评论区所有消息的媒体
```

> 当主消息只有文字、媒体全在评论区时，仍会创建目录并下载评论区资源（`main/` 为空）。

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
  多半是 User Session 失效或所在 IP 触发风控。可执行 `sudo tgd` → 选择「4) 单独配置 TG User Session」重新生成。

- **下载很慢 / 一直失败？**
  请检查 `TG_PROXY` 是否可用，或在 VPS 上确认没有被 Telegram 限速。可适当调小 `MAX_DOWNLOAD_WORKERS`。

- **下载到一半进度停止刷新？**
  已修复：进度刷新与下载解耦，前 1 分钟每 2 秒、之后每 5 秒刷新一次，长时间任务不会中断。如仍异常请用 `sudo tgd` → `9` 更新到最新代码。

- **`FileReferenceExpiredError` / 文件夹为空？**
  已修复：下载时自动刷新过期的 file_reference 重试，频道批量归档改用懒迭代避免引用过期。如仍异常请更新代码。

- **想让 Bot 静默工作？**
  发送 `/silent`，点「开启」并选择下载目录即可。之后下载直接到该目录，不再逐次询问。

- **怎么换下载盘？**
  发送 `/dir`，点「➕ 添加目录」，输入 `disk2 /mnt/disk2/downloads` 添加新别名；任务发起时选择，或 `/silent` 开启时设为默认。

- **怎么更新到最新版本？**
  `sudo tgd` → `9` 更新。会保留 `.env`、session、downloads，仅更新代码。

---

## 许可证

本项目仅供学习与个人使用，下载的内容版权归原作者所有，请勿用于非法用途。
