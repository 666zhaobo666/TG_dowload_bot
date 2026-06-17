#!/usr/bin/env bash
set -euo pipefail

APP_NAME="TG_dowload_bot"
SERVICE_NAME="tg-download-bot"
APP_USER="${SUDO_USER:-$USER}"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6 2>/dev/null || printf '%s' "$HOME")"
INSTALL_DIR_DEFAULT="${APP_HOME}/TG_download"
if [[ "$(id -u)" -eq 0 && "$APP_HOME" == /root* ]]; then
  INSTALL_DIR_DEFAULT="/opt/TG_download"
fi
SCRIPT_INSTALL_PATH="/usr/local/bin/tgd"
REPO_URL_OFFICIAL="https://github.com/666zhaobo666/TG_dowload_bot.git"
# 允许通过 TG_REPO_URL 环境变量覆盖默认 clone 源（例如内网镜像 / 私有 fork）。
# clone 失败时会自动回退到 GitHub 官方源，避免加速域名临时不可用导致安装卡死。
REPO_URL_DEFAULT="${TG_REPO_URL:-https://proxy.cccg.top/github.com/666zhaobo666/TG_dowload_bot.git}"

# 历史上 .env.example 里 TG_USER_SESSION 用过的占位符。
# 用于把旧部署里的「假 session」识别为「未配置」。
SESSION_PLACEHOLDERS=(
  "replace_with_your_string_session"
  "your_string_session"
  "REPLACE_ME"
)

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

log() { printf "%b[%s]%b %s\n" "$BLUE" "$APP_NAME" "$RESET" "$*"; }
warn() { printf "%b[%s]%b %s\n" "$YELLOW" "$APP_NAME" "$RESET" "$*"; }
err() { printf "%b[%s]%b %s\n" "$RED" "$APP_NAME" "$RESET" "$*" >&2; }
ok() { printf "%b[%s]%b %s\n" "$GREEN" "$APP_NAME" "$RESET" "$*"; }

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    err "该管理脚本仅支持 Linux 系统。"
    exit 1
  fi
}

run_as_root() {
  local run_user=""
  if [[ "${1:-}" == "-u" ]]; then
    run_user="$2"
    shift 2
  fi

  local current_user
  current_user="$(id -un 2>/dev/null || echo root)"

  if [[ -n "$run_user" && "$current_user" == "$run_user" ]]; then
    "$@"
  elif [[ -n "$run_user" ]]; then
    # -H 设 HOME，避免 sudo 抱怨；不重定向 stdin/stdout，让 sudo 透传 tty
    sudo -H -u "$run_user" "$@"
  elif [[ "$(id -u)" -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

# 探测「当前用户 sudo -H -u $target_user 是否能用」。
# 返回 0 = OK，非 0 = 不能用（requiretty / 缺 NOPASSWD 等）。
_probe_sudo_target_user() {
  local target_user="$1"
  local current_user
  current_user="$(id -un 2>/dev/null || echo root)"
  if [[ "$current_user" == "$target_user" ]]; then
    return 0
  fi
  # 用 sudo -n -H -u $target_user true：-n 防止 sudo 试图读密码
  if sudo -n -H -u "$target_user" true </dev/null >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# 在 install 流程里探测 sudo 配置并给出明确指引。
_check_sudo_for_target_user() {
  local target_user="$1"
  local current_user
  current_user="$(id -un 2>/dev/null || echo root)"
  if [[ "$current_user" == "$target_user" ]]; then
    return 0
  fi
  if _probe_sudo_target_user "$target_user"; then
    log "sudo 权限检测通过：可切换到 $target_user。"
    return 0
  fi

  warn "无法用 sudo 切换到 $target_user（可能 requiretty / 缺 NOPASSWD 规则）。"
  cat <<EOF >&2
后续管理脚本会用 sudo 把命令切换到 $target_user 用户执行（例如生成
TG_USER_SESSION）。如果 sudo 拒绝，生成 session 等交互流程会失败。

修复方法（任选其一）：
  1. 把当前用户加入 $target_user 组并配置 NOPASSWD：
     sudo visudo
     添加：$current_user ALL=($target_user) NOPASSWD: ALL

  2. 关闭 requiretty（如果 /etc/sudoers 里有的话）：
     sudo visudo
     注释掉：Defaults requiretty

  3. 直接以 $target_user 用户运行管理脚本（不要用 sudo ./）：
     su - $target_user -c 'curl ... | bash'

继续安装？[y/N]:
EOF
  local ans
  read -r ans
  if [[ "${ans,,}" != "y" ]]; then
    err "已取消。"
    exit 1
  fi
}

service_exists() {
  # 用 systemctl cat 精确判定 unit 是否存在，避免依赖 list-unit-files 的输出格式与 grep。
  systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1
}

install_dir() {
  if [[ -f "/etc/${SERVICE_NAME}.conf" ]]; then
    grep '^INSTALL_DIR=' "/etc/${SERVICE_NAME}.conf" | head -n1 | cut -d= -f2-
  else
    printf "%s" "$INSTALL_DIR_DEFAULT"
  fi
}

app_user() {
  if [[ -f "/etc/${SERVICE_NAME}.conf" ]]; then
    grep '^APP_USER=' "/etc/${SERVICE_NAME}.conf" | head -n1 | cut -d= -f2-
  else
    printf "%s" "$APP_USER"
  fi
}

app_group() {
  if [[ -f "/etc/${SERVICE_NAME}.conf" ]]; then
    grep '^APP_GROUP=' "/etc/${SERVICE_NAME}.conf" | head -n1 | cut -d= -f2-
  else
    id -gn "$APP_USER"
  fi
}

is_installed() {
  [[ -d "$(install_dir)" && -f "$(install_dir)/tg_archiver_bot.py" && -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]
}

ensure_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root apt-get install -y git curl python3 python3-venv
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y git curl python3 python3-venv
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y git curl python3 python3-venv
  else
    err "暂不支持当前包管理器，请手动安装 git、curl、python3 和 python3-venv。"
    exit 1
  fi
}

prompt_default() {
  local prompt="$1"
  local default="${2:-}"
  local secret="${3:-false}"
  local value

  if [[ "$secret" == "true" ]]; then
    read -r -s -p "${prompt} [${default}]: " value
    printf "\n"
  else
    read -r -p "${prompt} [${default}]: " value
    printf "\n"
  fi

  if [[ -z "$value" ]]; then
    value="$default"
  fi

  printf "%s" "$value"
}

normalize_linux_path() {
  local path="$1"

  path="${path//$'\r'/}"
  path="${path//$'\n'/}"
  path="$(printf '%s' "$path" | sed 's#//*#/#g')"

  if [[ -z "$path" || "$path" != /* ]]; then
    err "安装目录必须是 Linux 绝对路径，例如 /opt/TG_download 或 /home/<user>/TG_download。"
    exit 1
  fi

  if [[ "$path" != "/" ]]; then
    path="${path%/}"
  fi

  # 拦截危险路径：误把系统目录当安装目录会在后续 git clone 前 rm -rf 整个目录，
  # 造成灾难性删除。这里精确匹配系统/根目录本身；子目录（如 /opt/TG_download）放行。
  local _danger
  for _danger in / /bin /boot /dev /etc /lib /lib64 /proc /root /run /sbin /srv /sys /usr /var /home /opt /mnt /media /tmp; do
    if [[ "$path" == "$_danger" ]]; then
      err "拒绝使用系统/危险目录作为安装目录：$path"
      err "请指定一个专用子目录，例如 /opt/TG_download 或 /home/<user>/TG_download。"
      exit 1
    fi
  done

  printf "%s" "$path"
}

# 把识别为「占位符」的 session 值视为空（未配置）。
_normalize_session_value() {
  local raw="$1"
  for placeholder in "${SESSION_PLACEHOLDERS[@]}"; do
    if [[ "$raw" == "$placeholder" ]]; then
      printf ""
      return 0
    fi
  done
  printf "%s" "$raw"
}

# 调起 generate_string_session.py 交互式生成 TG_USER_SESSION。
# 通过 --output 让 python 把 session 写入文件，避免从 stdout 里 grep/tail 解析出错。
#
# stdin/stdout/stderr **不重定向**，直接连到当前 tty：
#   - python 的 prompt（手机号 / 验证码 / 2FA 密码）能直接显示给用户
#   - 用户的键盘输入能直接到达 python
#   - python 报错（连不上 / 风控 / 错误码）能直接显示
# 这样依赖 sudo -u 能正常透传 stdin/stdout（无 requiretty 时 OK）。
#
# 如果 sudo 因为 requiretty 失败，python 根本不会启动 —— 我们通过超时 + 检测
# session 文件是否被写入来识别这种情况并给用户明确提示。
generate_user_session() {
  local dir="$1"
  local api_id="$2"
  local api_hash="$3"
  local tg_proxy="${4:-}"
  local phone="${5:-}"

  # 局部 override log/ok，让它们在本函数内输出到 stderr（不污染 stdout 捕获）
  local _log_save _ok_save
  _log_save="$(declare -f log)"
  _ok_save="$(declare -f ok)"
  eval "log() { printf '%b[%s]%b %s\n' \"\$BLUE\" \"\$APP_NAME\" \"\$RESET\" \"\$*\" >&2; }"
  eval "ok() { printf '%b[%s]%b %s\n' \"\$GREEN\" \"\$APP_NAME\" \"\$RESET\" \"\$*\" >&2; }"
  trap 'eval "$_log_save"; eval "$_ok_save"; trap - RETURN' RETURN

  if [[ -z "$api_id" || -z "$api_hash" ]]; then
    err "生成 TG_USER_SESSION 需要先填写 TG_API_ID 和 TG_API_HASH。"
    return 1
  fi

  local out_file
  out_file="$(mktemp)"
  chmod 600 "$out_file"

  log "正在生成 TG_USER_SESSION，接下来会提示输入手机号和验证码。"
  if [[ -n "$phone" ]]; then
    log "（已记录手机号 $phone；脚本仍会要求你输入 Telegram 验证码 / 2FA 密码）"
  fi

  # 关键：不重定向 stdin/stdout/stderr，让 python 直接和用户交互。
  # session 通过 --output 传递，stderr/stdout 上是 python 的交互 prompt + 日志。
  local exit_code=0
  TG_API_ID="$api_id" \
  TG_API_HASH="$api_hash" \
  TG_PROXY="$tg_proxy" \
  TG_PHONE="$phone" \
    run_as_root -u "$APP_USER" "${dir}/.venv/bin/python" "${dir}/generate_string_session.py" \
      --output "$out_file" \
    || exit_code=$?

  # 函数结束：把 log/ok 恢复回去（在 trap RETURN 里已经做了，但 trap 只在
  # 函数 return 时触发；这里我们手动恢复一次以防 trap 没注册成功）
  eval "$_log_save" >/dev/null 2>&1 || true
  eval "$_ok_save" >/dev/null 2>&1 || true

  if [[ "$exit_code" -ne 0 ]]; then
    err "TG_USER_SESSION 生成失败（python 退出码 $exit_code）。"
    cat <<EOF >&2
常见原因：
  - sudo 配置不允许无密码切换到 $APP_USER（需要 requiretty / 缺免密规则）。
    解决：sudo visudo 添加一行
      $APP_USER ALL=(ALL) NOPASSWD: ALL
    或者把当前用户加入 sudo 组并启用 NOPASSWD。
  - 网络问题或代理不可达：请检查 TG_PROXY 配置；telethon 默认 2 次重试 × 10s。
  - 手机号格式不对（需要国际格式，例如 +8613800138000）。
  - Telegram 风控：同一时间同一账号最多 10 个活跃 session。
    请到 Telegram 客户端 → Settings → Devices → Terminate Other Sessions
    关掉不用的设备后再试。
EOF
    rm -f "$out_file"
    return 1
  fi

  if [[ ! -s "$out_file" ]]; then
    err "TG_USER_SESSION 生成失败：python 没有写入 session 文件。"
    cat <<EOF >&2
可能原因：python 提前退出而没有把 session 写入文件。
请检查上面的 python 输出（手机号 / 验证码 / 网络错误等）。
EOF
    rm -f "$out_file"
    return 1
  fi

  local session
  session="$(tr -d '[:space:]' < "$out_file")"
  rm -f "$out_file"

  if [[ -z "$session" ]]; then
    err "TG_USER_SESSION 生成失败：session 文件为空。"
    return 1
  fi

  ok "TG_USER_SESSION 生成成功。"
  # 关键：只用 stdout 写 session 字符串本身。装饰信息全部走 stderr。
  printf "%s" "$session"
  return 0
}

parse_alias_paths() {
  local raw="$1"
  local result=""

  IFS=';' read -r -a entries <<< "$raw"
  for entry in "${entries[@]}"; do
    entry="$(printf '%s' "$entry" | xargs)"
    [[ -z "$entry" ]] && continue

    if [[ "$entry" != *=* ]]; then
      err "目录别名格式无效：$entry"
      exit 1
    fi

    local alias_name="${entry%%=*}"
    local alias_path="${entry#*=}"
    alias_name="$(printf '%s' "$alias_name" | xargs)"
    alias_path="$(printf '%s' "$alias_path" | xargs)"

    if [[ ! "$alias_path" = /* ]]; then
      err "目录别名 '$alias_name' 对应的路径必须是 Linux 绝对路径。"
      exit 1
    fi

    result+="${alias_name}=${alias_path};"
  done

  printf "%s" "${result%;}"
}

write_service_conf() {
  local dir="$1"
  local user="$2"
  local group="$3"

  run_as_root tee "/etc/${SERVICE_NAME}.conf" >/dev/null <<EOF
INSTALL_DIR=${dir}
APP_USER=${user}
APP_GROUP=${group}
EOF
}

write_service_file() {
  local dir="$1"
  local user="$2"
  local group="$3"

  run_as_root tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=Telegram Download Bot
After=network.target

[Service]
Type=simple
User=${user}
Group=${group}
WorkingDirectory=${dir}
Environment=PYTHONUNBUFFERED=1
ExecStart="${dir}/.venv/bin/python" "${dir}/tg_archiver_bot.py"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  run_as_root systemctl daemon-reload
}

install_command_entry() {
  local dir="$1"

  run_as_root tee "$SCRIPT_INSTALL_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
cd "${dir}"
exec "${dir}/TG_dowload.sh" "\$@"
EOF

  run_as_root chmod +x "$SCRIPT_INSTALL_PATH"
}

# 确保安装目录里的管理脚本本身可执行。git clone 出来的文件权限遵循
# 服务器的 umask，不一定是 755。如果用户用 `sudo tgd` 走软链访问到这里，
# 缺了 +x 会报 "Permission denied"。
ensure_install_script_executable() {
  local dir="$1"
  local script="${dir}/TG_dowload.sh"
  if [[ -f "$script" ]]; then
    run_as_root chmod +x "$script"
  fi
}

# 拿到用户跑这次安装时所在的工作目录（用来在 install 成功后清理掉
# 当前目录下的临时 TG_dowload.sh）。记录到全局给 install_app 末尾用。
_INSTALL_CWD=""
_capture_install_cwd() {
  _INSTALL_CWD="$(pwd -P 2>/dev/null || pwd)"
}
_cleanup_install_cwd_script() {
  if [[ -n "$_INSTALL_CWD" && "$_INSTALL_CWD" != "$(install_dir)" ]]; then
    local tmp_script="${_INSTALL_CWD}/TG_dowload.sh"
    if [[ -f "$tmp_script" ]]; then
      run_as_root rm -f "$tmp_script" && log "已清理临时脚本：$tmp_script"
    fi
  fi
}

ensure_owner() {
  local dir="$1"
  local user="$2"
  local group="$3"
  run_as_root chown -R "${user}:${group}" "$dir"
}

check_exec_mount() {
  local dir="$1"
  if command -v findmnt >/dev/null 2>&1; then
    local opts
    opts="$(findmnt -no OPTIONS -T "$dir" 2>/dev/null || true)"
    if [[ "$opts" == *noexec* ]]; then
      err "${dir} 所在文件系统使用了 noexec 挂载选项。"
      err "虚拟环境里的可执行文件无法运行，请改装到可执行目录，例如 /home/<user>/TG_download。"
      exit 1
    fi
  fi
}

setup_venv() {
  local dir="$1"
  local user="$2"
  local venv_python="${dir}/.venv/bin/python"

  check_exec_mount "$dir"
  run_as_root -u "$user" python3 -m venv "${dir}/.venv"

  if [[ ! -x "$venv_python" ]]; then
    err "虚拟环境 Python 不可执行：${venv_python}"
    err "请检查目录权限，或确认安装路径是否被 noexec 挂载。"
    exit 1
  fi

  run_as_root -u "$user" "$venv_python" -m pip install --upgrade pip
  run_as_root -u "$user" "$venv_python" -m pip install -r "${dir}/requirements.txt"
}

# 读取 .env 中现有字段的辅助函数。返回的第一个值为字段值（可能为空），
# 第二个值为「是否在文件中存在」。处理占位符：所有 SESSION_PLACEHOLDERS
# 视为未配置。
_read_env_field() {
  local existing="$1"
  local key="$2"
  local raw=""
  if [[ -f "$existing" ]]; then
    raw="$(grep "^${key}=" "$existing" | cut -d= -f2- || true)"
  fi
  if [[ "$key" == "TG_USER_SESSION" ]]; then
    raw="$(_normalize_session_value "$raw")"
  fi
  printf "%s\n%s" "$raw" "$([[ -n "$raw" ]] && echo 1 || echo 0)"
}

# 完整重配：API / Bot / Proxy / Session / 并发数 全部走一遍。
# 这是 install_app 第一次跑的入口；manage menu 的「重新配置」也走它。
configure_env() {
  local dir="$1"
  local existing="${dir}/.env"
  local defaults_file="${dir}/.env.example"

  if [[ ! -f "$existing" && -f "$defaults_file" ]]; then
    cp "$defaults_file" "$existing"
  fi

  # 读现有值
  local _e _has
  _e="$(_read_env_field "$existing" TG_API_ID)"; local cur_api_id="${_e%%$'\n'*}"; _has="${_e##*$'\n'}"
  _e="$(_read_env_field "$existing" TG_API_HASH)"; local cur_api_hash="${_e%%$'\n'*}"; _has="${_e##*$'\n'}"
  _e="$(_read_env_field "$existing" TG_BOT_TOKEN)"; local cur_bot_token="${_e%%$'\n'*}"; _has="${_e##*$'\n'}"
  _e="$(_read_env_field "$existing" TG_USER_SESSION)"; local cur_session="${_e%%$'\n'*}"; _has="${_e##*$'\n'}"
  _e="$(_read_env_field "$existing" TG_PROXY)"; local cur_proxy="${_e%%$'\n'*}"; _has="${_e##*$'\n'}"
  _e="$(_read_env_field "$existing" MAX_DOWNLOAD_WORKERS)"; local cur_workers="${_e%%$'\n'*}"; _has="${_e##*$'\n'}"

  # 历史占位符识别
  [[ "$cur_api_id" == "123456" ]] && cur_api_id=""
  [[ "$cur_api_hash" == "your_api_hash" ]] && cur_api_hash=""
  [[ "$cur_bot_token" == "123456:your_bot_token" ]] && cur_bot_token=""
  [[ "$cur_proxy" == "socks5://127.0.0.1:10808" ]] && cur_proxy=""
  cur_workers="${cur_workers:-5}"

  log "开始配置 Telegram Bot 参数。"
  echo ""

  local api_id_val api_hash_val bot_token_val proxy_val workers_val
  api_id_val="$(prompt_default '请输入 TG API ID' "$cur_api_id")"
  echo ""
  api_hash_val="$(prompt_default '请输入 TG API HASH' "$cur_api_hash" true)"
  echo ""
  bot_token_val="$(prompt_default '请输入 TG Bot Token' "$cur_bot_token" true)"
  echo ""
  # 代理地址：用户首次填时给个明确提示，避免国内直连卡住
  if [[ -z "$cur_proxy" ]]; then
    warn "如果机器不在中国大陆，且能直连 telegram.org，可以直接回车跳过代理。"
    warn "否则请填写 socks5/http 代理地址，例如 socks5://127.0.0.1:10808"
  fi
  proxy_val="$(prompt_default '请输入 TG 代理地址（可选）' "$cur_proxy")"
  echo ""
  workers_val="$(prompt_default '请输入最大下载并发数（1-10）' "$cur_workers")"
  workers_val="${workers_val:-5}"
  echo ""

  local session_val
  session_val="$(update_session_prompt "$dir" "$existing" "$cur_session" "$api_id_val" "$api_hash_val" "$proxy_val" "configure")"

  echo ""
  _set_env_var "$existing" "TG_API_ID" "$api_id_val"
  _set_env_var "$existing" "TG_API_HASH" "$api_hash_val"
  _set_env_var "$existing" "TG_BOT_TOKEN" "$bot_token_val"
  _set_env_var "$existing" "TG_PROXY" "$proxy_val"
  _set_env_var "$existing" "MAX_DOWNLOAD_WORKERS" "$workers_val"
  _set_env_var "$existing" "TG_USER_SESSION" "$session_val"
  ok "配置已保存到 ${existing}"
}

# 只改 TG_USER_SESSION 的交互流程。
# 复用 update_session_prompt 的选项菜单，但不带「完整重配」入口。
update_session_only() {
  local dir="$1"
  local existing="${dir}/.env"

  local _e cur_session cur_api_id cur_api_hash cur_proxy
  _e="$(_read_env_field "$existing" TG_USER_SESSION)"; cur_session="${_e%%$'\n'*}"
  _e="$(_read_env_field "$existing" TG_API_ID)"; cur_api_id="${_e%%$'\n'*}"
  _e="$(_read_env_field "$existing" TG_API_HASH)"; cur_api_hash="${_e%%$'\n'*}"
  _e="$(_read_env_field "$existing" TG_PROXY)"; cur_proxy="${_e%%$'\n'*}"

  if [[ -z "$cur_api_id" || -z "$cur_api_hash" ]]; then
    err "生成 TG_USER_SESSION 前，必须先填写 TG API ID 和 TG API HASH。"
    err "请先通过「重新配置」或「单独配置 API / Bot Token」菜单把它们写好。"
    return 1
  fi

  local session_val
  session_val="$(update_session_prompt "$dir" "$existing" "$cur_session" "$cur_api_id" "$cur_api_hash" "$cur_proxy" "session_only")"

  _set_env_var "$existing" "TG_USER_SESSION" "$session_val"
  ok "TG_USER_SESSION 已更新。"
}

# 只改 TG_PROXY 的交互流程。
update_proxy_only() {
  local dir="$1"
  local existing="${dir}/.env"

  local _e cur_proxy
  _e="$(_read_env_field "$existing" TG_PROXY)"; cur_proxy="${_e%%$'\n'*}"

  echo ""
  log "当前 TG_PROXY：${cur_proxy:-（未配置）}"
  local proxy_val
  proxy_val="$(prompt_default '请输入新的 TG 代理地址（留空表示直连）' "$cur_proxy")"
  echo ""

  _set_env_var "$existing" "TG_PROXY" "$proxy_val"
  ok "TG_PROXY 已更新。"
}

# 只改 TG API / Bot Token 的交互流程。
update_api_only() {
  local dir="$1"
  local existing="${dir}/.env"

  local _e cur_api_id cur_api_hash cur_bot_token
  _e="$(_read_env_field "$existing" TG_API_ID)"; cur_api_id="${_e%%$'\n'*}"
  _e="$(_read_env_field "$existing" TG_API_HASH)"; cur_api_hash="${_e%%$'\n'*}"
  _e="$(_read_env_field "$existing" TG_BOT_TOKEN)"; cur_bot_token="${_e%%$'\n'*}"

  echo ""
  log "当前 TG API ID：${cur_api_id:-（未配置）}"
  log "当前 TG API HASH：${cur_api_hash:0:6}…（已脱敏）"
  log "当前 TG BOT TOKEN：${cur_bot_token:0:8}…（已脱敏）"
  echo ""

  local api_id_val api_hash_val bot_token_val
  api_id_val="$(prompt_default '请输入新的 TG API ID（留空保持）' "$cur_api_id")"
  echo ""
  api_hash_val="$(prompt_default '请输入新的 TG API HASH（留空保持）' "$cur_api_hash" true)"
  echo ""
  bot_token_val="$(prompt_default '请输入新的 TG Bot Token（留空保持）' "$cur_bot_token" true)"
  echo ""

  _set_env_var "$existing" "TG_API_ID" "$api_id_val"
  _set_env_var "$existing" "TG_API_HASH" "$api_hash_val"
  _set_env_var "$existing" "TG_BOT_TOKEN" "$bot_token_val"
  ok "TG API / Bot Token 已更新。"
}

# Session 配置菜单（被 configure_env 和 update_session_only 共用）。
# 第 5 个参数是调用上下文："configure" 或 "session_only"，影响菜单文案。
#
# 重要：本函数的所有提示信息走 stderr，只让最后的 session_val 走 stdout，
# 否则调用方 `$(update_session_prompt ...)` 会把所有菜单文字当 session 捕获。
update_session_prompt() {
  local dir="$1"
  local existing="$2"          # 当前 .env 文件路径（保留参数以便将来扩展）
  local cur_session="$3"
  local api_id_val="$4"
  local api_hash_val="$5"
  local proxy_val="$6"
  local ctx="${7:-configure}"  # configure | session_only

  # 局部 override：log/ok 在函数内重定向到 stderr；warn/err 本来就走 stderr
  local _log_save _ok_save
  _log_save="$(declare -f log)"
  _ok_save="$(declare -f ok)"
  eval "log() { printf '%b[%s]%b %s\n' \"\$BLUE\" \"\$APP_NAME\" \"\$RESET\" \"\$*\" >&2; }"
  eval "ok() { printf '%b[%s]%b %s\n' \"\$GREEN\" \"\$APP_NAME\" \"\$RESET\" \"\$*\" >&2; }"
  trap 'eval "$_log_save"; eval "$_ok_save"; trap - RETURN' RETURN

  local session_val="$cur_session"

  # 一次性判定当前 session 状态，后续所有逻辑都引用这个变量，避免边界 case
  # 下「当前状态」和「菜单选项」不一致（比如某些环境 trim 行为差异）。
  local has_session=0
  if [[ -n "$cur_session" ]]; then
    has_session=1
  fi

  printf "\n" >&2
  printf "TG User Session：\n" >&2
  if [[ "$has_session" == "1" ]]; then
    local masked="${cur_session:0:6}…${cur_session: -4}"
    printf "  当前状态：已配置  当前值：%s\n" "$masked" >&2
  else
    printf "  当前状态：未配置\n" >&2
  fi

  local default_choice
  if [[ "$has_session" == "1" ]]; then
    printf "  1) 重新生成 Session\n" >&2
    printf "  2) 保持当前 Session\n" >&2
    printf "  3) 清空 Session（删除当前值，需要重新生成才能继续使用 Bot）\n" >&2
    default_choice="2"
  else
    printf "  1) 现在生成 Session\n" >&2
    default_choice="1"
  fi

  local prompt_text="请选择 [$default_choice]: "
  local sess_choice
  printf "%s" "$prompt_text" >&2
  read -r sess_choice
  sess_choice="${sess_choice:-$default_choice}"

  case "$sess_choice" in
    1)
      if [[ -z "$api_id_val" || -z "$api_hash_val" ]]; then
        err "生成 TG_USER_SESSION 前，必须先填写 TG API ID 和 TG API HASH。"
      else
        session_val="$(generate_user_session "$dir" "$api_id_val" "$api_hash_val" "$proxy_val" "")"
      fi
      ;;
    2)
      : # 保持
      ;;
    3)
      if [[ -n "$cur_session" ]]; then
        session_val=""
        warn "已清空 TG_USER_SESSION，下次启动 Bot 之前需要重新生成。"
      else
        warn "当前 Session 本来就是空的，无需清空。"
      fi
      ;;
    *)
      err "无效选项，保持当前 Session。"
      ;;
  esac

  # 关键：只有 session_val 本身走 stdout
  printf "%s" "$session_val"
}

# 把 KEY=VAL 写入 .env 文件。允许 val 为空字符串（清空该键）。
# val 为空时：键存在 → 写成 KEY=；键不存在 → 不写。
# val 不为空时：键存在 → 更新；键不存在 → 追加。
_set_env_var() {
  local existing="$1"
  local key="$2"
  local val="$3"

  local tmpfile
  tmpfile="$(mktemp)"
  local found=0

  if [[ -f "$existing" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^${key}= ]]; then
        if [[ -n "$val" ]]; then
          echo "${key}=${val}" >> "$tmpfile"
        fi
        # val 为空时整行删除
        found=1
      else
        echo "$line" >> "$tmpfile"
      fi
    done < "$existing"
  fi

  if [[ "$found" == "0" && -n "$val" ]]; then
    echo "${key}=${val}" >> "$tmpfile"
  fi

  run_as_root mv "$tmpfile" "$existing"
}

# 给 install_app 用的 .env 预填充：clone 之后 configure_env 之前调用。
# 目的：清掉 .env.example 中可能的占位符（虽然现在已经是空字符串，但保险起见）。
# 同时把 .env 文件权限收紧到 600。
_strip_env_placeholders() {
  local existing="$1"
  [[ -f "$existing" ]] || return 0

  local tmpfile
  tmpfile="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    local stripped="${line#*=}"
    local is_placeholder=0
    for placeholder in "${SESSION_PLACEHOLDERS[@]}"; do
      if [[ -n "$stripped" && "$stripped" == "$placeholder" ]]; then
        is_placeholder=1
        break
      fi
    done
    if [[ "$is_placeholder" == "1" ]]; then
      echo "${line%%=*}=" >> "$tmpfile"
    else
      echo "$line" >> "$tmpfile"
    fi
  done < "$existing"

  run_as_root mv "$tmpfile" "$existing"
  run_as_root chmod 600 "$existing"
}

# clone 仓库，失败时回退到 GitHub 官方源，避免加速域名临时不可用导致安装卡死。
# 优先用传入的 url（默认加速镜像 / TG_REPO_URL 覆盖值）；失败且非官方源时回退。
clone_repo() {
  local url="$1"
  local dest="$2"
  local user="$3"
  if run_as_root -u "$user" git clone "$url" "$dest"; then
    return 0
  fi
  if [[ "$url" != "$REPO_URL_OFFICIAL" ]]; then
    warn "克隆失败（$url），回退到 GitHub 官方源重试..."
    run_as_root -u "$user" git clone "$REPO_URL_OFFICIAL" "$dest"
    return $?
  fi
  return 1
}

install_app() {
  require_linux
  ensure_packages
  _capture_install_cwd

  local target_dir target_user target_group repo_url
  target_user="$APP_USER"
  target_group="$(id -gn "$target_user")"

  # 探测 sudo 配置：后续脚本会用 sudo 切换到 $target_user 执行敏感命令
  _check_sudo_for_target_user "$target_user"
  target_dir="$(prompt_default '安装目录' "$INSTALL_DIR_DEFAULT")"
  target_dir="$(normalize_linux_path "$target_dir")"
  repo_url="$REPO_URL_DEFAULT"

  echo ""
  log "安装目录：$target_dir"
  run_as_root mkdir -p "$target_dir"

  if [[ -d "${target_dir}/.git" ]]; then
    run_as_root -u "$target_user" git -C "$target_dir" pull --ff-only
  else
    # rm -rf 前已有 normalize_linux_path 拦截系统/危险目录；这里再做一次存在性确认。
    if [[ -e "$target_dir" ]]; then
      run_as_root rm -rf "$target_dir"
    fi
    clone_repo "$repo_url" "$target_dir" "$target_user"
  fi

  write_service_conf "$target_dir" "$target_user" "$target_group"
  setup_venv "$target_dir" "$target_user"

  # 让 .env 先具备正确权限 + 清理掉残留占位符，然后才让用户交互
  if [[ -f "${target_dir}/.env" ]]; then
    run_as_root chmod 600 "${target_dir}/.env"
    _strip_env_placeholders "${target_dir}/.env"
  fi

  # 设置 trap：用户在交互式 prompt 时 Ctrl+C，至少保证 tgd 命令可用，
  # 这样用户可以重新跑 `sudo tgd` 继续配置。
  _install_post_trap_setup "$target_dir" "$target_user" "$target_group"
  trap '_install_on_interrupt "$target_dir" "$target_user" "$target_group"' INT TERM
  configure_env "$target_dir" || true
  trap - INT TERM

  ensure_owner "$target_dir" "$target_user" "$target_group"
  ensure_install_script_executable "$target_dir"
  write_service_file "$target_dir" "$target_user" "$target_group"
  install_command_entry "$target_dir"
  run_as_root systemctl enable --now "${SERVICE_NAME}.service" 2>/dev/null || true

  # 清理当前目录下临时跑的 TG_dowload.sh
  _cleanup_install_cwd_script

  ok "安装完成，服务已启动。"
  ok "后续可使用 'sudo tgd' 进行管理。"
}

# install_app 中途 Ctrl+C 时调用：保证 tgd 软链和 systemd unit 已就位，
# 即便用户没填完配置项也能用 `sudo tgd` 继续操作。
_install_post_trap_setup() {
  local dir="$1"
  local user="$2"
  local group="$3"
  ensure_install_script_executable "$dir"
  install_command_entry "$dir"
}

_install_on_interrupt() {
  local dir="$1"
  local user="$2"
  local group="$3"
  warn "安装被中断。正在确保管理命令可用..."
  ensure_owner "$dir" "$user" "$group" 2>/dev/null || true
  ensure_install_script_executable "$dir"
  write_service_file "$dir" "$user" "$group" 2>/dev/null || true
  install_command_entry "$dir"
  _cleanup_install_cwd_script
  ok "管理命令已就绪：sudo tgd"
  ok "继续配置请运行：sudo tgd → 重新配置"
  exit 130
}

reconfigure_app() {
  local dir
  dir="$(install_dir)"

  configure_env "$dir"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "配置已更新，服务已重启。"
}

# 单独配置 Session（不动 API / Bot / Proxy / 并发数）
update_session_menu() {
  local dir
  dir="$(install_dir)"

  update_session_only "$dir" || return 0
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "Session 已更新，服务已重启。"
}

# 单独配置 Proxy（不改其他）
update_proxy_menu() {
  local dir
  dir="$(install_dir)"

  update_proxy_only "$dir" || return 0
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "代理已更新，服务已重启。"
}

# 单独配置 API / Bot Token（不改 Proxy / Session / 并发数）
update_api_menu() {
  local dir
  dir="$(install_dir)"

  update_api_only "$dir" || return 0
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "API / Bot Token 已更新，服务已重启。"
}

start_service() {
  run_as_root systemctl start "${SERVICE_NAME}.service"
  ok "服务已启动。"
}

restart_service() {
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "服务已重启。"
}

stop_service() {
  run_as_root systemctl stop "${SERVICE_NAME}.service"
  ok "服务已停止。"
}

status_service() {
  run_as_root systemctl status "${SERVICE_NAME}.service" --no-pager
}

# 计算目录占用大小（人类可读）
_dir_size() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    printf "不存在"
    return 0
  fi
  if command -v du >/dev/null 2>&1; then
    du -sh "$path" 2>/dev/null | awk '{print $1}'
  else
    printf "未知"
  fi
}

# 列出将要被卸载清理的项，方便用户确认
_preview_uninstall() {
  local dir="$1"
  local purge="$2"

  echo "即将清理以下内容："
  if service_exists; then
    echo "  - systemd 单元：/etc/systemd/system/${SERVICE_NAME}.service"
    echo "  - 配置文件  ：/etc/${SERVICE_NAME}.conf"
  fi
  if [[ -e "$SCRIPT_INSTALL_PATH" ]]; then
    echo "  - 命令别名  ：$SCRIPT_INSTALL_PATH"
  fi
  if [[ -d "$dir" ]]; then
    echo "  - 安装目录  ：$dir （$(_dir_size "$dir")）"
    echo "      └─ 代码 / 配置 / 虚拟环境 / systemd 单元备份"
    local downloads_dir="${dir}/downloads"
    if [[ -d "$downloads_dir" ]]; then
      echo "      └─ 归档数据：${downloads_dir} （$(_dir_size "$downloads_dir")）"
    fi
  fi

  # APP_USER home 下的 telethon 缓存
  local home_dir
  home_dir="$(getent passwd "$APP_USER" | cut -d: -f6 2>/dev/null || true)"
  if [[ -n "$home_dir" ]]; then
    local cache_paths=(
      "${home_dir}/.cache/Telethon"
      "${home_dir}/.cache/Telethon.db"
      "${home_dir}/.local/share/Telegram"
      "${home_dir}/.local/lib/Telegram"
    )
    for p in "${cache_paths[@]}"; do
      if [[ -e "$p" ]]; then
        echo "  - 残留缓存  ：$p"
      fi
    done
  fi

  # systemd preset / drop-in（一般是空的，但清理一下更干净）
  local drop_in_dir="/etc/systemd/system/${SERVICE_NAME}.service.d"
  if [[ -d "$drop_in_dir" ]]; then
    echo "  - systemd drop-in：${drop_in_dir}"
  fi
  if [[ -e "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service" ]]; then
    echo "  - systemd 启用链接：/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service"
  fi

  if [[ "$purge" == "1" ]]; then
    echo ""
    warn "--purge 模式：归档数据 downloads/ 也会一并删除，下载过的内容不可恢复。"
  fi
}

_remove_path() {
  local label="$1"
  local path="$2"
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if run_as_root rm -rf "$path" 2>/dev/null; then
    log "已删除 $label：$path"
  else
    warn "删除失败 $label：$path（可能需要手动处理）"
  fi
}

_remove_file() {
  local label="$1"
  local path="$2"
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if run_as_root rm -f "$path" 2>/dev/null; then
    log "已删除 $label：$path"
  else
    warn "删除失败 $label：$path"
  fi
}

uninstall_app() {
  local purge="0"
  for arg in "$@"; do
    case "$arg" in
      --purge) purge="1" ;;
      --help|-h)
        cat <<EOF
用法: tgd uninstall [--purge]

默认仅删除服务、配置、命令别名和安装目录；
保留 \${INSTALL_DIR}/downloads 下的归档数据。

--purge      同时删除 downloads/ 下的所有归档内容。
EOF
        exit 0
        ;;
    esac
  done

  local dir
  dir="$(install_dir)"

  _preview_uninstall "$dir" "$purge"
  echo ""
  read -r -p "确认继续卸载？[y/N]: " confirm
  [[ "${confirm,,}" == "y" ]] || { warn "已取消。"; exit 0; }

  # 1. 停服务 + 取消开机自启
  if service_exists; then
    run_as_root systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    _remove_file "systemd 单元" "/etc/systemd/system/${SERVICE_NAME}.service"
    _remove_file "systemd 启用链接" "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service"
    _remove_path "systemd drop-in" "/etc/systemd/system/${SERVICE_NAME}.service.d"
    _remove_file "服务配置" "/etc/${SERVICE_NAME}.conf"
    run_as_root systemctl daemon-reload 2>/dev/null || true
    run_as_root systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
  fi

  # 2. 删除命令别名
  _remove_file "命令别名" "$SCRIPT_INSTALL_PATH"

  # 3. 处理安装目录：默认保留 downloads/，--purge 全删
  if [[ -d "$dir" ]]; then
    if [[ "$purge" == "1" ]]; then
      _remove_path "安装目录（含归档数据）" "$dir"
    else
      # 把 downloads/ 临时挪出来
      local downloads_dir="${dir}/downloads"
      local stash_dir
      stash_dir="$(mktemp -d -t tg_download_backup.XXXXXX)"
      if [[ -d "$downloads_dir" ]]; then
        log "保留归档数据：把 ${downloads_dir} 临时挪到 ${stash_dir}/downloads"
        run_as_root mv "$downloads_dir" "${stash_dir}/downloads" || true
      fi
      _remove_path "安装目录" "$dir"
      # 把目录重建出来 + 把 downloads/ 放回去，告知用户位置
      run_as_root mkdir -p "$dir"
      if [[ -d "${stash_dir}/downloads" ]]; then
        run_as_root mv "${stash_dir}/downloads" "${dir}/downloads"
        ok "归档数据已保留在 ${dir}/downloads。"
        ok "如确认不再需要，可执行: sudo tgd uninstall --purge"
      fi
      rmdir "$stash_dir" 2>/dev/null || true
    fi
  fi

  # 4. APP_USER home 下的 telethon 缓存
  local home_dir
  home_dir="$(getent passwd "$APP_USER" | cut -d: -f6 2>/dev/null || true)"
  if [[ -n "$home_dir" ]]; then
    _remove_path "Telethon 缓存" "${home_dir}/.cache/Telethon"
    _remove_path "Telethon 缓存文件" "${home_dir}/.cache/Telethon.db"
    _remove_path "Telegram 数据" "${home_dir}/.local/share/Telegram"
    _remove_path "Telegram 库" "${home_dir}/.local/lib/Telegram"
  fi

  ok "卸载完成。"
  echo ""
  echo "提示：之前用此 User Session 登录的 Telegram 设备仍会保留在账号里。"
  echo "      如需清除，请到 Telegram 客户端 → Settings → Devices → Terminate Other Sessions。"
}

show_install_menu() {
  echo "1) 安装"
  echo "0) 退出"
  read -r -p "请选择： " choice

  case "$choice" in
    1) install_app ;;
    0) exit 0 ;;
    *) err "无效选项。"; exit 1 ;;
  esac
}

show_manage_menu() {
  echo "1) 重新配置（全部参数）"
  echo "2) 单独配置 TG API / Bot Token"
  echo "3) 单独配置 TG 代理地址"
  echo "4) 单独配置 TG User Session"
  echo "5) 启动服务"
  echo "6) 重启服务"
  echo "7) 停止服务"
  echo "8) 查看服务状态"
  echo "9) 卸载"
  echo "0) 退出"
  read -r -p "请选择： " choice

  case "$choice" in
    1) reconfigure_app ;;
    2) update_api_menu ;;
    3) update_proxy_menu ;;
    4) update_session_menu ;;
    5) start_service ;;
    6) restart_service ;;
    7) stop_service ;;
    8) status_service ;;
    9) uninstall_app ;;
    0) exit 0 ;;
    *) err "无效选项。"; exit 1 ;;
  esac
}

main() {
  require_linux
  if is_installed; then
    show_manage_menu
  else
    show_install_menu
  fi
}

main "$@"