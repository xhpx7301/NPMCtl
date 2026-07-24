#!/usr/bin/env bash

# NPMCtl - an interactive Docker manager for Nginx Proxy Manager.
# It installs a separate `npmctl` command and keeps NPM's data in /opt/npmctl.

set -uo pipefail

readonly PROJECT_NAME="NPMCtl"
readonly MANAGER_VERSION="1.0.0"
readonly MANAGER_SOURCE_URL="${NPMCTL_SOURCE_URL:-https://raw.githubusercontent.com/xhpx7301/NPMCtl/main/npmctl.sh}"
readonly INSTALL_DIR="/opt/npmctl"
readonly COMPOSE_FILE="${INSTALL_DIR}/compose.yml"
readonly CONFIG_FILE="${INSTALL_DIR}/.env"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly CERT_DIR="${INSTALL_DIR}/letsencrypt"
readonly BACKUP_DIR="/var/backups/npmctl"
readonly MANAGER_DIR="/usr/local/lib/npmctl"
readonly MANAGER_SCRIPT="${MANAGER_DIR}/npmctl.sh"
readonly MANAGER_COMMAND="/usr/local/bin/npmctl"
readonly NPM_IMAGE="jc21/nginx-proxy-manager:latest"

if [[ -t 1 ]]; then
  readonly RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
  readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

info() { printf '%s[信息]%s %s\n' "$BLUE" "$RESET" "$*"; }
success() { printf '%s[完成]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error() { printf '%s[错误]%s %s\n' "$RED" "$RESET" "$*" >&2; }

pause_menu() { printf '\n'; read -r -p '按 Enter 键返回主菜单...' _ || true; }
confirm_action() { local answer; read -r -p "$1 [y/n，回车默认n]：" answer || return 1; [[ "$answer" =~ ^[Yy]$ ]]; }
timestamp() { date '+%Y%m%d-%H%M%S'; }
manager_source() { readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s\n' "${BASH_SOURCE[0]}"; }

show_command_usage() {
  cat <<'USAGE'
NPMCtl 是 Nginx Proxy Manager 的 Docker 管理菜单。
用法：npmctl [--install] [--network bridge|host] [--help]
  --install                 创建或更新 Nginx Proxy Manager 部署
  --network bridge|host     创建或切换网络模式（仅 Linux 支持 host）
  --install-manager         安装 npmctl 命令入口，供安装器调用
  --help, -h                显示本帮助
USAGE
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] && return
  command -v sudo >/dev/null 2>&1 || { error '此菜单需要 root 权限，并且系统没有安装 sudo。'; exit 1; }
  exec sudo bash "$(manager_source)" "$@"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || { error '未找到 Docker。请先在菜单中安装 Docker Engine，或按 Docker 官方文档安装。'; return 1; }
  docker info >/dev/null 2>&1 || { error 'Docker 守护进程不可用。请启动 docker 服务后重试。'; return 1; }
  docker compose version >/dev/null 2>&1 || { error '需要 Docker Compose v2（命令：docker compose）。'; return 1; }
}

install_manager_command() {
  local source_path
  source_path="$(manager_source)"
  install -d -m 0755 "$MANAGER_DIR"
  [[ "$source_path" == "$MANAGER_SCRIPT" ]] || install -m 0755 "$source_path" "$MANAGER_SCRIPT"
  cat >"$MANAGER_COMMAND" <<'WRAPPER'
#!/usr/bin/env bash
set -uo pipefail
readonly MANAGER_SCRIPT="/usr/local/lib/npmctl/npmctl.sh"
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  exec "$MANAGER_SCRIPT" "$@"
fi
command -v sudo >/dev/null 2>&1 || { printf 'npmctl 需要 root 权限，但系统未安装 sudo。\n' >&2; exit 1; }
exec sudo "$MANAGER_SCRIPT" "$@"
WRAPPER
  chmod 0755 "$MANAGER_COMMAND"
}

cache_busted_github_raw_url() {
  local source_url="$1" separator
  case "$source_url" in
    https://raw.githubusercontent.com/*)
      [[ "$source_url" == *\?* ]] && separator='&' || separator='?'
      printf '%s%snpmctl_cache_bust=%s-%s-%s\n' "$source_url" "$separator" "$(date +%s)" "$$" "$RANDOM"
      ;;
    *) printf '%s\n' "$source_url" ;;
  esac
}

update_manager() {
  local temp_file source_url new_version
  temp_file="$(mktemp)" || return 1
  source_url="$(cache_busted_github_raw_url "$MANAGER_SOURCE_URL")"
  info '正在下载 NPMCtl 管理菜单更新...'
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 -H 'Cache-Control: no-cache' "$source_url" -o "$temp_file" || { rm -f "$temp_file"; error '下载失败。'; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$temp_file" --header='Cache-Control: no-cache' "$source_url" || { rm -f "$temp_file"; error '下载失败。'; return 1; }
  else
    rm -f "$temp_file"; error '需要 curl 或 wget 才能更新。'; return 1
  fi
  if ! grep -Fq 'readonly PROJECT_NAME="NPMCtl"' "$temp_file" || ! bash -n "$temp_file"; then
    rm -f "$temp_file"; error '下载的脚本校验失败。'; return 1
  fi
  new_version="$(sed -n 's/^readonly MANAGER_VERSION="\([^"]*\)"$/\1/p' "$temp_file" | head -n 1)"
  install -d -m 0750 "$BACKUP_DIR"
  [[ ! -f "$MANAGER_SCRIPT" ]] || cp -a "$MANAGER_SCRIPT" "${BACKUP_DIR}/npmctl-before-update.$(timestamp).bak"
  install -m 0755 "$temp_file" "$MANAGER_SCRIPT"
  rm -f "$temp_file"
  success "NPMCtl 已更新：${MANAGER_VERSION} -> ${new_version:-未知版本}。"
}

install_docker() {
  local manager
  command -v docker >/dev/null 2>&1 && { success 'Docker 已安装。'; return 0; }
  warn '将通过系统软件源安装 Docker Engine 和 Docker Compose 插件。'
  confirm_action '确认继续安装 Docker？' || { info '已取消。'; return 0; }
  if command -v apt-get >/dev/null 2>&1; then
    manager='apt-get'
    apt-get update && apt-get install -y docker.io docker-compose-plugin || { error 'Docker 安装失败。部分发行版需要按 Docker 官方文档添加 Docker 软件源。'; return 1; }
  elif command -v dnf >/dev/null 2>&1; then
    manager='dnf'
    dnf install -y docker docker-compose-plugin || { error 'Docker 安装失败。'; return 1; }
  else
    error '仅支持 apt 或 dnf 发行版自动安装 Docker。请按 Docker 官方文档安装。'; return 1
  fi
  systemctl enable --now docker || { error "已执行 ${manager} 安装，但 Docker 服务启动失败。"; return 1; }
  require_docker && success 'Docker Engine 与 Compose 已就绪。'
}

config_value() { [[ -f "$CONFIG_FILE" ]] && sed -n "s/^$1=//p" "$CONFIG_FILE" | tail -n 1 || true; }
current_network_mode() { local mode; mode="$(config_value NETWORK_MODE)"; [[ "$mode" == host ]] && printf 'host\n' || printf 'bridge\n'; }

write_config() {
  local mode="$1"
  install -d -m 0750 "$INSTALL_DIR" "$DATA_DIR" "$CERT_DIR"
  cat >"$CONFIG_FILE" <<EOF
# Managed by NPMCtl. Change networking through: npmctl --network bridge|host
NETWORK_MODE=${mode}
EOF
  chmod 0640 "$CONFIG_FILE"
}

write_compose_file() {
  local mode="$1"
  install -d -m 0750 "$INSTALL_DIR" "$DATA_DIR" "$CERT_DIR"
  if [[ "$mode" == host ]]; then
    cat >"$COMPOSE_FILE" <<EOF
# Managed by NPMCtl. Linux host network mode: NPM can reach host 127.0.0.1 services.
services:
  npm:
    image: ${NPM_IMAGE}
    container_name: nginx-proxy-manager
    restart: unless-stopped
    network_mode: host
    environment:
      DB_SQLITE_FILE: "/data/database.sqlite"
      DISABLE_IPV6: "true"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF
  else
    cat >"$COMPOSE_FILE" <<EOF
# Managed by NPMCtl. Official default: Docker bridge network with published ports.
services:
  npm:
    image: ${NPM_IMAGE}
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    environment:
      DB_SQLITE_FILE: "/data/database.sqlite"
      DISABLE_IPV6: "true"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF
  fi
  chmod 0640 "$COMPOSE_FILE"
  write_config "$mode"
}

backup_deployment_files() {
  install -d -m 0750 "$BACKUP_DIR"
  [[ ! -f "$COMPOSE_FILE" ]] || cp -a "$COMPOSE_FILE" "${BACKUP_DIR}/compose.yml.$(timestamp).bak"
  [[ ! -f "$CONFIG_FILE" ]] || cp -a "$CONFIG_FILE" "${BACKUP_DIR}/npmctl.env.$(timestamp).bak"
}

port_conflicts() {
  local port
  command -v ss >/dev/null 2>&1 || return 0
  for port in 80 81 443; do
    if ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; then
      warn "检测到宿主机端口 ${port} 正在监听："
      ss -ltnp "sport = :${port}" 2>/dev/null || true
    fi
  done
}

deploy_npm() {
  local mode="$1" previous_mode='' first_deploy=0
  require_docker || return 1
  [[ "$mode" == bridge || "$mode" == host ]] || { error '网络模式必须为 bridge 或 host。'; return 1; }
  [[ "$mode" != host || "$(uname -s)" == Linux ]] || { error 'network_mode: host 仅支持 Linux Docker。'; return 1; }
  previous_mode="$(current_network_mode)"
  if [[ "$mode" == host ]]; then
    warn 'host 模式会让 NPM 使用宿主机网络；上游可填写 127.0.0.1:端口。'
    warn 'Compose 不会使用 ports 映射；80、81、443 必须由 NPM 独占。'
  else
    info 'bridge 模式采用官方默认端口映射：80:80、81:81、443:443。'
  fi
  port_conflicts
  if [[ -f "$COMPOSE_FILE" ]]; then
    confirm_action "确认将网络模式从 ${previous_mode} 切换为 ${mode} 并重建 NPM 容器？" || { info '已取消。'; return 0; }
    backup_deployment_files
    (cd "$INSTALL_DIR" && docker compose down) || { error '停止旧容器失败，未修改配置。'; return 1; }
  else
    confirm_action "确认以 ${mode} 网络模式部署 Nginx Proxy Manager？" || { info '已取消。'; return 0; }
    [[ -f "${DATA_DIR}/database.sqlite" ]] || first_deploy=1
  fi
  write_compose_file "$mode"
  if (cd "$INSTALL_DIR" && docker compose config >/dev/null && docker compose up -d); then
    success "Nginx Proxy Manager 已以 ${mode} 网络模式启动。"
    if [[ "$mode" == host ]]; then
      info '管理地址：http://服务器IP:81；为原生后端填写 127.0.0.1:端口。'
    else
      info '管理地址：http://服务器IP:81；容器化后端优先通过共享 Docker 网络访问。'
    fi
    (( first_deploy == 0 )) || show_initial_account_guidance
  else
    error 'NPM 启动失败。已保留部署文件备份；请查看日志并检查端口占用。'
    return 1
  fi
}

show_initial_account_guidance() {
  printf '\n%s首次登录提示%s\n' "$BOLD" "$RESET"
  printf '请在浏览器打开：http://服务器IP:81\n'
  printf '当前新版 Nginx Proxy Manager 首次启动会显示“创建管理员账户”页面。\n'
  printf '填写姓名、邮箱和新密码即可；没有应由 NPMCtl 显示的固定默认账号或密码。\n'
  warn '请妥善保存管理员密码。NPMCtl 不保存、显示或修改 NPM 用户凭据。'
}

switch_network_mode() {
  local current selected
  current="$(current_network_mode)"
  printf '\n当前网络模式：%s\n' "$current"
  printf '  1. bridge（官方默认，端口映射，网络隔离）\n'
  printf '  2. host（仅 Linux；可访问宿主机 127.0.0.1）\n'
  printf '  0. 返回\n'
  read -r -p '请选择 [0-2]：' selected
  case "$selected" in
    1) deploy_npm bridge ;;
    2) deploy_npm host ;;
    0) return 0 ;;
    *) error '无效选项。'; return 1 ;;
  esac
}

show_status() {
  local mode container_state image
  mode="$(current_network_mode)"
  printf '\n%sNginx Proxy Manager 状态%s\n' "$BOLD" "$RESET"
  printf '部署目录：%s\n网络模式：%s\n' "$INSTALL_DIR" "$mode"
  if ! command -v docker >/dev/null 2>&1; then warn 'Docker 未安装。'; return 0; fi
  container_state="$(docker inspect --format '{{.State.Status}}' nginx-proxy-manager 2>/dev/null || true)"
  image="$(docker inspect --format '{{.Config.Image}}' nginx-proxy-manager 2>/dev/null || true)"
  printf '容器状态：%s\n镜像：%s\n' "${container_state:-未创建}" "${image:-$NPM_IMAGE}"
  [[ -f "$COMPOSE_FILE" ]] && { printf '\nCompose 配置：\n'; sed -n '1,120p' "$COMPOSE_FILE"; }
}

show_logs() {
  require_docker || return 1
  docker logs --tail 160 nginx-proxy-manager 2>&1 || error '容器不存在或无法读取日志。'
}

show_listeners() {
  printf '\n%sNPM 端口与 Docker 映射%s\n' "$BOLD" "$RESET"
  command -v ss >/dev/null 2>&1 && ss -ltnp 2>/dev/null | sed -n '1p;/docker-proxy/p;/:80 /p;/:81 /p;/:443 /p' || warn '未找到 ss。'
  if command -v docker >/dev/null 2>&1; then
    printf '\n容器名称\t状态\t端口映射\n'
    docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
  fi
}

show_backend_guidance() {
  local mode
  mode="$(current_network_mode)"
  printf '\n%s后端连接建议%s\n' "$BOLD" "$RESET"
  if [[ "$mode" == host ]]; then
    cat <<'GUIDE'
当前为 host 模式。NPM 与宿主机共享网络命名空间：
  - 原生服务仅监听 127.0.0.1 时，在 NPM 中填写 127.0.0.1:服务端口。
  - Docker 应用可发布端口到宿主机，再以 127.0.0.1:宿主机端口访问。
  - 宿主机的 80、81、443 不可再由其他服务占用。
GUIDE
  else
    cat <<'GUIDE'
当前为官方默认 bridge 模式：
  - 容器内的 127.0.0.1 不是宿主机；不能直接代理宿主机回环服务。
  - 容器化后端优先让 NPM 与应用加入同一 Docker 网络，并填写 服务名:内部端口。
  - 宿主机后端需监听可被 Docker 网关访问的地址，或切换到 host 模式。
GUIDE
  fi
}

backup_data() {
  local archive item
  local -a backup_items=()
  [[ -d "$INSTALL_DIR" ]] || { error '尚未创建 NPM 部署。'; return 1; }
  for item in data letsencrypt compose.yml .env; do
    [[ -e "${INSTALL_DIR}/${item}" ]] && backup_items+=("$item")
  done
  (( ${#backup_items[@]} > 0 )) || { error '没有可备份的 NPM 数据或配置。'; return 1; }
  install -d -m 0750 "$BACKUP_DIR"
  archive="${BACKUP_DIR}/npmctl-data.$(timestamp).tar.gz"
  confirm_action "确认创建数据备份 ${archive}？" || { info '已取消。'; return 0; }
  tar -C "$INSTALL_DIR" -czf "$archive" "${backup_items[@]}" && success "备份完成：${archive}" || { rm -f "$archive"; error '备份失败。'; return 1; }
}

uninstall_menu() {
  local choice
  printf '\n  1. 停止并删除 NPM 容器（保留数据与配置）\n'
  printf '  2. 删除 NPMCtl 管理入口（保留 NPM、数据与配置）\n'
  printf '  3. 完全卸载 NPM 与 NPMCtl（删除数据、证书和备份）\n'
  printf '  0. 返回\n'
  read -r -p '请选择 [0-3]：' choice
  case "$choice" in
    1)
      require_docker || return 1
      confirm_action '确认停止并删除 NPM 容器？数据目录会保留。' || return 0
      [[ -f "$COMPOSE_FILE" ]] && (cd "$INSTALL_DIR" && docker compose down) || docker rm -f nginx-proxy-manager 2>/dev/null || true
      success 'NPM 容器已删除，数据仍保留在 /opt/npmctl。'
      ;;
    2)
      confirm_action '确认删除 npmctl 管理入口？' || return 0
      rm -f "$MANAGER_COMMAND" "$MANAGER_SCRIPT"
      rmdir "$MANAGER_DIR" 2>/dev/null || true
      success 'NPMCtl 管理入口已删除。'
      ;;
    3)
      warn '此操作会永久删除 NPM 容器、NPMCtl、/opt/npmctl 中的数据与证书，以及 /var/backups/npmctl。'
      confirm_action '确认完全卸载？此操作不可恢复。' || { info '已取消。'; return 0; }
      if command -v docker >/dev/null 2>&1; then
        if [[ -f "$COMPOSE_FILE" ]]; then
          (cd "$INSTALL_DIR" && docker compose down --remove-orphans) || docker rm -f nginx-proxy-manager 2>/dev/null || true
        else
          docker rm -f nginx-proxy-manager 2>/dev/null || true
        fi
        docker image rm "$NPM_IMAGE" 2>/dev/null || true
      fi
      rm -rf -- "$INSTALL_DIR" "$BACKUP_DIR"
      rm -f -- "$MANAGER_COMMAND" "$MANAGER_SCRIPT"
      rmdir "$MANAGER_DIR" 2>/dev/null || true
      success 'Nginx Proxy Manager、NPMCtl、运行数据和备份已完全删除。'
      ;;
    0) return 0 ;;
    *) error '无效选项。'; return 1 ;;
  esac
}

status_line() {
  local mode state
  mode="$(current_network_mode)"
  state="$(docker inspect --format '{{.State.Status}}' nginx-proxy-manager 2>/dev/null || printf '未部署')"
  printf 'NPM：%s | 网络：%s | NPMCtl：%s\n' "$state" "$mode" "$MANAGER_VERSION"
}

draw_menu() {
  clear 2>/dev/null || true
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '%s      NPMCtl · Nginx Proxy Manager 管理菜单%s\n' "$BOLD" "$RESET"
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  status_line
  printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
  printf '  1. 查看运行状态与 Compose 配置\n'
  printf '  2. 安装 Docker Engine 与 Compose\n'
  printf '  3. 部署或更新 Nginx Proxy Manager\n'
  printf '  4. 切换网络模式（bridge / host）\n'
  printf '  5. 查看后端连接建议\n'
  printf '  6. 查看 NPM 容器日志\n'
  printf '  7. 查看端口监听与 Docker 映射\n'
  printf '  8. 备份 NPM 数据与证书\n'
  printf '  9. 更新 NPMCtl 管理菜单\n'
  printf ' 10. 卸载 NPM 或 NPMCtl\n'
  printf '  0. 退出\n'
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '提示：退出后可在终端输入 npmctl 再次打开本菜单。\n'
}

main_menu() {
  local choice
  while true; do
    draw_menu
    read -r -p '请选择 [0-10]：' choice || exit 0
    printf '\n'
    case "$choice" in
      1) show_status; pause_menu ;;
      2) install_docker; pause_menu ;;
      3) deploy_npm "$(current_network_mode)"; pause_menu ;;
      4) switch_network_mode; pause_menu ;;
      5) show_backend_guidance; pause_menu ;;
      6) show_logs; pause_menu ;;
      7) show_listeners; pause_menu ;;
      8) backup_data; pause_menu ;;
      9) update_manager; pause_menu ;;
      10) uninstall_menu; pause_menu ;;
      0) exit 0 ;;
      *) warn '无效选项。'; pause_menu ;;
    esac
  done
}

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then show_command_usage; exit 0; fi
if [[ $# -eq 1 && "$1" == --install-manager ]]; then require_root "$@"; install_manager_command; success 'NPMCtl 管理菜单已安装。'; main_menu; exit 0; fi
if [[ $# -eq 1 && "$1" == --install ]]; then require_root "$@"; deploy_npm "$(current_network_mode)"; exit $?; fi
if [[ $# -eq 2 && "$1" == --network ]]; then require_root "$@"; deploy_npm "$2"; exit $?; fi
[[ $# -eq 0 ]] || { show_command_usage; exit 2; }
require_root "$@"
main_menu
