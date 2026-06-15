#!/usr/bin/env bash
set -euo pipefail

APP_NAME="TG_dowload_bot"
SERVICE_NAME="tg-download-bot"
APP_USER="${SUDO_USER:-$USER}"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6 2>/dev/null || printf '%s' "$HOME")"
INSTALL_DIR_DEFAULT="${APP_HOME}/TG_download"
SCRIPT_INSTALL_PATH="/usr/local/bin/tgd"
REPO_URL_DEFAULT="https://github.com/666zhaobo666/TG_dowload_bot.git"

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
  fi
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  printf "%s" "$value"
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

  local current_api_id="" current_api_hash="" current_bot_token="" current_session="" current_proxy=""
  local current_output_dir="" current_comments="true" current_limit="100" current_workers="5"
  local current_alias_paths="" current_default_alias="" current_silent="false"
  if [[ -f "$existing" ]]; then
    current_api_id="$(grep '^TG_API_ID=' "$existing" | cut -d= -f2- || true)"
    current_api_hash="$(grep '^TG_API_HASH=' "$existing" | cut -d= -f2- || true)"
    current_bot_token="$(grep '^TG_BOT_TOKEN=' "$existing" | cut -d= -f2- || true)"
    current_session="$(grep '^TG_USER_SESSION=' "$existing" | cut -d= -f2- || true)"
    current_proxy="$(grep '^TG_PROXY=' "$existing" | cut -d= -f2- || true)"
    current_output_dir="$(grep '^OUTPUT_DIR=' "$existing" | cut -d= -f2- || true)"
    current_comments="$(grep '^INCLUDE_COMMENTS=' "$existing" | cut -d= -f2- || true)"
    current_limit="$(grep '^DEFAULT_CHANNEL_LIMIT=' "$existing" | cut -d= -f2- || true)"
    current_workers="$(grep '^MAX_DOWNLOAD_WORKERS=' "$existing" | cut -d= -f2- || true)"
    current_alias_paths="$(grep '^DOWNLOAD_DIR_ALIASES=' "$existing" | cut -d= -f2- || true)"
    current_default_alias="$(grep '^DEFAULT_DOWNLOAD_ALIAS=' "$existing" | cut -d= -f2- || true)"
    current_silent="$(grep '^SILENT_DOWNLOAD_MODE=' "$existing" | cut -d= -f2- || true)"
  fi

  log "Configure bot environment."
  local api_id api_hash bot_token user_session tg_proxy output_dir include_comments default_limit max_workers alias_paths default_alias silent_mode
  api_id="$(prompt_default 'TG_API_ID' "$current_api_id")"
  api_hash="$(prompt_default 'TG_API_HASH' "$current_api_hash" true)"
  bot_token="$(prompt_default 'TG_BOT_TOKEN' "$current_bot_token" true)"
  user_session="$(prompt_default 'TG_USER_SESSION' "$current_session" true)"
  tg_proxy="$(prompt_default 'TG_PROXY (optional)' "$current_proxy")"
  output_dir="$(prompt_default 'OUTPUT_DIR (absolute path recommended on Linux)' "${current_output_dir:-${dir}/downloads}")"
  include_comments="$(prompt_default 'INCLUDE_COMMENTS (true/false)' "$current_comments")"
  default_limit="$(prompt_default 'DEFAULT_CHANNEL_LIMIT' "$current_limit")"
  max_workers="$(prompt_default 'MAX_DOWNLOAD_WORKERS (1-10)' "$current_workers")"
  alias_paths="$(prompt_default 'DOWNLOAD_DIR_ALIASES (alias=/abs/path;alias2=/abs/path2)' "$current_alias_paths")"
  alias_paths="$(parse_alias_paths "$alias_paths")"
  default_alias="$(prompt_default 'DEFAULT_DOWNLOAD_ALIAS' "$current_default_alias")"
  silent_mode="$(prompt_default 'SILENT_DOWNLOAD_MODE (true/false)' "$current_silent")"

  cat > "$existing" <<EOF
TG_API_ID=${api_id}
TG_API_HASH=${api_hash}
TG_BOT_TOKEN=${bot_token}
TG_USER_SESSION=${user_session}
TG_PROXY=${tg_proxy}
OUTPUT_DIR=${output_dir}
INCLUDE_COMMENTS=${include_comments}
DEFAULT_CHANNEL_LIMIT=${default_limit}
MAX_DOWNLOAD_WORKERS=${max_workers}
DOWNLOAD_DIR_ALIASES=${alias_paths}
DEFAULT_DOWNLOAD_ALIAS=${default_alias}
SILENT_DOWNLOAD_MODE=${silent_mode}
EOF
  ok ".env updated: ${existing}"
}

install_app() {
  require_linux
  ensure_packages

  local target_dir target_user target_group repo_url
  target_user="$APP_USER"
  target_group="$(id -gn "$target_user")"
  target_dir="$(prompt_default 'Install directory' "$INSTALL_DIR_DEFAULT")"
  repo_url="$REPO_URL_DEFAULT"

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
  ok "Installation complete and service started."
  ok "You can manage it later with: tgd"
}

reconfigure_app() {
  local dir
  dir="$(install_dir)"
  configure_env "$dir"
  run_as_root systemctl restart "${SERVICE_NAME}.service"
  ok "Configuration updated and service restarted."
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
  echo "1) Install"
  echo "0) Exit"
  read -r -p "Choose: " choice
  case "$choice" in
    1) install_app ;;
    0) exit 0 ;;
    *) err "Invalid choice." ; exit 1 ;;
  esac
}

show_manage_menu() {
  echo "1) Reconfigure"
  echo "2) Start service"
  echo "3) Restart service"
  echo "4) Stop service"
  echo "5) Service status"
  echo "6) Uninstall"
  echo "0) Exit"
  read -r -p "Choose: " choice
  case "$choice" in
    1) reconfigure_app ;;
    2) start_service ;;
    3) restart_service ;;
    4) stop_service ;;
    5) status_service ;;
    6) uninstall_app ;;
    0) exit 0 ;;
    *) err "Invalid choice." ; exit 1 ;;
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
