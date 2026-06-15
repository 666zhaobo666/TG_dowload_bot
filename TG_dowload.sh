#!/usr/bin/env bash
set -euo pipefail

APP_NAME="TG_dowload_bot"
SERVICE_NAME="tg-download-bot"
APP_USER="${SUDO_USER:-$USER}"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6 2>/dev/null || printf '%s' "$HOME")"

# Detect "noexec" mount on APP_HOME (common on /root in many VPS / OpenVZ environments).
_mount_has_noexec() {
  local target="$1"
  command -v findmnt >/dev/null 2>&1 || return 1
  local opts
  opts="$(findmnt -no OPTIONS --target "$target" 2>/dev/null || true)"
  [[ "$opts" == *noexec* ]]
}

INSTALL_DIR_DEFAULT="${APP_HOME}/TG_download"
if [[ "$(id -u)" -eq 0 && "$APP_HOME" == /root* ]] || _mount_has_noexec "$APP_HOME"; then
  printf "\033[33m[%s]\033[0m Detected a noexec mount or root user; defaulting install dir to /opt/TG_download\n" "$APP_NAME"
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
    err "This manager only supports Linux."
    exit 1
  fi
}

run_as_root() {
  local run_user=""
  if [[ "${1:-}" == "-u" ]]; then
    run_user="$2"
    shift 2
  fi
  if [[ -n "$run_user" ]]; then
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
    err "Unsupported package manager. Please install git, curl, python3, and python3-venv manually."
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
    err "TG_API_ID and TG_API_HASH are required to generate TG_USER_SESSION"
    return 1
  fi

  log "Generating TG_USER_SESSION (you will be prompted for phone + verification code)..."
  local tmpfile
  tmpfile="$(mktemp)"
  TG_API_ID="$api_id" TG_API_HASH="$api_hash" TG_PROXY="$tg_proxy" \
    run_as_root -u "$APP_USER" python3 "${dir}/generate_string_session.py" 2>&1 | tee "$tmpfile" >/dev/null || true
  local session
  session="$(grep -v '^Put the following' "$tmpfile" | tail -n1 | tr -d '[:space:]')"
  rm -f "$tmpfile"
  if [[ -n "$session" ]]; then
    ok "TG_USER_SESSION generated"
    printf "%s" "$session"
    return 0
  fi
  err "Failed to generate TG_USER_SESSION"
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
      err "Invalid directory alias entry: $entry"
      exit 1
    fi
    local alias_name="${entry%%=*}"
    local alias_path="${entry#*=}"
    alias_name="$(printf '%s' "$alias_name" | xargs)"
    alias_path="$(printf '%s' "$alias_path" | xargs)"
    if [[ ! "$alias_path" = /* ]]; then
      err "Directory path for alias '$alias_name' must be an absolute Linux path."
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
ExecStart=${dir}/.venv/bin/python ${dir}/tg_archiver_bot.py
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

setup_venv() {
  local dir="$1"
  local user="$2"

  # Sanity check: refuse to create the venv on a noexec filesystem,
  # otherwise pip/python inside the venv will fail with "Permission denied".
  if _mount_has_noexec "$dir"; then
    err "Install directory $dir is on a noexec mount; venv binaries will not be executable."
    err "Please re-run the installer and choose a directory on a normal mount (e.g. /opt/TG_download)."
    exit 1
  fi

  run_as_root -u "$user" python3 -m venv "${dir}/.venv"
  run_as_root -u "$user" "${dir}/.venv/bin/pip" install --upgrade pip
  run_as_root -u "$user" "${dir}/.venv/bin/pip" install -r "${dir}/requirements.txt"
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
  cur_workers="${cur_workers:-5}"
  log "开始配置 TG Bot 参数。"
  echo ""
  local api_id_val api_hash_val bot_token_val proxy_val workers_val
  api_id_val="$(prompt_default '告 TG API ID（输入后回车）' "$cur_api_id")"
  echo ""
  api_hash_val="$(prompt_default '告 TG API HASH（输入后回车保持不变）' "$cur_api_hash" true)"
  echo ""
  bot_token_val="$(prompt_default '告 TG Bot Token（输入后回车保持不变）' "$cur_bot_token" true)"
  echo ""
  proxy_val="$(prompt_default '告 TG 代理地址（可选，直接回车跳过）' "$cur_proxy")"
  echo ""
  workers_val="$(prompt_default '告 最大并发下载线程数（1-10，默讨 5）' "$cur_workers")"
  workers_val="${workers_val:-5}"
  echo ""
  local session_val="$cur_session"
  echo "TG User Session（用户登录帐证）："
  echo "  当前状态：${session_val:+已配置}  ${session_val:+-}"
  echo "  1) 重新生成（需要电话+验证码）"
  echo "  2) 保持当前配置"
  read -r -p "请选择 [2]: " sess_choice
  sess_choice="${sess_choice:-2}"
  if [[ "$sess_choice" == "1" ]]; then
    if [[ -z "$api_id_val" || -z "$api_hash_val" ]]; then
      err "生成 TG_USER_SESSION 需要先填写 TG API ID 和 API HASH"
      echo "提示：重新运行本向导，先配置 API 参数。"
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
  ok "配置文件已保存：${existing}"
}

install_app() {
  require_linux
  ensure_packages
  local target_dir target_user target_group repo_url
  target_user="$APP_USER"
  target_group="$(id -gn "$target_user")"
  target_dir="$(prompt_default '安装目录（直接回车使用默讨路径）' "$INSTALL_DIR_DEFAULT")"
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
  ok "后续管理请使用：sudo tgd"
}

reconfigure_app() {
  local dir
  dir="$(install_dir)"
  while true; do
    echo ""
    echo "========== 参数配置 =========="
    echo "1) TG API 配置（API ID + API HASH）"
    echo "2) TG Bot Token"
    echo "3) TG 代理地址"
    echo "4) TG User Session（用户登录帐证）"
    echo "5) 最大并发线程数"
    echo "6) 完整配置向导"
    echo "0) 返回"
    read -r -p "请选择: " choice
    case "$choice" in
      1) _reconfig_api "$dir" ;;
      2) _reconfig_token "$dir" ;;
      3) _reconfig_proxy "$dir" ;;
      4) _reconfig_session "$dir" ;;
      5) _reconfig_workers "$dir" ;;
      6) configure_env "$dir" ; run_as_root systemctl restart "${SERVICE_NAME}.service" ; ok "配置已更新，服务重启中..." ;;
      0) break ;;
      *) err "无效选项，请重新选择" ;;
    esac
  done
}

_reconfig_api() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_id cur_hash new_id new_hash
  cur_id="$(grep '^TG_API_ID=' "$existing" | cut -d= -f2- || true)"
  cur_hash="$(grep '^TG_API_HASH=' "$existing" | cut -d= -f2- || true)"
  new_id="$(prompt_default '告 TG API ID（直接回车保持不变）' "$cur_id")"
  echo ""
  new_hash="$(prompt_default '告 TG API HASH（直接回车保持不变）' "$cur_hash" true)"
  echo ""
  [[ -n "$new_id" ]] && _set_env_var "$existing" "TG_API_ID" "$new_id"
  [[ -n "$new_hash" ]] && _set_env_var "$existing" "TG_API_HASH" "$new_hash"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "API 配置已更新，服务重启中..."
}

_reconfig_token() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_token new_token
  cur_token="$(grep '^TG_BOT_TOKEN=' "$existing" | cut -d= -f2- || true)"
  new_token="$(prompt_default '告 TG Bot Token（直接回车保持不变）' "$cur_token" true)"
  echo ""
  [[ -n "$new_token" ]] && _set_env_var "$existing" "TG_BOT_TOKEN" "$new_token"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "Bot Token 已更新，服务重启中..."
}

_reconfig_proxy() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_proxy new_proxy
  cur_proxy="$(grep '^TG_PROXY=' "$existing" | cut -d= -f2- || true)"
  new_proxy="$(prompt_default '告 TG 代理地址（直接回车保持不变）' "$cur_proxy")"
  echo ""
  _set_env_var "$existing" "TG_PROXY" "$new_proxy"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "代理配置已更新，服务重启中..."
}

_reconfig_session() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_session api_id_val api_hash_val proxy_val
  cur_session="$(grep '^TG_USER_SESSION=' "$existing" | cut -d= -f2- || true)"
  api_id_val="$(grep '^TG_API_ID=' "$existing" | cut -d= -f2- || true)"
  api_hash_val="$(grep '^TG_API_HASH=' "$existing" | cut -d= -f2- || true)"
  proxy_val="$(grep '^TG_PROXY=' "$existing" | cut -d= -f2- || true)"
  echo "TG User Session（当前：${cur_session:+已配置}  ${cur_session:+-}）："
  echo "1) 重新生成（需要电话+验证码）"
  echo "2) 保持当前配置"
  read -r -p "请选择 [2]: " ch
  ch="${ch:-2}"
  if [[ "$ch" == "1" ]]; then
    if [[ -z "$api_id_val" || -z "$api_hash_val" ]]; then
      err "生成 Session 需要先配置 TG API，请先选择第 1 项"
    else
      local new_session="$(generate_user_session "$dir" "$api_id_val" "$api_hash_val" "$proxy_val")"
      _set_env_var "$existing" "TG_USER_SESSION" "$new_session"
      run_as_root systemctl restart "${SERVICE_NAME}.service"
      ok "Session 已更新，服务重启中..."
    fi
  fi
}

_reconfig_workers() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_workers new_workers
  cur_workers="$(grep '^MAX_DOWNLOAD_WORKERS=' "$existing" | cut -d= -f2- || true)"
  cur_workers="${cur_workers:-5}"
  new_workers="$(prompt_default '最大并发线程数（直接回车保持不变）' "$cur_workers")"
  echo ""
  [[ -n "$new_workers" ]] && _set_env_var "$existing" "MAX_DOWNLOAD_WORKERS" "$new_workers"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "线程数配置已更新，服务重启中..."
}

_set_env_var() {
  local existing="$1"; local key="$2"; local val="$3"
  if [[ -z "$val" ]]; then return; fi
  local tmpfile="$(mktemp)"; local found=0
  if [[ -f "$existing" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^${key}= ]]; then
        echo "${key}=${val}" >> "$tmpfile"; found=1
      else echo "$line" >> "$tmpfile"; fi
    done < "$existing"
  fi
  [[ "$found" == "0" ]] && echo "${key}=${val}" >> "$tmpfile"
  run_as_root mv "$tmpfile" "$existing"
}

_reconfig_api() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_id cur_hash new_id new_hash
  cur_id="$(grep '^TG_API_ID=' "$existing" | cut -d= -f2- || true)"
  cur_hash="$(grep '^TG_API_HASH=' "$existing" | cut -d= -f2- || true)"
  new_id="$(prompt_default 'TG API ID??????????' "$cur_id")"
  echo ""
  new_hash="$(prompt_default 'TG API HASH??????????' "$cur_hash" true)"
  echo ""
  [[ -n "$new_id" ]] && _set_env_var "$existing" "TG_API_ID" "$new_id"
  [[ -n "$new_hash" ]] && _set_env_var "$existing" "TG_API_HASH" "$new_hash"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "API ???????????..."
}

_reconfig_token() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_token new_token
  cur_token="$(grep '^TG_BOT_TOKEN=' "$existing" | cut -d= -f2- || true)"
  new_token="$(prompt_default 'TG Bot Token??????????' "$cur_token" true)"
  echo ""
  [[ -n "$new_token" ]] && _set_env_var "$existing" "TG_BOT_TOKEN" "$new_token"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "Bot Token ?????????..."
}

_reconfig_proxy() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_proxy new_proxy
  cur_proxy="$(grep '^TG_PROXY=' "$existing" | cut -d= -f2- || true)"
  new_proxy="$(prompt_default 'TG ??????????????' "$cur_proxy")"
  echo ""
  _set_env_var "$existing" "TG_PROXY" "$new_proxy"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "?????????????..."
}

_reconfig_session() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_session api_id_val api_hash_val proxy_val
  cur_session="$(grep '^TG_USER_SESSION=' "$existing" | cut -d= -f2- || true)"
  api_id_val="$(grep '^TG_API_ID=' "$existing" | cut -d= -f2- || true)"
  api_hash_val="$(grep '^TG_API_HASH=' "$existing" | cut -d= -f2- || true)"
  proxy_val="$(grep '^TG_PROXY=' "$existing" | cut -d= -f2- || true)"
  echo "TG User Session????${cur_session:+???}  ${cur_session:+-}??"
  echo "1) ?????????+????"
  echo "2) ??????"
  read -r -p "??? [2]: " ch
  ch="${ch:-2}"
  if [[ "$ch" == "1" ]]; then
    if [[ -z "$api_id_val" || -z "$api_hash_val" ]]; then
      err "?? Session ????? TG API?????? 1 ?"
    else
      local new_session="$(generate_user_session "$dir" "$api_id_val" "$api_hash_val" "$proxy_val")"
      _set_env_var "$existing" "TG_USER_SESSION" "$new_session"
      run_as_root systemctl restart "${SERVICE_NAME}.service"
      ok "Session ?????????..."
    fi
  fi
}

_reconfig_workers() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_workers new_workers
  cur_workers="$(grep '^MAX_DOWNLOAD_WORKERS=' "$existing" | cut -d= -f2- || true)"
  cur_workers="${cur_workers:-5}"
  new_workers="$(prompt_default '?????????????????' "$cur_workers")"
  echo ""
  [[ -n "$new_workers" ]] && _set_env_var "$existing" "MAX_DOWNLOAD_WORKERS" "$new_workers"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "??????????????..."
}

_set_env_var() {
  local existing="$1"; local key="$2"; local val="$3"
  if [[ -z "$val" ]]; then return; fi
  local tmpfile="$(mktemp)"; local found=0
  if [[ -f "$existing" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^${key}= ]]; then
        echo "${key}=${val}" >> "$tmpfile"; found=1
      else echo "$line" >> "$tmpfile"; fi
    done < "$existing"
  fi
  [[ "$found" == "0" ]] && echo "${key}=${val}" >> "$tmpfile"
  run_as_root mv "$tmpfile" "$existing"
}

_reconfig_api() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_id cur_hash new_id new_hash
  cur_id="$(grep '"'"'^TG_API_ID='"'"' "$existing" | cut -d= -f2- || true)"
  cur_hash="$(grep '"'"'^TG_API_HASH='"'"' "$existing" | cut -d= -f2- || true)"
  new_id="$(prompt_default '"'"'TG API ID??????????'"'"' "$cur_id")"
  echo ""
  new_hash="$(prompt_default '"'"'TG API HASH??????????'"'"' "$cur_hash" true)"
  echo ""
  [[ -n "$new_id" ]] && _set_env_var "$existing" "TG_API_ID" "$new_id"
  [[ -n "$new_hash" ]] && _set_env_var "$existing" "TG_API_HASH" "$new_hash"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "API ???????????..."
}

_reconfig_token() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_token new_token
  cur_token="$(grep '"'"'^TG_BOT_TOKEN='"'"' "$existing" | cut -d= -f2- || true)"
  new_token="$(prompt_default '"'"'TG Bot Token??????????'"'"' "$cur_token" true)"
  echo ""
  [[ -n "$new_token" ]] && _set_env_var "$existing" "TG_BOT_TOKEN" "$new_token"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "Bot Token ?????????..."
}

_reconfig_proxy() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_proxy new_proxy
  cur_proxy="$(grep '"'"'^TG_PROXY='"'"' "$existing" | cut -d= -f2- || true)"
  new_proxy="$(prompt_default '"'"'TG ??????????????'"'"' "$cur_proxy")"
  echo ""
  _set_env_var "$existing" "TG_PROXY" "$new_proxy"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "?????????????..."
}

_reconfig_session() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_session api_id_val api_hash_val proxy_val
  cur_session="$(grep '"'"'^TG_USER_SESSION='"'"' "$existing" | cut -d= -f2- || true)"
  api_id_val="$(grep '"'"'^TG_API_ID='"'"' "$existing" | cut -d= -f2- || true)"
  api_hash_val="$(grep '"'"'^TG_API_HASH='"'"' "$existing" | cut -d= -f2- || true)"
  proxy_val="$(grep '"'"'^TG_PROXY='"'"' "$existing" | cut -d= -f2- || true)"
  echo "TG User Session????${cur_session:+???}  ${cur_session:+-}??"
  echo "1) ?????????+????"
  echo "2) ??????"
  read -r -p "??? [2]: " ch
  ch="${ch:-2}"
  if [[ "$ch" == "1" ]]; then
    if [[ -z "$api_id_val" || -z "$api_hash_val" ]]; then
      err "?? Session ????? TG API?????? 1 ?"
    else
      local new_session="$(generate_user_session "$dir" "$api_id_val" "$api_hash_val" "$proxy_val")"
      _set_env_var "$existing" "TG_USER_SESSION" "$new_session"
      run_as_root systemctl restart "${SERVICE_NAME}.service"
      ok "Session ?????????..."
    fi
  fi
}

_reconfig_workers() {
  local dir="$1"; local existing="${dir}/.env"
  local cur_workers new_workers
  cur_workers="$(grep '"'"'^MAX_DOWNLOAD_WORKERS='"'"' "$existing" | cut -d= -f2- || true)"
  cur_workers="${cur_workers:-5}"
  new_workers="$(prompt_default '"'"'?????????????????'"'"' "$cur_workers")"
  echo ""
  [[ -n "$new_workers" ]] && _set_env_var "$existing" "MAX_DOWNLOAD_WORKERS" "$new_workers"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "??????????????..."
}

_set_env_var() {
  local existing="$1"; local key="$2"; local val="$3"
  if [[ -z "$val" ]]; then return; fi
  local tmpfile="$(mktemp)"; local found=0
  if [[ -f "$existing" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^${key}= ]]; then
        echo "${key}=${val}" >> "$tmpfile"; found=1
      else echo "$line" >> "$tmpfile"; fi
    done < "$existing"
  fi
  [[ "$found" == "0" ]] && echo "${key}=${val}" >> "$tmpfile"
  run_as_root mv "$tmpfile" "$existing"
}

start_service() {
  run_as_root systemctl start "${SERVICE_NAME}.service"
  ok "Service started."
}

restart_service() {
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "Service restarted."
}

stop_service() {
  run_as_root systemctl stop "${SERVICE_NAME}.service"
  ok "Service stopped."
}

status_service() {
  run_as_root systemctl status "${SERVICE_NAME}.service" --no-pager
}

uninstall_app() {
  local dir
  dir="$(install_dir)"
  read -r -p "This will stop service and remove ${dir}. Continue? [y/N]: " confirm
  [[ "${confirm,,}" == "y" ]] || exit 0
  if service_exists; then
    run_as_root systemctl disable --now "${SERVICE_NAME}.service" || true
    run_as_root rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    run_as_root rm -f "/etc/${SERVICE_NAME}.conf"
    run_as_root systemctl daemon-reload
  fi
  run_as_root rm -f "$SCRIPT_INSTALL_PATH"
  run_as_root rm -rf "$dir"
  ok "Uninstalled."
}


show_install_menu() {
  echo "1) 安装"
  echo "0) 退出"
  read -r -p "请选择: " choice
  case "$choice" in
    1) install_app ;;
    0) exit 0 ;;
    *) err "无效选项。" ; exit 1 ;;
  esac
}


show_manage_menu() {
  echo "1) 重配置"
  echo "2) 启动服务"
  echo "3) 重启服务"
  echo "4) 停止服务"
  echo "5) 服务状态"
  echo "6) 卸载"
  echo "0) 退出"
  read -r -p "请选择: " choice
  case "$choice" in
    1) reconfigure_app ;;
    2) start_service ;;
    3) restart_service ;;
    4) stop_service ;;
    5) status_service ;;
    6) uninstall_app ;;
    0) exit 0 ;;
    *) err "无效选项。" ; exit 1 ;;
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


