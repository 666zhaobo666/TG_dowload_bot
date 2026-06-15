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
REPO_URL_DEFAULT="https://proxy.cccg.top/github.com/666zhaobo666/TG_dowload_bot.git"

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
    sudo -u "$run_user" "$@"
  elif [[ "$(id -u)" -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

service_exists() {
  systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"
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

generate_user_session() {
  local dir="$1"
  local api_id="$2"
  local api_hash="$3"
  local tg_proxy="${4:-}"

  if [[ -z "$api_id" || -z "$api_hash" ]]; then
    err "生成 TG_USER_SESSION 需要先填写 TG_API_ID 和 TG_API_HASH。"
    return 1
  fi

  log "正在生成 TG_USER_SESSION，接下来会提示输入手机号和验证码。"
  local tmpfile
  tmpfile="$(mktemp)"

  TG_API_ID="$api_id" TG_API_HASH="$api_hash" TG_PROXY="$tg_proxy" \
    run_as_root -u "$APP_USER" python3 "${dir}/generate_string_session.py" 2>&1 | tee "$tmpfile" >/dev/null || true

  local session
  session="$(grep -v '^Put the following' "$tmpfile" | tail -n1 | tr -d '[:space:]')"
  rm -f "$tmpfile"

  if [[ -n "$session" ]]; then
    ok "TG_USER_SESSION 生成成功。"
    printf "%s" "$session"
    return 0
  fi

  err "TG_USER_SESSION 生成失败。"
  return 1
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

configure_env() {
  local dir="$1"
  local existing="${dir}/.env"
  local defaults_file="${dir}/.env.example"

  if [[ ! -f "$existing" && -f "$defaults_file" ]]; then
    cp "$defaults_file" "$existing"
  fi

  local cur_api_id cur_api_hash cur_bot_token cur_session cur_proxy cur_workers
  cur_api_id="$(grep '^TG_API_ID=' "$existing" | cut -d= -f2- || true)"
  cur_api_hash="$(grep '^TG_API_HASH=' "$existing" | cut -d= -f2- || true)"
  cur_bot_token="$(grep '^TG_BOT_TOKEN=' "$existing" | cut -d= -f2- || true)"
  cur_session="$(grep '^TG_USER_SESSION=' "$existing" | cut -d= -f2- || true)"
  cur_proxy="$(grep '^TG_PROXY=' "$existing" | cut -d= -f2- || true)"
  cur_workers="$(grep '^MAX_DOWNLOAD_WORKERS=' "$existing" | cut -d= -f2- || true)"
  [[ "$cur_api_id" == "123456" ]] && cur_api_id=""
  [[ "$cur_api_hash" == "your_api_hash" ]] && cur_api_hash=""
  [[ "$cur_bot_token" == "123456:your_bot_token" ]] && cur_bot_token=""
  [[ "$cur_session" == "replace_with_your_string_session" ]] && cur_session=""
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
  proxy_val="$(prompt_default '请输入 TG 代理地址（可选）' "$cur_proxy")"
  echo ""
  workers_val="$(prompt_default '请输入最大下载并发数（1-10）' "$cur_workers")"
  workers_val="${workers_val:-5}"
  echo ""

  local session_val="$cur_session"
  echo "TG User Session："
  if [[ -n "$session_val" ]]; then
    echo "  当前状态：已配置"
  else
    echo "  当前状态：未配置"
  fi
  echo "  1) 重新生成 Session"
  echo "  2) 保持当前 Session"
  read -r -p "请选择 [2]: " sess_choice
  sess_choice="${sess_choice:-2}"

  if [[ "$sess_choice" == "1" ]]; then
    if [[ -z "$api_id_val" || -z "$api_hash_val" ]]; then
      err "生成 TG_USER_SESSION 前，必须先填写 TG API ID 和 TG API HASH。"
    else
      session_val="$(generate_user_session "$dir" "$api_id_val" "$api_hash_val" "$proxy_val")"
    fi
  fi

  echo ""
  _set_env_var "$existing" "TG_API_ID" "$api_id_val"
  _set_env_var "$existing" "TG_API_HASH" "$api_hash_val"
  _set_env_var "$existing" "TG_BOT_TOKEN" "$bot_token_val"
  _set_env_var "$existing" "TG_PROXY" "$proxy_val"
  _set_env_var "$existing" "MAX_DOWNLOAD_WORKERS" "$workers_val"
  _set_env_var "$existing" "TG_USER_SESSION" "$session_val"
  ok "配置已保存到 ${existing}"
}

_set_env_var() {
  local existing="$1"
  local key="$2"
  local val="$3"

  if [[ -z "$val" ]]; then
    return
  fi

  local tmpfile
  local found=0
  tmpfile="$(mktemp)"

  if [[ -f "$existing" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^${key}= ]]; then
        echo "${key}=${val}" >> "$tmpfile"
        found=1
      else
        echo "$line" >> "$tmpfile"
      fi
    done < "$existing"
  fi

  if [[ "$found" == "0" ]]; then
    echo "${key}=${val}" >> "$tmpfile"
  fi

  run_as_root mv "$tmpfile" "$existing"
}

install_app() {
  require_linux
  ensure_packages

  local target_dir target_user target_group repo_url
  target_user="$APP_USER"
  target_group="$(id -gn "$target_user")"
  target_dir="$(prompt_default '安装目录' "$INSTALL_DIR_DEFAULT")"
  repo_url="$REPO_URL_DEFAULT"

  echo ""
  run_as_root mkdir -p "$target_dir"

  if [[ -d "${target_dir}/.git" ]]; then
    run_as_root -u "$target_user" git -C "$target_dir" pull --ff-only
  else
    run_as_root rm -rf "$target_dir"
    run_as_root -u "$target_user" git clone "$repo_url" "$target_dir"
  fi

  write_service_conf "$target_dir" "$target_user" "$target_group"
  setup_venv "$target_dir" "$target_user"
  configure_env "$target_dir"
  ensure_owner "$target_dir" "$target_user" "$target_group"
  write_service_file "$target_dir" "$target_user" "$target_group"
  install_command_entry "$target_dir"
  run_as_root systemctl enable --now "${SERVICE_NAME}.service"

  ok "安装完成，服务已启动。"
  ok "后续可使用 'sudo tgd' 进行管理。"
}

reconfigure_app() {
  local dir
  dir="$(install_dir)"

  configure_env "$dir"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "配置已更新，服务已重启。"
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

uninstall_app() {
  local dir
  dir="$(install_dir)"

  read -r -p "这将停止服务并删除 ${dir}，确认继续吗？[y/N]: " confirm
  [[ "${confirm,,}" == "y" ]] || exit 0

  if service_exists; then
    run_as_root systemctl disable --now "${SERVICE_NAME}.service" || true
    run_as_root rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    run_as_root rm -f "/etc/${SERVICE_NAME}.conf"
    run_as_root systemctl daemon-reload
  fi

  run_as_root rm -f "$SCRIPT_INSTALL_PATH"
  run_as_root rm -rf "$dir"
  ok "卸载完成。"
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
  echo "1) 重新配置"
  echo "2) 启动服务"
  echo "3) 重启服务"
  echo "4) 停止服务"
  echo "5) 查看服务状态"
  echo "6) 卸载"
  echo "0) 退出"
  read -r -p "请选择： " choice

  case "$choice" in
    1) reconfigure_app ;;
    2) start_service ;;
    3) restart_service ;;
    4) stop_service ;;
    5) status_service ;;
    6) uninstall_app ;;
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
