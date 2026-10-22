#!/usr/bin/env bash

# NPMCtl - an interactive Docker manager for Nginx Proxy Manager.
# It installs a separate `npmctl` command and keeps NPM's data in /opt/npmctl.

set -uo pipefail

readonly PROJECT_NAME="NPMCtl"
readonly MANAGER_VERSION="1.4.4"
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

pause_menu() { printf '\n'; read -r -p '按回车键返回主菜单...' _ || true; }
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
  info '正在重新加载新的管理菜单...'
  exec "$MANAGER_SCRIPT"
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

uninstall_docker() {
  local manager package
  local -a packages=() candidates=()

  warn '此操作会停止并删除本机所有 Docker 容器、镜像、卷和网络。'
  warn '同时会卸载 Docker Engine、Docker Compose，并删除 Docker 运行时数据。'
  warn 'NPMCtl 管理入口和 /opt/npmctl 中的数据不会被此项删除。'
  confirm_action '确认完全卸载 Docker 与 Compose？此操作不可恢复。' || { info '已取消。'; return 0; }

  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1 || true
      docker system prune -af --volumes >/dev/null 2>&1 || true
    else
      warn 'Docker 服务当前不可用，将继续清理软件包和运行时目录。'
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now docker docker.socket containerd 2>/dev/null || true
  fi

  if command -v apt-get >/dev/null 2>&1; then
    manager='apt-get'
    candidates=(docker.io docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose-v2 docker-compose docker-ce-rootless-extras)
    if command -v dpkg-query >/dev/null 2>&1; then
      for package in "${candidates[@]}"; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' && packages+=("$package")
      done
    fi
    ((${#packages[@]} > 0)) && apt-get purge -y "${packages[@]}" 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
  elif command -v dnf >/dev/null 2>&1; then
    manager='dnf'
    candidates=(docker docker-client docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose-v2 docker-compose docker-ce-rootless-extras)
    for package in "${candidates[@]}"; do
      rpm -q "$package" >/dev/null 2>&1 && packages+=("$package")
    done
    ((${#packages[@]} > 0)) && dnf remove -y "${packages[@]}" 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then
    manager='yum'
    candidates=(docker docker-client docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose-v2 docker-compose docker-ce-rootless-extras)
    for package in "${candidates[@]}"; do
      rpm -q "$package" >/dev/null 2>&1 && packages+=("$package")
    done
    ((${#packages[@]} > 0)) && yum remove -y "${packages[@]}" 2>/dev/null || true
  else
    manager='未知软件包管理器'
    warn '未识别 apt、dnf 或 yum；将继续删除 Docker 运行时文件。'
  fi

  rm -rf -- /var/lib/docker /var/lib/containerd /etc/docker /etc/containerd
  rm -f -- /usr/local/bin/docker-compose /usr/libexec/docker/cli-plugins/docker-compose /usr/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose /root/.docker/cli-plugins/docker-compose
  rm -f -- /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/yum.repos.d/docker-ce.repo
  success "Docker Engine 与 Compose 已完全卸载（使用 ${manager} 清理软件包）。"
}

config_value() { [[ -f "$CONFIG_FILE" ]] && sed -n "s/^$1=//p" "$CONFIG_FILE" | tail -n 1 || true; }
current_network_mode() { local mode; mode="$(config_value NETWORK_MODE)"; [[ "$mode" == host ]] && printf 'host\n' || printf 'bridge\n'; }

localize_network_mode() {
  case "$1" in
    bridge) printf '桥接网络（bridge）' ;;
    host) printf '宿主机网络（host）' ;;
    *) printf '%s' "${1:-未知}" ;;
  esac
}

short_network_mode() {
  case "$1" in
    bridge) printf '桥接' ;;
    host) printf '宿主机' ;;
    *) printf '%s' "${1:-未知}" ;;
  esac
}

localize_container_state() {
  case "$1" in
    created) printf '已创建' ;;
    restarting) printf '正在重启' ;;
    running) printf '运行中' ;;
    paused) printf '已暂停' ;;
    exited) printf '已停止' ;;
    dead) printf '异常终止' ;;
    '') printf '未创建' ;;
    *) printf '%s' "$1" ;;
  esac
}

write_config() {
  local mode="$1"
  install -d -m 0750 "$INSTALL_DIR" "$DATA_DIR" "$CERT_DIR"
  cat >"$CONFIG_FILE" <<EOF
# 由 NPMCtl 管理。请通过 npmctl --network bridge|host 切换网络模式。
NETWORK_MODE=${mode}
EOF
  chmod 0640 "$CONFIG_FILE"
}

write_compose_file() {
  local mode="$1"
  install -d -m 0750 "$INSTALL_DIR" "$DATA_DIR" "$CERT_DIR"
  if [[ "$mode" == host ]]; then
    cat >"$COMPOSE_FILE" <<EOF
# 由 NPMCtl 管理。Linux 宿主机网络模式：NPM 可访问宿主机的 127.0.0.1 服务。
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
# 由 NPMCtl 管理。官方默认：Docker 桥接网络，并发布所需端口。
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
  [[ "$mode" == bridge || "$mode" == host ]] || { error '网络模式必须为桥接网络（bridge）或宿主机网络（host）。'; return 1; }
  [[ "$mode" != host || "$(uname -s)" == Linux ]] || { error '宿主机网络（host）仅支持 Linux Docker。'; return 1; }
  previous_mode="$(current_network_mode)"
  if [[ "$mode" == host ]]; then
    warn '宿主机网络（host）会让 NPM 使用宿主机网络；上游可填写 127.0.0.1:端口。'
    warn 'Docker Compose 不会使用 ports 映射；80、81、443 必须由 NPM 独占。'
  else
    info '桥接网络（bridge）采用官方默认端口映射：80:80、81:81、443:443。'
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
    success "Nginx Proxy Manager 已以 $(localize_network_mode "$mode") 启动。"
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
  printf '\n当前网络模式：%s\n' "$(localize_network_mode "$current")"
  printf '  1. 桥接网络（bridge，官方默认，端口映射，网络隔离）\n'
  printf '  2. 宿主机网络（host，仅 Linux；可访问宿主机 127.0.0.1）\n'
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
  printf '部署目录：%s\n网络模式：%s\n' "$INSTALL_DIR" "$(localize_network_mode "$mode")"
  if ! command -v docker >/dev/null 2>&1; then warn 'Docker 未安装。'; return 0; fi
  container_state="$(docker inspect --format '{{.State.Status}}' nginx-proxy-manager 2>/dev/null || true)"
  image="$(docker inspect --format '{{.Config.Image}}' nginx-proxy-manager 2>/dev/null || true)"
  printf '容器状态：%s\n镜像：%s\n' "$(localize_container_state "$container_state")" "${image:-$NPM_IMAGE}"
  [[ -f "$COMPOSE_FILE" ]] && { printf '\nDocker Compose 配置（以下字段为 Docker 标准语法）：\n'; show_compose_config; }
}

show_compose_config() {
  sed \
    -e 's|^# Managed by NPMCtl\. Linux host network mode: NPM can reach host 127\.0\.0\.1 services\.$|# 由 NPMCtl 管理。Linux 宿主机网络模式：NPM 可访问宿主机的 127.0.0.1 服务。|' \
    -e 's|^# Managed by NPMCtl\. Official default: Docker bridge network with published ports\.$|# 由 NPMCtl 管理。官方默认：Docker 桥接网络，并发布所需端口。|' \
    -n '1,120p' "$COMPOSE_FILE"
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
    while IFS=$'\t' read -r name state ports; do
      printf '%s\t%s\t%s\n' "$name" "$(localize_container_state "$state")" "$ports"
    done < <(docker ps --format '{{.Names}}\t{{.State}}\t{{.Ports}}' 2>/dev/null)
  fi
}

backup_file() {
  local path="$1"
  local label="${2:-$(basename "$path")}"

  [[ -e "$path" ]] || return 0
  install -d -m 0750 "$BACKUP_DIR"
  cp -a -- "$path" "${BACKUP_DIR}/${label}.$(timestamp).bak"
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

is_local_upstream_host() {
  local host="$1"

  case "$host" in
    localhost|127.0.0.1|::1) return 0 ;;
  esac

  if command -v ip >/dev/null 2>&1 \
      && ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$host"; then
    return 0
  fi

  # Docker bridge gateways are host-side addresses, but some Docker/runtime
  # combinations do not expose the bridge interface through `ip addr`.
  command -v docker >/dev/null 2>&1 || return 1
  docker network ls -q 2>/dev/null | while read -r network_id; do
    docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' "$network_id" 2>/dev/null
  done | awk 'NF' | grep -Fxq "$host"
}

local_tcp_listener_details() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltnpH "sport = :$port" 2>/dev/null || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ (port "$")'
  fi
}

show_local_listener() {
  local port="$1"
  local listener

  printf '\n%s本机端口监听结果%s\n' "$BOLD" "$RESET"
  info "127.0.0.1 表示仅本机；* 或 0.0.0.0 表示所有 IPv4；具体 IP 表示仅该网卡。"
  if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
    warn "未找到 ss 或 netstat，无法查看本机监听状态。"
    return 0
  fi
  listener="$(local_tcp_listener_details "$port")"
  if [[ -n "$listener" ]]; then
    printf '%s\n' "$listener"
  else
    warn "未发现 TCP 端口 $port 处于监听状态。"
  fi
}

docker_published_listener_services() {
  local container_id

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    docker inspect --format '{{range $containerPort, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{printf "%s\t%s\t%s\t" .HostIp .HostPort $containerPort}}{{with index $.Config.Labels "com.docker.compose.service"}}{{.}}{{else}}{{$.Name}}{{end}}{{println}}{{end}}{{end}}' "$container_id" 2>/dev/null
  done < <(docker ps -q 2>/dev/null)
}

format_listener_table() {
  local docker_services="$1"
  local listener_command="$2"

  awk -v docker_services="$docker_services" -v listener_command="$listener_command" '
    function normalized_host(host) {
      sub(/^\[/, "", host)
      sub(/\]$/, "", host)
      return host
    }
    function add_service(services, key, service, current) {
      current = services[key]
      if (current == "") {
        services[key] = service
      } else if (index("," current ",", "," service ",") == 0) {
        services[key] = current "," service
      }
    }
    function visible_length(value) {
      return value == "未知" ? 4 : length(value)
    }
    function print_spaces(count, i) {
      for (i = 0; i < count; i++) {
        printf " "
      }
    }
    function print_header_field(label, label_width, field_width) {
      printf "%s", label
      print_spaces(field_width - label_width + 2)
    }
    function print_data_field(value, field_width) {
      printf "%s", value
      print_spaces(field_width - visible_length(value) + 2)
    }
    function print_table_header() {
      if (listener_command == "netstat") {
        print_header_field("协议", 4, width[1])
      } else {
        print_header_field("状态", 4, width[1])
      }
      print_header_field("接收队列", 8, width[2])
      print_header_field("发送队列", 8, width[3])
      print_header_field("本地监听地址:端口", 17, width[4])
      print_header_field("服务实际端口", 12, width[5])
      if (listener_command == "netstat") {
        print_header_field("状态", 4, width[6])
        print_header_field("服务名称", 8, width[7])
      } else {
        print_header_field("服务名称", 8, width[6])
      }
      print "进程"
    }
    BEGIN {
      width[1] = 7
      width[2] = 8
      width[3] = 8
      width[4] = 18
      width[5] = 14
      width[6] = 7
      width[7] = 12
      if (listener_command != "netstat") {
        width[6] = 12
      }
      mapping_count = split(docker_services, mappings, "\n")
      for (i = 1; i <= mapping_count; i++) {
        field_count = split(mappings[i], fields, "\t")
        if (field_count < 4 || fields[1] == "" || fields[2] == "" || fields[3] == "" || fields[4] == "") {
          continue
        }
        sub(/^\/+/, "", fields[4])
        host = normalized_host(fields[1])
        add_service(service_by_binding, host SUBSEP fields[2], fields[4])
        add_service(service_by_port, fields[2], fields[4])
        add_service(actual_port_by_binding, host SUBSEP fields[2], fields[3])
        add_service(actual_port_by_port, fields[2], fields[3])
      }
    }
    listener_command == "netstat" && NR <= 2 {
      next
    }
    listener_command != "netstat" && NR == 1 {
      next
    }
    NF < (listener_command == "netstat" ? 6 : 5) {
      next
    }
    {
      process_field = listener_command == "netstat" ? 7 : 6
      process = ""
      for (i = process_field; i <= NF; i++) {
        process = process (process == "" ? "" : " ") $i
      }
      service = "-"
      address = $4
      port = address
      sub(/^.*:/, "", port)
      host = address
      sub(/:[^:]*$/, "", host)
      host = normalized_host(host)
      actual_port = port "/tcp"
      if (process ~ /docker-proxy/) {
        service = service_by_binding[host SUBSEP port]
        if (service == "") {
          service = service_by_port[port]
        }
        if (service == "") {
          service = "未知"
        }
        actual_port = actual_port_by_binding[host SUBSEP port]
        if (actual_port == "") {
          actual_port = actual_port_by_port[port]
        }
        if (actual_port == "") {
          actual_port = "未知"
        }
      }
      row_count++
      field[row_count, 1] = $1
      field[row_count, 2] = $2
      field[row_count, 3] = $3
      field[row_count, 4] = $4
      field[row_count, 5] = actual_port
      if (listener_command == "netstat") {
        field[row_count, 6] = $6
        field[row_count, 7] = service
        field[row_count, 8] = process
        for (i = 1; i <= 7; i++) {
          if (visible_length(field[row_count, i]) > width[i]) {
            width[i] = visible_length(field[row_count, i])
          }
        }
      } else {
        field[row_count, 6] = service
        field[row_count, 7] = process
        for (i = 1; i <= 6; i++) {
          if (visible_length(field[row_count, i]) > width[i]) {
            width[i] = visible_length(field[row_count, i])
          }
        }
      }
    }
    END {
      if (listener_command == "netstat") {
        print "TCP 监听端口（仅服务端）"
      }
      print_table_header()
      for (row = 1; row <= row_count; row++) {
        if (listener_command == "netstat") {
          for (i = 1; i <= 7; i++) {
            print_data_field(field[row, i], width[i])
          }
          print field[row, 8]
        } else {
          for (i = 1; i <= 6; i++) {
            print_data_field(field[row, i], width[i])
          }
          print field[row, 7]
        }
      }
    }
  '
}

localize_ss_listener_header() {
  local docker_services

  docker_services="$(docker_published_listener_services)"
  format_listener_table "$docker_services" ss
}

localize_netstat_listener_header() {
  local docker_services

  docker_services="$(docker_published_listener_services)"
  format_listener_table "$docker_services" netstat
}

show_all_local_listeners() {
  printf '\n%s本机 TCP 服务监听地址%s\n' "$BOLD" "$RESET"
  info "127.0.0.1 表示仅本机；* 或 0.0.0.0 表示所有 IPv4；具体 IP 表示仅该网卡。"
  info "服务实际端口：Docker 显示容器内部端口；systemd 和普通进程显示本地监听端口。"
  info "docker-proxy 表示宿主机发布端口；服务名称列优先显示 Compose 服务名，否则显示容器名。"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | localize_ss_listener_header
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | localize_netstat_listener_header
  else
    warn "未找到 ss 或 netstat，无法查看本机监听状态。"
  fi
}

listener_pid_from_details() {
  sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1
}

listener_process_from_details() {
  sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1
}

is_valid_ipv4() {
  local address="$1" octet

  [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a octet <<< "$address"
  (( ${#octet[@]} == 4 )) || return 1
  for address in "${octet[@]}"; do
    (( 10#$address <= 255 )) || return 1
  done
}

is_npm_container() {
  local image="${1,,}"
  local container_name="${2,,}"

  # Monitoring/sidecar containers often reuse the NPM name prefix but are not
  # the proxy manager that should receive gateway traffic.
  case "$image:$container_name" in
    *monitor*|*metrics*|*exporter*) return 1 ;;
  esac

  case "$image" in
    *nginx*proxy*manager*|jc21/*) return 0 ;;
  esac
  case "$container_name" in
    npm|npm-*|nginx-proxy-manager|nginx-proxy-manager-*) return 0 ;;
  esac
  return 1
}

find_npm_containers() {
  local container_id image container_name

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  while IFS='|' read -r container_id image container_name; do
    is_npm_container "$image" "$container_name" || continue
    printf '%s\t%s\t%s\n' "$container_id" "$container_name" "$image"
  done < <(docker ps --format '{{.ID}}|{{.Image}}|{{.Names}}' 2>/dev/null)
}

docker_gateway_targets_for_container() {
  local container_reference="$1"
  local container_id container_name network gateway

  IFS='|' read -r container_id container_name < <(docker inspect --format '{{.Id}}|{{.Name}}' "$container_reference" 2>/dev/null)
  [[ -n "$container_id" && -n "$container_name" ]] || return 0
  container_name="${container_name#/}"
  while IFS='|' read -r network gateway; do
    is_valid_ipv4 "$gateway" || continue
    printf '%s\t%s\t%s\t%s\n' "$container_id" "$container_name" "$network" "$gateway"
  done < <(docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}|{{$network.Gateway}}{{println}}{{end}}' "$container_reference" 2>/dev/null)
}

docker_npm_compatibility_targets() {
  local container_reference="$1"
  local container_id container_name attached_targets default_bridge_gateway

  IFS='|' read -r container_id container_name < <(docker inspect --format '{{.Id}}|{{.Name}}' "$container_reference" 2>/dev/null)
  [[ -n "$container_id" && -n "$container_name" ]] || return 0
  container_name="${container_name#/}"
  attached_targets="$(docker_gateway_targets_for_container "$container_id")"
  [[ -z "$attached_targets" ]] || printf '%s\n' "$attached_targets"

  default_bridge_gateway="$(docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' bridge 2>/dev/null || true)"
  is_valid_ipv4 "$default_bridge_gateway" || return 0
  if ! awk -F '\t' '$3 == "bridge" { found = 1 } END { exit !found }' <<< "$attached_targets"; then
    printf '%s\t%s\t%s\t%s\n' "$container_id" "$container_name" 'bridge（Docker系统默认）' "$default_bridge_gateway"
  fi
}

show_running_docker_containers() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  printf '\n运行中的 Docker 容器（短 ID | 名称 | 镜像）：\n'
  docker ps --format '{{.ID}} | {{.Names}} | {{.Image}}' 2>/dev/null
}

show_docker_container_internal_listeners() {
  local container_reference="$1"
  local container_name="$2"
  local exposed_ports

  printf '\n%sDocker 容器内部监听%s\n' "$BOLD" "$RESET"
  printf '容器：%s\n' "$container_name"
  printf '容器网络 IP（仅供诊断，NPM 共享网络优先使用服务名）：\n'
  docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}  {{$name}}: {{$network.IPAddress}}{{println}}{{end}}' "$container_reference" 2>/dev/null || true

  if docker exec "$container_reference" ss -ltnp >/dev/null 2>&1; then
    info "以下为容器网络空间中的实际 TCP 监听地址。"
    docker exec "$container_reference" ss -ltnp 2>/dev/null | localize_ss_listener_header
    return 0
  fi
  if docker exec "$container_reference" netstat -ltnp >/dev/null 2>&1; then
    info "以下为容器网络空间中的实际 TCP 监听地址。"
    docker exec "$container_reference" netstat -ltnp 2>/dev/null | localize_netstat_listener_header
    return 0
  fi

  warn "容器内未找到 ss 或 netstat，无法直接检测实际监听地址。"
  exposed_ports="$(docker inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$container_reference" 2>/dev/null || true)"
  if [[ -n "$exposed_ports" ]]; then
    printf '镜像声明端口（不等同于实际监听）：\n%s\n' "$exposed_ports"
  else
    warn "镜像未声明 EXPOSE 端口，请根据应用启动参数或日志确认容器内部端口。"
  fi
}

show_all_docker_internal_listeners() {
  local container_id container_name count=0
  local network_ips listeners exposed_ports detection table

  command -v docker >/dev/null 2>&1 || {
    error "未检测到 Docker 命令。"
    return 1
  }
  docker info >/dev/null 2>&1 || {
    error "无法连接 Docker 服务。"
    return 1
  }
  printf '\n%s全部运行中 Docker 容器的内部监听%s\n' "$BOLD" "$RESET"
  table=$'容器名称\t网络 IP（仅诊断）\t内部 TCP 监听\t检测方式'
  while IFS='|' read -r container_id container_name; do
    [[ -n "$container_id" && -n "$container_name" ]] || continue
    ((count += 1))

    network_ips="$(docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}={{$network.IPAddress}}{{println}}{{end}}' "$container_id" 2>/dev/null | awk 'NF' | paste -sd ',' -)"
    [[ -n "$network_ips" ]] || network_ips="-"

    listeners=""
    detection=""
    if docker exec "$container_id" ss -ltnH >/dev/null 2>&1; then
      listeners="$(docker exec "$container_id" ss -ltnH 2>/dev/null | awk '$4 !~ /^127\.0\.0\.11:/ {print $4}' | paste -sd ',' -)"
      detection="ss 实际检测"
    elif docker exec "$container_id" netstat -ltn >/dev/null 2>&1; then
      listeners="$(docker exec "$container_id" netstat -ltn 2>/dev/null | awk '$1 ~ /^tcp/ && $4 !~ /^127\.0\.0\.11:/ {print $4}' | paste -sd ',' -)"
      detection="netstat 实际检测"
    else
      exposed_ports="$(docker inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$container_id" 2>/dev/null | awk 'NF' | paste -sd ',' -)"
      if [[ -n "$exposed_ports" ]]; then
        listeners="声明：${exposed_ports}"
        detection="无检测工具；仅镜像声明"
      else
        listeners="-"
        detection="无检测工具；未声明端口"
      fi
    fi
    [[ -n "$listeners" ]] || listeners="-"
    table+=$'\n'"${container_name}"$'\t'"${network_ips}"$'\t'"${listeners}"$'\t'"${detection}"
  done < <(docker ps --format '{{.ID}}|{{.Names}}' 2>/dev/null)
  if (( count == 0 )); then
    warn "未发现运行中的 Docker 容器。"
    return 0
  fi

  if command -v column >/dev/null 2>&1; then
    printf '%s\n' "$table" | column -t -s $'\t'
  else
    printf '%s\n' "$table"
  fi
  info "网络 IP 仅用于诊断；NPM 共享网络反代请填写 Docker Compose 服务名和容器内部端口。"
}

docker_network_mode_for_container() {
  docker inspect --format '{{.HostConfig.NetworkMode}}' "$1" 2>/dev/null || true
}

find_npm_gateway_targets() {
  local container_id image container_name

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  while IFS='|' read -r container_id image container_name; do
    is_npm_container "$image" "$container_name" || continue
    docker_npm_compatibility_targets "$container_id"
  done < <(docker ps --format '{{.ID}}|{{.Image}}|{{.Names}}' 2>/dev/null)
}

preferred_npm_gateway_target() {
  local target container_id container_name network gateway
  local -a targets=("$@")

  (( ${#targets[@]} > 0 )) || return 1
  # NPMCtl creates npmctl_default. Prefer it when NPM is attached to several
  # bridge networks, then fall back to Docker's default bridge.
  for target in "${targets[@]}"; do
    IFS=$'\t' read -r container_id container_name network gateway <<< "$target"
    if [[ "$network" == npmctl_default ]]; then
      printf '%s\n' "$target"
      return 0
    fi
  done
  for target in "${targets[@]}"; do
    IFS=$'\t' read -r container_id container_name network gateway <<< "$target"
    if [[ "$network" == bridge ]]; then
      printf '%s\n' "$target"
      return 0
    fi
  done
  printf '%s\n' "${targets[0]}"
}

verify_npm_gateway_connection() {
  local container_id="$1"
  local container_name="$2"
  local gateway="$3"
  local port="$4"
  local node_check

  node_check='const net = require("net");
const host = process.argv[1];
const port = Number(process.argv[2]);
const socket = net.createConnection({ host, port });
socket.setTimeout(5000);
socket.on("connect", () => { socket.end(); process.exit(0); });
socket.on("timeout", () => { socket.destroy(); process.exit(1); });
socket.on("error", () => process.exit(1));'

  printf '\n%sNPM 容器连通性验证%s\n' "$BOLD" "$RESET"
  if docker exec "$container_id" node -e "$node_check" "$gateway" "$port" >/dev/null 2>&1; then
    success "NPM 容器 ${container_name} 可连接 Kopia：${gateway}:${port}。"
    info "请在 Nginx Proxy Manager 中将“转发主机名/IP”设为 ${gateway}，端口设为 ${port}，协议使用 http。"
    return 0
  fi

  warn "NPM 容器 ${container_name} 无法连接 ${gateway}:${port}。请检查 Docker 网络、服务重启结果及主机防火墙。"
  return 1
}

systemd_unit_for_pid() {
  local pid="$1"

  [[ -r "/proc/$pid/cgroup" ]] || return 1
  awk -F/ '{for (i = NF; i > 0; i--) if ($i ~ /\.service$/) { print $i; exit }}' \
    "/proc/$pid/cgroup"
}

kopia_default_config_path_for_user() {
  local user="$1"
  local home_dir="$2"
  local xdg_config_home="$3"
  local config_root candidate

  if [[ -z "$home_dir" ]]; then
    home_dir="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  fi
  [[ -n "$home_dir" ]] || return 0
  config_root="${xdg_config_home:-${home_dir}/.config}"
  candidate="${config_root}/kopia/repository.config"
  [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
}

kopia_environment_exports() {
  local pid="$1"
  local environment_item name value
  local run_user home_dir="" xdg_config_home="" config_path=""
  local has_config_path="false"

  [[ -r "/proc/$pid/environ" ]] || return 0
  run_user="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  while IFS= read -r -d '' environment_item; do
    name="${environment_item%%=*}"
    value="${environment_item#*=}"
    case "$name" in
      HOME) home_dir="$value" ;;
      XDG_CONFIG_HOME) xdg_config_home="$value" ;;
      KOPIA_CONFIG_PATH) has_config_path="true" ;;
    esac
    if [[ "$name" == "HOME" || "$name" == "XDG_CONFIG_HOME" || "$name" =~ ^KOPIA_[A-Za-z0-9_]+$ ]]; then
      printf 'export %s=%q\n' "$name" "$value"
    fi
  done < "/proc/$pid/environ"

  if [[ "$has_config_path" != "true" && -n "$run_user" ]]; then
    config_path="$(kopia_default_config_path_for_user "$run_user" "$home_dir" "$xdg_config_home")"
    [[ -n "$config_path" ]] && printf 'export KOPIA_CONFIG_PATH=%q\n' "$config_path"
  fi
}

apply_kopia_listener_address() {
  local pid="$1"
  local port="$2"
  local bind_host="$3"
  local unit wrapper_dir wrapper_path override_dir override_path
  local previous_wrapper="" previous_override="" had_wrapper="false" had_override="false"
  local temp_wrapper temp_override arg attempt listener_ready="false"
  local -a command filtered
  local i has_server="false" has_start="false"

  unit="$(systemd_unit_for_pid "$pid")"
  if [[ -z "$unit" || ! "$unit" =~ ^[A-Za-z0-9_.@-]+\.service$ ]]; then
    error "未找到 Kopia 对应的 systemd 服务，无法安全自动修改。"
    return 1
  fi
  case "$(systemctl show "$unit" --property=Type --value 2>/dev/null)" in
    simple|exec) ;;
    *)
      error "仅支持 Type=simple 或 Type=exec 的 systemd Kopia 服务，当前服务类型不支持自动修改。"
      return 1
      ;;
  esac
  if ! mapfile -d '' -t command < "/proc/$pid/cmdline" || [[ ${#command[@]} -eq 0 ]]; then
    error "无法读取当前 Kopia 启动命令。"
    return 1
  fi
  if [[ "$(basename "${command[0]}")" != "kopia" ]]; then
    error "当前进程不是直接由 kopia 命令启动，无法安全自动修改。"
    return 1
  fi
  for arg in "${command[@]}"; do
    [[ "$arg" == "server" ]] && has_server="true"
    [[ "$arg" == "start" ]] && has_start="true"
  done
  if [[ "$has_server" != "true" || "$has_start" != "true" ]]; then
    error "当前 Kopia 命令不是 server start 模式，无法安全自动修改。"
    return 1
  fi

  for ((i = 0; i < ${#command[@]}; i++)); do
    arg="${command[$i]}"
    if [[ "$arg" == "--address" ]]; then
      ((i++))
      continue
    fi
    [[ "$arg" == --address=* ]] && continue
    filtered+=("$arg")
  done
  filtered+=("--address=${bind_host}:${port}")

  wrapper_dir="${MANAGER_DIR}/service-wrappers"
  wrapper_path="${wrapper_dir}/${unit}.sh"
  override_dir="/etc/systemd/system/${unit}.d"
  override_path="${override_dir}/npmctl-listener.conf"
  temp_wrapper="$(mktemp)" || return 1
  temp_override="$(mktemp)" || { rm -f -- "$temp_wrapper"; return 1; }
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    kopia_environment_exports "$pid"
    printf 'exec'
    for arg in "${filtered[@]}"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  } >"$temp_wrapper"
  printf '[Service]\nExecStart=\nExecStart=%s\n' "$wrapper_path" >"$temp_override"

  if [[ -f "$wrapper_path" ]]; then
    had_wrapper="true"
    previous_wrapper="$(mktemp)"
    cp -a -- "$wrapper_path" "$previous_wrapper"
    backup_file "$wrapper_path" "${unit}-listener-wrapper"
  fi
  if [[ -f "$override_path" ]]; then
    had_override="true"
    previous_override="$(mktemp)"
    cp -a -- "$override_path" "$previous_override"
    backup_file "$override_path" "${unit}-listener-override"
  fi

  install -d -m 0700 "$wrapper_dir" "$override_dir"
  install -m 0700 "$temp_wrapper" "$wrapper_path"
  install -m 0600 "$temp_override" "$override_path"
  rm -f -- "$temp_wrapper" "$temp_override"
  systemctl daemon-reload
  if systemctl restart "$unit" && systemctl is-active --quiet "$unit"; then
    for ((attempt = 1; attempt <= 10; attempt++)); do
      if generic_listener_is_listening_on "$port" "$bind_host"; then
        listener_ready="true"
        break
      fi
      sleep 1
    done
  fi
  if [[ "$listener_ready" == "true" ]]; then
    rm -f -- "$previous_wrapper" "$previous_override"
    success "Kopia 监听地址已更新为 ${bind_host}:${port}。"
    if [[ "$bind_host" == "127.0.0.1" ]]; then
      info "请使用第 6 项检查对应站点，将后端服务地址同步改为 127.0.0.1。"
    fi
    show_local_listener "$port"
    return 0
  fi

  error "Kopia 重启或监听验证失败，正在恢复原有启动配置。"
  if [[ "$had_wrapper" == "true" ]]; then
    install -m 0700 "$previous_wrapper" "$wrapper_path"
  else
    rm -f -- "$wrapper_path"
  fi
  if [[ "$had_override" == "true" ]]; then
    install -m 0600 "$previous_override" "$override_path"
  else
    rm -f -- "$override_path"
  fi
  rm -f -- "$previous_wrapper" "$previous_override"
  systemctl daemon-reload
  systemctl restart "$unit" >/dev/null 2>&1 || true
  return 1
}

adopt_manual_kopia_service() {
  local pid="$1"
  local port="$2"
  local unit="npmctl-kopia-${port}.service"
  local unit_path="/etc/systemd/system/${unit}"
  local wrapper_dir="${MANAGER_DIR}/service-wrappers"
  local wrapper_path="${wrapper_dir}/${unit}.sh"
  local run_user parent_pid
  local temp_wrapper temp_unit argument
  local -a command
  local i has_server="false" has_start="false"

  if [[ -e "$unit_path" ]] || systemctl cat "$unit" >/dev/null 2>&1; then
    error "systemd 服务 ${unit} 已存在，NPMCtl 不会覆盖它。请先检查或删除该服务后重试。"
    return 1
  fi
  if ! mapfile -d '' -t command < "/proc/$pid/cmdline" || [[ ${#command[@]} -eq 0 ]]; then
    error "无法读取当前 Kopia 启动命令。"
    return 1
  fi
  if [[ "$(basename "${command[0]}")" != "kopia" ]]; then
    error "当前进程不是直接由 kopia 命令启动，无法安全接管。"
    return 1
  fi
  for argument in "${command[@]}"; do
    [[ "$argument" == "server" ]] && has_server="true"
    [[ "$argument" == "start" ]] && has_start="true"
  done
  if [[ "$has_server" != "true" || "$has_start" != "true" ]]; then
    error "当前 Kopia 命令不是 server start 模式，无法安全接管。"
    return 1
  fi
  run_user="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "$run_user" ]] || ! id "$run_user" >/dev/null 2>&1; then
    error "无法识别 Kopia 进程的运行用户，无法安全接管。"
    return 1
  fi
  parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ "$parent_pid" != "1" ]]; then
    error "Kopia 的父进程为 PID ${parent_pid:-未知}，可能仍受脚本或面板管理；请先在原管理器中停止它，再改用 systemd。"
    return 1
  fi
  temp_wrapper="$(mktemp)" || return 1
  temp_unit="$(mktemp)" || { rm -f -- "$temp_wrapper"; return 1; }
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    kopia_environment_exports "$pid"
    printf 'exec'
    for argument in "${command[@]}"; do
      printf ' %q' "$argument"
    done
    printf '\n'
  } >"$temp_wrapper"
  {
    printf '[Unit]\nDescription=NPMCtl managed Kopia server on TCP %s\n' "$port"
    printf 'Wants=network-online.target\nAfter=network-online.target\n\n'
    printf '[Service]\nType=simple\n'
    [[ "$run_user" != "root" ]] && printf 'User=%s\n' "$run_user"
    printf 'ExecStart=%s\nRestart=on-failure\nRestartSec=5\n\n' "$wrapper_path"
    printf '[Install]\nWantedBy=multi-user.target\n'
  } >"$temp_unit"

  warn "将接管 PID ${pid} 的手工 Kopia 进程，保留当前启动参数并创建 ${unit}。"
  info "将保留 HOME、XDG_CONFIG_HOME 以及 KOPIA_* 环境变量，并优先沿用原存储库配置。"
  confirm_action "确认停止当前手工进程并启用 ${unit}？" || {
    rm -f -- "$temp_wrapper" "$temp_unit"
    info "已取消。"
    return 0
  }

  install -d -m 0700 "$wrapper_dir"
  install -m 0700 "$temp_wrapper" "$wrapper_path"
  install -m 0644 "$temp_unit" "$unit_path"
  rm -f -- "$temp_wrapper" "$temp_unit"
  systemctl daemon-reload
  if ! kill -TERM "$pid" 2>/dev/null; then
    error "无法停止当前手工 Kopia 进程，未启动新的 systemd 服务。"
    rm -f -- "$wrapper_path" "$unit_path"
    systemctl daemon-reload
    return 1
  fi
  for ((i = 0; i < 25; i++)); do
    [[ -d "/proc/$pid" ]] || break
    sleep 0.2
  done
  if [[ -d "/proc/$pid" ]]; then
    error "当前手工 Kopia 进程未在 5 秒内退出，未启动新的 systemd 服务。"
    rm -f -- "$wrapper_path" "$unit_path"
    systemctl daemon-reload
    return 1
  fi
  if systemctl start "$unit"; then
    systemctl enable "$unit" >/dev/null 2>&1 || warn "服务已启动，但未能设置开机自启：$unit"
    success "已接管为 systemd 服务：${unit}。"
    return 0
  fi

  error "systemd 服务启动失败，正在尝试恢复原手工启动方式。"
  systemctl stop "$unit" >/dev/null 2>&1 || true
  "$wrapper_path" >/dev/null 2>&1 &
  rm -f -- "$wrapper_path" "$unit_path"
  systemctl daemon-reload
  warn "已尝试按原命令恢复 Kopia。请使用 ss 或 npmctl 菜单确认端口监听状态。"
  return 1
}

manage_kopia_listener() {
  local port="$1"
  local listener="$2"
  local pid unit mode bind_host process_info parent_pid
  local -a npm_targets
  local npm_target npm_container_id npm_container_name npm_network npm_gateway
  local manual_container npm_network_mode

  pid="$(printf '%s\n' "$listener" | listener_pid_from_details)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { error "无法识别 Kopia 进程 PID。"; return 1; }
  unit="$(systemd_unit_for_pid "$pid")"
  printf '\n%sKopia 监听地址修改%s\n' "$BOLD" "$RESET"
  printf '当前监听：\n%s\n' "$listener"
  printf '关联 systemd 服务：%s\n' "${unit:-未识别}"
  if [[ -z "$unit" ]]; then
    process_info="$(ps -o pid=,ppid=,user=,comm= -p "$pid" 2>/dev/null || true)"
    parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [[ -n "$process_info" ]] && info "进程信息（PID/父进程/用户/命令）：$process_info"
    if [[ "$parent_pid" != "1" ]]; then
      warn "Kopia 当前可能仍由脚本或面板管理，菜单不会直接接管以避免原管理器重新拉起进程。"
      info "请先在原脚本或面板中停止并禁用 Kopia，再以 systemd 方式启动。"
      return 1
    fi
    warn "Kopia 当前是已脱离终端的手工命令（由 PID 1 收养），不是 systemd 服务。"
    printf '  1. 接管为 NPMCtl 管理的 systemd 服务（保留当前启动参数）\n'
    printf '  0. 返回\n'
    read -r -p "请选择 [0-1]：" mode
    case "$mode" in
      1)
        if adopt_manual_kopia_service "$pid" "$port"; then
          listener="$(local_tcp_listener_details "$port")"
          if [[ -n "$listener" ]] && [[ "$(printf '%s\n' "$listener" | listener_process_from_details)" == "kopia" ]]; then
            manage_kopia_listener "$port" "$listener"
          else
            warn "接管后的 Kopia 监听状态尚未识别，请稍后重新打开端口助手检查。"
          fi
        fi
        return
        ;;
      0) return 0 ;;
      *) error "无效选项：$mode"; return 1 ;;
    esac
  fi
  printf '  1. 仅服务器本机：127.0.0.1:%s（供宿主机上的 NPM、Nginx 等反代访问）\n' "$port"
  printf '  2. Docker NPM 访问宿主机服务（网关模式，自动识别并验证）\n'
  printf '  3. 允许服务器公网 IP 访问：0.0.0.0:%s（需配合防火墙）\n' "$port"
  printf '  0. 返回\n'
  read -r -p "请选择 [0-3]：" mode

  case "$mode" in
    1) bind_host="127.0.0.1" ;;
    2)
      mapfile -t npm_targets < <(find_npm_gateway_targets)
      if (( ${#npm_targets[@]} == 0 )); then
        warn "未自动识别到带 IPv4 Docker 网络网关的 Nginx Proxy Manager 容器。"
        show_running_docker_containers
        read -r -p "输入 NPM 容器名称或 ID（直接回车返回）:" manual_container
        [[ -n "$manual_container" ]] || return 0
        mapfile -t npm_targets < <(docker_gateway_targets_for_container "$manual_container")
        if (( ${#npm_targets[@]} == 0 )); then
          npm_network_mode="$(docker_network_mode_for_container "$manual_container")"
          if [[ "$npm_network_mode" == "host" ]]; then
            warn "该容器使用 host 网络，NPM 可直接访问宿主机 127.0.0.1。请返回并选择“仅服务器本机”模式。"
          else
            error "容器 ${manual_container} 未找到 IPv4 Docker 网络网关。请确认名称正确且容器正在使用 bridge 网络。"
          fi
          return 1
        fi
      fi
      if (( ${#npm_targets[@]} == 1 )); then
        npm_target="${npm_targets[0]}"
      else
        printf '\n检测到多个 NPM Docker 网络：\n'
        local i selection
        for ((i = 0; i < ${#npm_targets[@]}; i++)); do
          IFS=$'\t' read -r npm_container_id npm_container_name npm_network npm_gateway <<< "${npm_targets[$i]}"
          printf '  %d. 容器 %s，网络 %s，网关 %s\n' "$((i + 1))" "$npm_container_name" "$npm_network" "$npm_gateway"
        done
        read -r -p "请选择 [1-${#npm_targets[@]}]：" selection
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#npm_targets[@]} )); then
          error "无效选项：$selection"
          return 1
        fi
        npm_target="${npm_targets[$((selection - 1))]}"
      fi
      IFS=$'\t' read -r npm_container_id npm_container_name npm_network npm_gateway <<< "$npm_target"
      if ! is_local_upstream_host "$npm_gateway"; then
        error "Docker 网关 ${npm_gateway} 未出现在本机网卡地址中，无法安全作为 Kopia 监听地址。"
        return 1
      fi
      bind_host="$npm_gateway"
      info "检测到 NPM 容器 ${npm_container_name}，网络 ${npm_network}，网关 ${npm_gateway}。"
      info "Kopia 将仅监听 Docker 网络网关；该模式不直接开放公网端口。"
      warn "同一 Docker 网络中的其他容器也可访问 ${npm_gateway}:${port}。"
      ;;
    3)
      bind_host="0.0.0.0"
      warn "此端口将接受所有 IPv4 网络接口的连接，请仅在防火墙允许可信来源。"
      ;;
    0) return 0 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac

  warn "将为 $unit 创建 NPMCtl 管理的启动覆盖文件，并重启 Kopia 服务。"
  confirm_action "确认修改 Kopia 监听地址为 ${bind_host}:${port}？" || { info "已取消。"; return 0; }
  if apply_kopia_listener_address "$pid" "$port" "$bind_host"; then
    if [[ "$mode" == "2" ]]; then
      verify_npm_gateway_connection "$npm_container_id" "$npm_container_name" "$npm_gateway" "$port" || true
    fi
  fi
}

generic_systemd_rollback_paths() {
  local unit="$1"
  local port="$2"
  local rollback_dir="${MANAGER_DIR}/listener-rollbacks"

  printf '%s\t%s\n' \
    "${rollback_dir}/${unit}-${port}.rollback" \
    "${rollback_dir}/${unit}-${port}.before-change.bak"
}

generic_listener_is_listening_on() {
  local port="$1"
  local bind_host="$2"
  local listener

  listener="$(local_tcp_listener_details "$port")"
  [[ -n "$listener" ]] || return 1
  if [[ "$bind_host" == "0.0.0.0" ]]; then
    grep -Eq "(0\\.0\\.0\\.0|\\*):${port}([^0-9]|$)" <<< "$listener"
  else
    grep -Fq -- "${bind_host}:${port}" <<< "$listener"
  fi
}

show_generic_systemd_service_details() {
  local unit="$1"

  printf '\n%s%s 服务详情%s\n' "$BOLD" "$unit" "$RESET"
  systemctl show "$unit" \
    --property=Id,Description,ActiveState,SubState,Type,ExecStart,Environment,FragmentPath \
    --no-pager 2>/dev/null || true
  printf '\n%s服务定义与覆盖文件%s\n' "$BOLD" "$RESET"
  systemctl cat "$unit" --no-pager 2>/dev/null || true
}

prompt_generic_systemd_bind_host() {
  local port="$1"
  local mode manual_host manual_container npm_network_mode selection i
  local npm_target npm_container_id npm_container_name npm_network npm_gateway
  local -a npm_targets

  GENERIC_BIND_HOST=""
  GENERIC_NPM_CONTAINER_ID=""
  GENERIC_NPM_CONTAINER_NAME=""
  GENERIC_NPM_GATEWAY=""
  printf '  1. [宿主机 NPM] 仅本机反代：127.0.0.1:%s（Docker NPM 不可访问）\n' "$port"
  printf '  2. [Docker NPM] 经 Docker 网关访问（自动识别；需应用支持绑定该地址）\n'
  printf '  3. [指定网卡] 仅指定服务器 IPv4 地址可访问（适用于内网或特定公网 IP）\n'
  printf '  4. [公网] 所有 IPv4 可访问：0.0.0.0:%s（需配置防火墙）\n' "$port"
  printf '  0. 返回\n'
  read -r -p "请选择 [0-4]：" mode

  case "$mode" in
    1) GENERIC_BIND_HOST="127.0.0.1" ;;
    2)
      mapfile -t npm_targets < <(find_npm_gateway_targets)
      if (( ${#npm_targets[@]} == 0 )); then
        warn "未自动识别到带 IPv4 Docker 网络网关的 Nginx Proxy Manager 容器。"
        show_running_docker_containers
        read -r -p "输入 NPM 容器名称或 ID（直接回车返回）:" manual_container
        [[ -n "$manual_container" ]] || return 1
        mapfile -t npm_targets < <(docker_gateway_targets_for_container "$manual_container")
        if (( ${#npm_targets[@]} == 0 )); then
          npm_network_mode="$(docker_network_mode_for_container "$manual_container")"
          if [[ "$npm_network_mode" == "host" ]]; then
            warn "该容器使用 host 网络，请返回并选择“仅服务器本机”模式。"
          else
            error "容器 ${manual_container} 未找到 IPv4 Docker 网络网关。"
          fi
          return 1
        fi
      fi
      if (( ${#npm_targets[@]} == 1 )); then
        npm_target="${npm_targets[0]}"
      else
        printf '\n检测到多个 NPM Docker 网络：\n'
        for ((i = 0; i < ${#npm_targets[@]}; i++)); do
          IFS=$'\t' read -r npm_container_id npm_container_name npm_network npm_gateway <<< "${npm_targets[$i]}"
          printf '  %d. 容器 %s，网络 %s，网关 %s\n' "$((i + 1))" "$npm_container_name" "$npm_network" "$npm_gateway"
        done
        read -r -p "请选择 [1-${#npm_targets[@]}]：" selection
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#npm_targets[@]} )); then
          error "无效选项：$selection"
          return 1
        fi
        npm_target="${npm_targets[$((selection - 1))]}"
      fi
      IFS=$'\t' read -r npm_container_id npm_container_name npm_network npm_gateway <<< "$npm_target"
      if ! is_local_upstream_host "$npm_gateway"; then
        error "Docker 网关 ${npm_gateway} 未出现在本机网卡地址中，无法安全作为监听地址。"
        return 1
      fi
      GENERIC_BIND_HOST="$npm_gateway"
      GENERIC_NPM_CONTAINER_ID="$npm_container_id"
      GENERIC_NPM_CONTAINER_NAME="$npm_container_name"
      GENERIC_NPM_GATEWAY="$npm_gateway"
      info "检测到 NPM 容器 ${npm_container_name}，网络 ${npm_network}，网关 ${npm_gateway}。"
      info "将请求应用监听 ${npm_gateway}:${port}；这不是将 systemd 服务挂载到 NPM 容器。"
      ;;
    3)
      read -r -p "服务器本机 IPv4 地址：" manual_host
      if ! is_valid_ipv4 "$manual_host" || ! is_local_upstream_host "$manual_host"; then
        error "该地址不是服务器当前网卡上的 IPv4 地址。"
        return 1
      fi
      GENERIC_BIND_HOST="$manual_host"
      ;;
    4)
      GENERIC_BIND_HOST="0.0.0.0"
      warn "此端口将接受所有 IPv4 网络接口的连接，请仅在防火墙允许可信来源。"
      ;;
    0) return 1 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac
}

generic_systemd_config_search_paths() {
  local unit="$1"
  local unit_base="${unit%.service}"
  local environment_file working_directory executable_path directory
  local -a directories

  while IFS= read -r environment_file; do
    [[ -n "$environment_file" && -f "$environment_file" ]] && printf '%s\n' "$environment_file"
  done < <(
    systemctl cat "$unit" --no-pager 2>/dev/null \
      | sed -nE 's/^[[:space:]]*EnvironmentFile=-?([^[:space:]"]+).*$/\1/p'
  )

  working_directory="$(systemctl show "$unit" --property=WorkingDirectory --value 2>/dev/null || true)"
  executable_path="$(
    systemctl show "$unit" --property=ExecStart --value 2>/dev/null \
      | sed -n 's/.*path=\([^ ;}]*\).*/\1/p' | head -n 1
  )"
  directories=(
    "$working_directory"
    "$(dirname -- "$executable_path" 2>/dev/null || true)"
    "/etc/${unit_base}"
  )
  for directory in "${directories[@]}"; do
    [[ -n "$directory" && "$directory" != "/" && -d "$directory" ]] || continue
    find "$directory" -maxdepth 3 -type f \
      \( -name '*.conf' -o -name '*.config' -o -name '*.env' -o -name '*.ini' \
         -o -name '*.json' -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' \) \
      -print 2>/dev/null
  done
  for environment_file in "/etc/default/${unit_base}" "/etc/${unit_base}.conf"; do
    [[ -f "$environment_file" ]] && printf '%s\n' "$environment_file"
  done
}

generic_systemd_listener_config_candidates() {
  local unit="$1"
  local port="$2"
  local config_path address match_lines
  local -a addresses=(
    "127.0.0.1:${port}"
    "0.0.0.0:${port}"
    "*:${port}"
    "[::]:${port}"
    ":::${port}"
  )

  while IFS= read -r config_path; do
    [[ -f "$config_path" && -r "$config_path" ]] || continue
    grep -Iq . "$config_path" 2>/dev/null || continue
    for address in "${addresses[@]}"; do
      match_lines="$(grep -Foc -- "$address" "$config_path" 2>/dev/null || true)"
      [[ "$match_lines" == "1" ]] && printf '%s\t%s\n' "$config_path" "$address"
    done
  done < <(generic_systemd_config_search_paths "$unit" | awk 'NF && !seen[$0]++')
}

apply_generic_systemd_listener_address() {
  local unit="$1"
  local port="$2"
  local config_path="$3"
  local old_address="$4"
  local bind_host="$5"
  local new_address="${bind_host}:${port}"
  local rollback_manifest rollback_backup rollback_dir temp_file previous_file match_lines

  [[ "$unit" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || {
    error "systemd 服务名称不安全，已取消。"
    return 1
  }
  config_path="$(readlink -f -- "$config_path" 2>/dev/null || true)"
  if [[ -z "$config_path" || ! -f "$config_path" || ! -r "$config_path" || ! -w "$config_path" ]]; then
    error "配置文件必须是当前可读写的普通文件。"
    return 1
  fi
  if [[ -z "$old_address" || ! "$old_address" == *:* ]]; then
    error "旧监听地址必须包含地址和端口，例如 0.0.0.0:${port}。"
    return 1
  fi
  if ! grep -Fq -- "$old_address" "$config_path"; then
    error "配置文件中未找到精确的旧监听地址：${old_address}"
    return 1
  fi
  match_lines="$(grep -Foc -- "$old_address" "$config_path" || true)"
  if [[ "$match_lines" != "1" ]]; then
    error "旧监听地址出现在 ${match_lines} 行。请缩小为仅包含该服务监听地址的配置文件后重试。"
    return 1
  fi
  if [[ "$old_address" == "$new_address" ]]; then
    info "监听地址已是 ${new_address}，无需修改。"
    return 0
  fi

  IFS=$'\t' read -r rollback_manifest rollback_backup < <(generic_systemd_rollback_paths "$unit" "$port")
  rollback_dir="$(dirname "$rollback_manifest")"
  install -d -m 0700 "$rollback_dir"
  previous_file="$(mktemp "${rollback_dir}/.${unit}-${port}.previous.XXXXXX")" || return 1
  temp_file="$(mktemp "$(dirname "$config_path")/.npmctl-listener.XXXXXX")" || {
    rm -f -- "$previous_file"
    return 1
  }
  cp -a -- "$config_path" "$previous_file"
  cp -a -- "$config_path" "$rollback_backup"
  chown --reference="$config_path" "$temp_file"
  chmod --reference="$config_path" "$temp_file"
  awk -v old="$old_address" -v new="$new_address" '
    {
      while ((position = index($0, old)) > 0) {
        $0 = substr($0, 1, position - 1) new substr($0, position + length(old))
      }
      print
    }
  ' "$config_path" >"$temp_file"
  mv -f -- "$temp_file" "$config_path"
  printf '%s\t%s\t%s\t%s\n' "$config_path" "$rollback_backup" "$unit" "$port" >"$rollback_manifest"
  backup_file "$previous_file" "${unit}-${port}-before-listener-change"

  if systemctl restart "$unit" && systemctl is-active --quiet "$unit" \
      && generic_listener_is_listening_on "$port" "$bind_host"; then
    rm -f -- "$previous_file"
    success "${unit} 监听地址已更新为 ${new_address}。"
    show_local_listener "$port"
    return 0
  fi

  error "服务重启或监听验证失败，正在自动恢复原配置。"
  cp -a -- "$previous_file" "$config_path"
  rm -f -- "$previous_file" "$rollback_manifest" "$rollback_backup"
  systemctl restart "$unit" >/dev/null 2>&1 || true
  return 1
}

rollback_generic_systemd_listener_address() {
  local unit="$1"
  local port="$2"
  local rollback_manifest rollback_backup config_path saved_unit saved_port current_copy

  IFS=$'\t' read -r rollback_manifest rollback_backup < <(generic_systemd_rollback_paths "$unit" "$port")
  if [[ ! -f "$rollback_manifest" ]]; then
    warn "未找到 ${unit} 端口 ${port} 的 NPMCtl 手动回滚点。"
    return 0
  fi
  IFS=$'\t' read -r config_path rollback_backup saved_unit saved_port <"$rollback_manifest"
  if [[ "$saved_unit" != "$unit" || "$saved_port" != "$port" || ! -f "$rollback_backup" || ! -f "$config_path" ]]; then
    error "回滚记录不完整或已被手工修改，已取消。"
    return 1
  fi
  confirm_action "确认恢复 ${unit} 在修改前的监听配置？" || { info "已取消。"; return 0; }
  current_copy="$(mktemp "$(dirname "$rollback_manifest")/.${unit}-${port}.current.XXXXXX")" || return 1
  cp -a -- "$config_path" "$current_copy"
  cp -a -- "$rollback_backup" "$config_path"
  if systemctl restart "$unit" && systemctl is-active --quiet "$unit" \
      && [[ -n "$(local_tcp_listener_details "$port")" ]]; then
    rm -f -- "$current_copy" "$rollback_manifest" "$rollback_backup"
    success "已恢复 ${unit} 修改前的监听配置。"
    show_local_listener "$port"
    return 0
  fi

  error "手动回滚后服务未正常启动，正在恢复回滚前配置。"
  cp -a -- "$current_copy" "$config_path"
  rm -f -- "$current_copy"
  systemctl restart "$unit" >/dev/null 2>&1 || true
  return 1
}

manage_generic_systemd_listener() {
  local port="$1"
  local listener="$2"
  local unit="$3"
  local mode config_path old_address selection automatic_answer manual_config_answer selected_candidate
  local -a config_candidates

  while true; do
    printf '\n%s通用 systemd 监听地址管理%s\n' "$BOLD" "$RESET"
    printf '服务：%s\n当前监听：\n%s\n' "$unit" "$listener"
    printf '优先自动识别应用配置中的精确地址；不会修改 systemd ExecStart。\n'
    printf '  1. 查看服务详情与 systemd 定义\n'
    printf '  2. 修改应用配置中的监听地址（自动回滚）\n'
    printf '  3. 恢复上一次由 NPMCtl 修改的监听配置\n'
    printf '  0. 返回\n'
    read -r -p "请选择 [0-3]：" mode

    case "$mode" in
    1)
      show_generic_systemd_service_details "$unit"
      read -r -p "按 Enter 键返回通用 systemd 监听地址管理菜单..." _ || true
      ;;
    2)
      prompt_generic_systemd_bind_host "$port" || continue
      mapfile -t config_candidates < <(generic_systemd_listener_config_candidates "$unit" "$port")
      if (( ${#config_candidates[@]} > 0 )); then
        printf '\n%s自动识别到的应用监听配置%s\n' "$BOLD" "$RESET"
        if (( ${#config_candidates[@]} == 1 )); then
          selected_candidate="${config_candidates[0]}"
        else
          for ((selection = 0; selection < ${#config_candidates[@]}; selection++)); do
            IFS=$'\t' read -r config_path old_address <<< "${config_candidates[$selection]}"
            printf '  %d. %s（当前：%s）\n' "$((selection + 1))" "$config_path" "$old_address"
          done
          read -r -p "请选择 [1-${#config_candidates[@]}]（直接回车改为手动填写）：" selection
          if [[ -z "$selection" ]]; then
            config_candidates=()
          elif [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#config_candidates[@]} )); then
            selected_candidate="${config_candidates[$((selection - 1))]}"
          else
            error "无效选项：$selection"
            continue
          fi
        fi
        if (( ${#config_candidates[@]} > 0 )); then
          IFS=$'\t' read -r config_path old_address <<< "$selected_candidate"
          info "已识别配置：${config_path}；当前监听：${old_address}。"
          read -r -p "自动备份、替换为 ${GENERIC_BIND_HOST}:${port} 并重启 ${unit}？[y/N，回车默认 N]：" automatic_answer
          automatic_answer="${automatic_answer:-N}"
          case "$automatic_answer" in
            Y|y)
              if apply_generic_systemd_listener_address "$unit" "$port" "$config_path" "$old_address" "$GENERIC_BIND_HOST"; then
                if [[ -n "$GENERIC_NPM_CONTAINER_ID" ]]; then
                  verify_npm_gateway_connection "$GENERIC_NPM_CONTAINER_ID" "$GENERIC_NPM_CONTAINER_NAME" "$GENERIC_NPM_GATEWAY" "$port" || true
                fi
              fi
              continue
              ;;
            N|n) info "已取消自动修改。"; continue ;;
            *) error "请输入 y 或 n。"; continue ;;
          esac
        fi
      fi
      warn "未自动识别到唯一的文本配置监听地址，需手动指定。"
      if [[ -n "$GENERIC_NPM_GATEWAY" ]]; then
        info "选项 2 的目标监听地址为 ${GENERIC_NPM_GATEWAY}:${port}；端口存储在数据库或面板内部的服务无法由通用文本替换安全修改。"
      else
        info "端口存储在数据库或面板内部的服务无法由通用文本替换安全修改。"
      fi
      read -r -p "是否手动指定应用文本配置文件？[y/N，回车默认 N]：" manual_config_answer
      manual_config_answer="${manual_config_answer:-N}"
      case "$manual_config_answer" in
        Y|y) ;;
        N|n) info "已取消手动配置。"; continue ;;
        *) error "请输入 y 或 n。"; continue ;;
      esac
      printf '旧地址必须与文件内容完全一致，例如 0.0.0.0:%s 或 127.0.0.1:%s。\n' "$port" "$port"
      read -r -p "应用配置文件绝对路径：" config_path
      read -r -p "配置中的旧监听地址：" old_address
      warn "将把 ${config_path} 中唯一的 ${old_address} 替换为 ${GENERIC_BIND_HOST}:${port}，并重启 ${unit}。"
      confirm_action "确认继续？" || { info "已取消。"; continue; }
      if apply_generic_systemd_listener_address "$unit" "$port" "$config_path" "$old_address" "$GENERIC_BIND_HOST"; then
        if [[ -n "$GENERIC_NPM_CONTAINER_ID" ]]; then
          verify_npm_gateway_connection "$GENERIC_NPM_CONTAINER_ID" "$GENERIC_NPM_CONTAINER_NAME" "$GENERIC_NPM_GATEWAY" "$port" || true
        fi
      fi
      ;;
    3) rollback_generic_systemd_listener_address "$unit" "$port" ;;
    0) return 0 ;;
    *) error "无效选项：$mode" ;;
    esac
  done
}

docker_mapping_for_host_port() {
  local host_port="$1"
  local container_id container_name mappings container_port host_ip mapped_port

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  while IFS='|' read -r container_id container_name; do
    mappings="$(docker inspect --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{$port}}|{{.HostIp}}|{{.HostPort}}{{println}}{{end}}{{end}}' "$container_id" 2>/dev/null || true)"
    while IFS='|' read -r container_port host_ip mapped_port; do
      [[ "$mapped_port" == "$host_port" ]] || continue
      printf '%s\t%s\t%s\t%s\n' "$container_id" "$container_name" "$container_port" "$host_ip"
      return 0
    done <<< "$mappings"
  done < <(docker ps --format '{{.ID}}|{{.Names}}' 2>/dev/null)
}

docker_container_network_names() {
  docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$1" 2>/dev/null
}

docker_container_has_network() {
  local container_reference="$1"
  local network_name="$2"
  local attached_network

  while IFS= read -r attached_network; do
    [[ "$attached_network" == "$network_name" ]] && return 0
  done < <(docker_container_network_names "$container_reference")
  return 1
}

connect_container_to_network() {
  local container_reference="$1"
  local container_name="$2"
  local network_name="$3"
  local network_alias="${4:-}"

  if docker_container_has_network "$container_reference" "$network_name"; then
    info "容器 ${container_name} 已加入网络 ${network_name}。"
    return 0
  fi

  if [[ -n "$network_alias" ]]; then
    if ! docker network connect --alias "$network_alias" "$network_name" "$container_reference"; then
      error "无法将容器 ${container_name} 加入网络 ${network_name}。"
      return 1
    fi
  elif ! docker network connect "$network_name" "$container_reference"; then
    error "无法将容器 ${container_name} 加入网络 ${network_name}。"
    return 1
  fi

  if ! docker_container_has_network "$container_reference" "$network_name"; then
    error "容器 ${container_name} 未出现在网络 ${network_name} 中。"
    return 1
  fi
  success "已将容器 ${container_name} 加入网络 ${network_name}。"
}

replace_compose_port_mapping() {
  local config_path="$1"
  local current_host_ip="$2"
  local host_port="$3"
  local internal_port="$4"
  local bind_host="$5"
  local temp_file line mapping_regex port_suffix line_suffix match_count=0 variable_mapping_detected=false

  [[ -r "$config_path" && -w "$config_path" ]] || {
    error "Compose 配置文件不可读或不可写：${config_path}"
    return 1
  }
  temp_file="$(mktemp "${config_path}.npmctl.XXXXXX")" || return 1
  if [[ "$current_host_ip" == "0.0.0.0" ]]; then
    mapping_regex="^([[:space:]]*-[[:space:]]*[\"']?)(0\\.0\\.0\\.0:)?${host_port}:${internal_port}(/tcp)?([\"']?[[:space:]]*(#.*)?)$"
  else
    mapping_regex="^([[:space:]]*-[[:space:]]*[\"']?)${current_host_ip}:${host_port}:${internal_port}(/tcp)?([\"']?[[:space:]]*(#.*)?)$"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*-[[:space:]]*.*\$\{ ]] && variable_mapping_detected=true
    if [[ "$line" =~ $mapping_regex ]]; then
      ((match_count += 1))
      if [[ "$current_host_ip" == "0.0.0.0" ]]; then
        port_suffix="${BASH_REMATCH[3]:-}"
        line_suffix="${BASH_REMATCH[4]:-}"
      else
        port_suffix="${BASH_REMATCH[2]:-}"
        line_suffix="${BASH_REMATCH[3]:-}"
      fi
      printf '%s%s:%s:%s%s%s\n' "${BASH_REMATCH[1]}" "$bind_host" "$host_port" "$internal_port" "$port_suffix" "$line_suffix" >>"$temp_file"
    else
      printf '%s\n' "$line" >>"$temp_file"
    fi
  done <"$config_path"

  if (( match_count != 1 )); then
    rm -f -- "$temp_file"
    if [[ "$variable_mapping_detected" == true ]]; then
      warn "Compose 端口映射由环境变量管理，NPMCtl 无法安全判断变量来源，未自动修改。"
      info "请使用应用自身的管理工具，或修改对应 env 文件后重建容器。"
    else
      warn "未能在 Compose 文件中唯一识别当前端口映射，未自动修改。"
    fi
    return 1
  fi
  chmod --reference="$config_path" "$temp_file" || {
    rm -f -- "$temp_file"
    return 1
  }
  mv -- "$temp_file" "$config_path"
}

is_kopiactl_web_ui_container() {
  local container_name="$1"

  [[ "$container_name" == kopia-web-ui ]] || return 1
  [[ -x /usr/local/bin/kopiactl ]] || return 1
  [[ -f /opt/kopiactl/kopiactl.env ]] || return 1
  grep -qx 'INSTALL_MODE=docker' /opt/kopiactl/kopiactl.env 2>/dev/null
}

apply_kopiactl_web_ui_bind_address() {
  local bind_host="$1"
  local host_port="$2"
  local internal_port="$3"

  info "检测到 KopiaCtl 管理的 Web UI，交由 KopiaCtl 修改发布范围并重建容器。"
  /usr/local/bin/kopiactl web-ui set-bind "$bind_host" || {
    error 'KopiaCtl 未能修改 Web UI 发布范围。请先将 KopiaCtl 更新到支持该命令的版本。'
    return 1
  }
  if ! wait_for_docker_port_mapping "$host_port" "$bind_host" "${internal_port}/tcp"; then
    error 'KopiaCtl 命令已执行，但未检测到预期端口映射。请查看 KopiaCtl 的 Web UI 状态。'
    return 1
  fi
  success "KopiaCtl Web UI 已改为 ${bind_host}:${host_port}:${internal_port}。"
}

wait_for_docker_port_mapping() {
  local host_port="$1"
  local expected_host="$2"
  local expected_container_port="$3"
  local mapping container_id container_name container_port mapped_host attempt

  for ((attempt = 1; attempt <= 10; attempt++)); do
    mapping="$(docker_mapping_for_host_port "$host_port" || true)"
    if [[ -n "$mapping" ]]; then
      IFS=$'\t' read -r container_id container_name container_port mapped_host <<< "$mapping"
      if [[ "$mapped_host" == "$expected_host" && "$container_port" == "$expected_container_port" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

apply_compose_port_mapping() {
  local config_path="$1"
  local workdir="$2"
  local service="$3"
  local current_host_ip="$4"
  local host_port="$5"
  local internal_port="$6"
  local bind_host="$7"
  local rollback_file

  rollback_file="$(mktemp "$(dirname "$config_path")/.npmctl-port-rollback.XXXXXX")" || return 1
  cp -a -- "$config_path" "$rollback_file" || {
    rm -f -- "$rollback_file"
    return 1
  }
  backup_file "$config_path" "docker-${service}-port-mapping-before-change"

  if ! replace_compose_port_mapping "$config_path" "$current_host_ip" "$host_port" "$internal_port" "$bind_host"; then
    rm -f -- "$rollback_file"
    return 1
  fi
  if ! (cd "$workdir" && docker compose -f "$config_path" config -q); then
    error "Compose 配置校验失败，正在恢复原配置。"
    cp -a -- "$rollback_file" "$config_path"
    rm -f -- "$rollback_file"
    return 1
  fi
  if ! (cd "$workdir" && docker compose -f "$config_path" up -d "$service"); then
    error "重建 Docker 服务失败，正在恢复原配置和服务。"
    cp -a -- "$rollback_file" "$config_path"
    (cd "$workdir" && docker compose -f "$config_path" up -d "$service") || true
    rm -f -- "$rollback_file"
    return 1
  fi
  if ! wait_for_docker_port_mapping "$host_port" "$bind_host" "${internal_port}/tcp"; then
    error "未检测到目标端口映射，正在恢复原配置和服务。"
    cp -a -- "$rollback_file" "$config_path"
    (cd "$workdir" && docker compose -f "$config_path" up -d "$service") || true
    rm -f -- "$rollback_file"
    return 1
  fi

  rm -f -- "$rollback_file"
  success "已修改 Compose 端口映射并重建服务：${bind_host}:${host_port}:${internal_port}。"
}

docker_compose_service_or_name() {
  local container_reference="$1"
  local service container_name

  service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$container_reference" 2>/dev/null || true)"
  if [[ -n "$service" && "$service" != "<no value>" ]]; then
    printf '%s\n' "$service"
    return 0
  fi
  container_name="$(docker inspect --format '{{.Name}}' "$container_reference" 2>/dev/null || true)"
  printf '%s\n' "${container_name#/}"
}

show_npm_shared_network_guide() {
  local app_container_id="$1"
  local app_container_name="$2"
  local container_port="$3"
  local npm_target npm_container_id npm_container_name npm_image manual_container selection
  local app_network npm_network shared_network="" internal_port app_service npm_service upstream_name default_network create_network_answer connect_network_answer
  local -a npm_containers app_networks npm_networks

  printf '\n%sDocker 后端 + NPM 共享网络创建%s\n' "$BOLD" "$RESET"
  mapfile -t npm_containers < <(find_npm_containers)
  if (( ${#npm_containers[@]} == 0 )); then
    warn "未自动识别 Nginx Proxy Manager 容器。"
    show_running_docker_containers
    read -r -p "输入 NPM 容器名称或 ID（直接回车返回）:" manual_container
    [[ -n "$manual_container" ]] || return 0
    if [[ "$(docker inspect --format '{{.State.Running}}' "$manual_container" 2>/dev/null)" != "true" ]]; then
      error "容器未运行或不存在：$manual_container"
      return 1
    fi
    npm_container_id="$(docker inspect --format '{{.Id}}' "$manual_container" 2>/dev/null || true)"
    npm_container_name="$(docker inspect --format '{{.Name}}' "$manual_container" 2>/dev/null || true)"
    npm_container_name="${npm_container_name#/}"
  elif (( ${#npm_containers[@]} == 1 )); then
    npm_target="${npm_containers[0]}"
    IFS=$'\t' read -r npm_container_id npm_container_name npm_image <<< "$npm_target"
  else
    printf '检测到多个 NPM 容器：\n'
    local i
    for ((i = 0; i < ${#npm_containers[@]}; i++)); do
      IFS=$'\t' read -r npm_container_id npm_container_name npm_image <<< "${npm_containers[$i]}"
      printf '  %d. %s | %s\n' "$((i + 1))" "$npm_container_name" "$npm_image"
    done
    read -r -p "请选择 [1-${#npm_containers[@]}]：" selection
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#npm_containers[@]} )); then
      error "无效选项：$selection"
      return 1
    fi
    npm_target="${npm_containers[$((selection - 1))]}"
    IFS=$'\t' read -r npm_container_id npm_container_name npm_image <<< "$npm_target"
  fi

  mapfile -t app_networks < <(docker_container_network_names "$app_container_id")
  mapfile -t npm_networks < <(docker_container_network_names "$npm_container_id")
  for app_network in "${app_networks[@]}"; do
    for npm_network in "${npm_networks[@]}"; do
      if [[ "$app_network" == "$npm_network" ]]; then
        shared_network="$app_network"
        break 2
      fi
    done
  done

  internal_port="${container_port%/tcp}"
  app_service="$(docker_compose_service_or_name "$app_container_id")"
  npm_service="$(docker_compose_service_or_name "$npm_container_id")"
  upstream_name="${app_service:-$app_container_name}"
  if [[ -n "$shared_network" ]]; then
    success "应用容器 ${app_container_name} 与 NPM ${npm_container_name} 已共享网络：${shared_network}。"
    info "请在 NPM 中将上游设为 ${upstream_name}:${internal_port}，协议按应用实际情况选择。"
    warn "请确认该网络已在两个 Compose 文件中声明；手工连接会在容器重建后丢失。"
    return 0
  fi

  warn "应用容器 ${app_container_name} 与 NPM ${npm_container_name} 没有共享 Docker 网络。"
  # Network names are for operators to recognize; Compose service names remain for NPM DNS upstreams.
  default_network="${npm_container_name}-${app_container_name}"
  read -r -p "共享网络名称 [默认 ${default_network}，按容器名自动生成]：" shared_network
  shared_network="${shared_network:-$default_network}"
  if [[ ! "$shared_network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    error "Docker 网络名称格式不正确。"
    return 1
  fi
  if docker network inspect "$shared_network" >/dev/null 2>&1; then
    info "Docker 网络 ${shared_network} 已存在。"
  else
    read -r -p "立即创建 Docker 共享网络 ${shared_network}？[y/N，回车默认 N]：" create_network_answer
    create_network_answer="${create_network_answer:-N}"
    case "$create_network_answer" in
      Y|y)
        if ! docker network create "$shared_network" >/dev/null; then
          error "创建 Docker 网络失败：${shared_network}"
          return 1
        fi
        success "已创建 Docker 共享网络：${shared_network}。"
        ;;
      N|n)
        info "未创建 Docker 网络。可稍后执行：docker network create ${shared_network}"
        ;;
      *)
        error "请输入 Y 或 n。"
        return 1
        ;;
    esac
  fi

  if ! docker network inspect "$shared_network" >/dev/null 2>&1; then
    warn "Docker 网络 ${shared_network} 尚未创建，未执行容器连接。"
  else
    read -r -p "立即将 NPM ${npm_container_name} 和应用 ${app_container_name} 加入 ${shared_network}？[y/N，回车默认 N]：" connect_network_answer
    connect_network_answer="${connect_network_answer:-N}"
    case "$connect_network_answer" in
      Y|y)
        connect_container_to_network "$app_container_id" "$app_container_name" "$shared_network" "$upstream_name" || return 1
        connect_container_to_network "$npm_container_id" "$npm_container_name" "$shared_network" || return 1
        if docker_container_has_network "$app_container_id" "$shared_network" && docker_container_has_network "$npm_container_id" "$shared_network"; then
          success "已验证 NPM 与应用容器均已加入网络 ${shared_network}。"
        else
          error "共享网络成员验证失败。"
          return 1
        fi
        if docker exec "$npm_container_id" getent hosts "$upstream_name" >/dev/null 2>&1; then
          success "NPM 容器可解析上游名称：${upstream_name}。"
        else
          warn "未能在 NPM 容器中执行 getent 解析检查；请在 NPM 保存代理主机后验证连接。"
        fi
        success "现在可在 NPM 中将上游设为 ${upstream_name}:${internal_port}。"
        ;;
      N|n)
        info "未连接当前容器。完成 Compose 配置后执行 docker compose up -d，或重新进入此菜单连接。"
        ;;
      *)
        error "请输入 Y 或 n。"
        return 1
        ;;
    esac
  fi

  printf '\n在 NPM 和应用各自的 Compose 文件中加入同名外部网络：\n\n'
  printf 'services:\n  %s:\n    networks:\n      - %s\n\n' "${npm_service:-<NPM服务名>}" "$shared_network"
  printf 'services:\n  %s:\n    networks:\n      - %s\n\n' "${app_service:-<应用服务名>}" "$shared_network"
  printf 'networks:\n  %s:\n    external: true\n\n' "$shared_network"
  info "以上片段用于持久化：分别保存后在两个 Compose 项目目录执行 docker compose up -d。"
  info "手工连接成功时可立即使用 ${upstream_name}:${internal_port}；重建容器后必须依靠上述 Compose 配置恢复连接。"
  warn "本向导不会修改当前 ports。确认共享网络已持久化且 NPM 访问正常后，可自行移除不再需要的端口映射并重建应用容器。"
}

show_docker_mapping_plan() {
  local container_id="$1"
  local container_name="$2"
  local container_port="$3"
  local current_host_ip="$4"
  local host_port="$5"
  local mode bind_host internal_port project service workdir config_files auto_apply_answer
  local compat_target compat_container_id compat_container_name compat_network compat_gateway compat_gateway_display manual_container selection i preferred_index
  local -a compat_targets

  internal_port="${container_port%/tcp}"
  project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container_id" 2>/dev/null || true)"
  service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$container_id" 2>/dev/null || true)"
  workdir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container_id" 2>/dev/null || true)"
  config_files="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container_id" 2>/dev/null || true)"
  mapfile -t compat_targets < <(find_npm_gateway_targets)
  compat_gateway_display="<选择后确定>"
  if (( ${#compat_targets[@]} == 1 )); then
    IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "${compat_targets[0]}"
    if [[ "$compat_network" == bridge* ]]; then
      compat_gateway_display="$compat_gateway（Docker 系统默认 bridge）"
    else
      compat_gateway_display="$compat_gateway"
    fi
  elif (( ${#compat_targets[@]} > 1 )); then
    compat_target="$(preferred_npm_gateway_target "${compat_targets[@]}")"
    IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "$compat_target"
    compat_gateway_display="$compat_gateway（默认；检测到 ${#compat_targets[@]} 个网关）"
  fi

  printf '\n%sDocker 容器访问与端口发布%s\n' "$BOLD" "$RESET"
  if [[ -n "$project" ]]; then
    printf '启动方式：Docker 容器（Compose 管理）\n'
  else
    printf '启动方式：Docker 容器\n'
  fi
  printf '容器：%s\n宿主机发布地址：%s:%s（docker-proxy）\n容器内部端口：%s（共享网络/NPM 直连使用）\n' \
    "$container_name" "${current_host_ip:-0.0.0.0}" "$host_port" "$container_port"
  info "选项 1 只配置共享网络并保留当前 ports；选项 2-4 才会修改端口发布地址。"
  printf '  1. [推荐] 配置 NPM 与应用共享网络（不修改当前端口映射）\n'
  printf '  2. [兼容] NPM 经 Docker bridge 网关中转（含系统默认 bridge）：%s:%s:%s（仅发布到该网关）\n' "$compat_gateway_display" "$host_port" "$internal_port"
  printf '  3. [宿主机 NPM] 仅发布到本机：127.0.0.1:%s:%s\n' "$host_port" "$internal_port"
  printf '  4. [公网] 任何来源可访问：0.0.0.0:%s:%s\n' "$host_port" "$internal_port"
  printf '  0. 返回\n'
  read -r -p "请选择 [0-4]：" mode

  case "$mode" in
    1)
      show_npm_shared_network_guide "$container_id" "$container_name" "$container_port"
      return
      ;;
    2)
      if (( ${#compat_targets[@]} == 0 )); then
        warn "未自动检测到带 IPv4 Docker bridge 网关的 NPM 容器。"
        show_running_docker_containers
        read -r -p "输入 NPM 容器名称或 ID（直接回车返回）: " manual_container
        [[ -n "$manual_container" ]] || return 0
        mapfile -t compat_targets < <(docker_npm_compatibility_targets "$manual_container")
      fi
      if (( ${#compat_targets[@]} == 0 )); then
        error "未找到 NPM 容器的 IPv4 Docker bridge 网关，无法生成兼容映射。"
        return 1
      fi
      if (( ${#compat_targets[@]} == 1 )); then
        compat_target="${compat_targets[0]}"
      else
        preferred_index=1
        compat_target="$(preferred_npm_gateway_target "${compat_targets[@]}")"
        IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "$compat_target"
        printf '\n检测到多个 NPM Docker 网络网关（回车使用推荐项）：\n'
        for ((i = 0; i < ${#compat_targets[@]}; i++)); do
          IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "${compat_targets[$i]}"
          if [[ "$compat_targets[$i]" == "$compat_target" ]]; then
            preferred_index=$((i + 1))
          if [[ "$compat_network" == bridge* ]]; then
            printf '  %d. 容器 %s，Docker 系统默认 bridge 网络，网关 %s [推荐]\n' "$((i + 1))" "$compat_container_name" "$compat_gateway"
          else
            printf '  %d. 容器 %s，网络 %s，网关 %s [推荐]\n' "$((i + 1))" "$compat_container_name" "$compat_network" "$compat_gateway"
          fi
          else
          if [[ "$compat_network" == bridge* ]]; then
            printf '  %d. 容器 %s，Docker 系统默认 bridge 网络，网关 %s\n' "$((i + 1))" "$compat_container_name" "$compat_gateway"
          else
            printf '  %d. 容器 %s，网络 %s，网关 %s\n' "$((i + 1))" "$compat_container_name" "$compat_network" "$compat_gateway"
          fi
          fi
        done
        read -r -p "请选择 [1-${#compat_targets[@]}，默认 ${preferred_index}]: " selection
        selection="${selection:-$preferred_index}"
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#compat_targets[@]} )); then
          error "无效选项：$selection"
          return 1
        fi
        compat_target="${compat_targets[$((selection - 1))]}"
      fi
      IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "$compat_target"
      if ! is_local_upstream_host "$compat_gateway"; then
        error "检测到的 Docker 网关 ${compat_gateway} 不是本机地址，无法作为端口发布地址。"
        return 1
      fi
      bind_host="$compat_gateway"
      if [[ "$compat_network" == bridge* ]]; then
        info "已选择 Docker 系统默认 bridge 网络网关：${compat_gateway}（NPM 容器：${compat_container_name}）。"
        warn "请确认 NPM 容器能够访问此网关；若不可达，请改选 NPM 已连接的 Docker 网络网关。"
      else
        info "检测到 NPM 容器 ${compat_container_name} 的 Docker 网关：${compat_gateway}（网络 ${compat_network}）。"
      fi
      info "Compose 目标映射：${compat_gateway}:${host_port}:${internal_port}。"
      info "重建后在 NPM 中填写上游地址 ${compat_gateway}:${host_port}。"
      ;;
    3)
      bind_host="127.0.0.1"
      info "仅修改宿主机发布地址为 127.0.0.1:${host_port}；容器内部端口仍为 ${internal_port}。"
      info "此端口供宿主机上的 NPM、Nginx 等反代；Docker 内的 NPM 不能经 127.0.0.1:${host_port} 访问。"
      ;;
    4)
      bind_host="0.0.0.0"
      warn "此容器端口将接受所有 IPv4 网络接口的连接，请限制防火墙来源。"
      ;;
    0) return 0 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac

  if is_kopiactl_web_ui_container "$container_name"; then
    if [[ "$current_host_ip" == "$bind_host" ]]; then
      info "当前 KopiaCtl Web UI 端口映射已是目标地址，无需修改。"
      return 0
    fi
    read -r -p "交由 KopiaCtl 修改 Web UI 发布范围并重建容器？[y/N，回车默认 N]：" auto_apply_answer
    auto_apply_answer="${auto_apply_answer:-N}"
    case "$auto_apply_answer" in
      Y|y) apply_kopiactl_web_ui_bind_address "$bind_host" "$host_port" "$internal_port" ;;
      N|n) info "未自动修改。可在 KopiaCtl 的“修改 Web UI 发布范围”中设置为 ${bind_host}。" ;;
      *) error "请输入 Y 或 n。"; return 1 ;;
    esac
    return
  fi

  printf '\n请将 Compose 中对应服务的 ports 映射改为：\n\n'
  printf 'services:\n  %s:\n    ports:\n      - "%s:%s:%s"\n' \
    "${service:-<服务名>}" "$bind_host" "$host_port" "$internal_port"
  printf '\n'
  if [[ -n "$project" ]]; then
    info "检测到 Compose 项目：$project"
    [[ -n "$workdir" ]] && info "项目目录：$workdir"
    [[ -n "$config_files" ]] && info "配置文件：$config_files"
    if [[ "$current_host_ip" == "$bind_host" ]]; then
      info "当前 Docker 端口映射已是目标地址，无需修改。"
    elif [[ -n "$service" && "$service" != "<no value>" && -n "$workdir" && -d "$workdir" && -n "$config_files" && "$config_files" != *,* && -f "$config_files" ]]; then
      read -r -p "自动备份、修改 Compose 并重建服务 ${service}？[y/N，回车默认 N]：" auto_apply_answer
      auto_apply_answer="${auto_apply_answer:-N}"
      case "$auto_apply_answer" in
        Y|y)
          apply_compose_port_mapping "$config_files" "$workdir" "$service" "$current_host_ip" "$host_port" "$internal_port" "$bind_host" || return 1
          ;;
        N|n)
          info "未自动修改。保存上述 Compose 片段后，在项目目录执行 docker compose up -d。"
          ;;
        *) error "请输入 Y 或 n。"; return 1 ;;
      esac
    else
      warn "未能安全识别单个可修改的 Compose 文件，未自动重建容器。"
      info "保存上述 Compose 片段后，在项目目录执行 docker compose up -d。"
    fi
  else
    warn "未检测到 Compose 标签。Docker 无法原地修改端口映射，需要使用新的 -p 参数重建该容器。"
  fi
  info "自动重建仅在已识别的单文件 Compose 与唯一端口映射时执行；其他情形保留手工操作。"
}

show_native_listener_launch_info() {
  local listener="$1"
  local pid unit ppid user process parent_process

  pid="$(printf '%s\n' "$listener" | listener_pid_from_details)"
  [[ "$pid" =~ ^[0-9]+$ ]] || {
    warn "无法从监听信息中识别进程 PID。"
    return 0
  }
  unit="$(systemd_unit_for_pid "$pid")"
  if [[ -n "$unit" ]]; then
    printf '启动方式：systemd 服务（%s）\n' "$unit"
    info "下一步：Kopia 可自动修改；其他原生服务可使用通用 systemd 配置替换与回滚功能。"
    return 0
  fi

  ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  user="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  process="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  parent_process="$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d ' ' || true)"
  if [[ "$ppid" == "1" ]]; then
    printf '启动方式：已脱离终端的手工命令（由 systemd / PID 1 收养，但不是 systemd 服务）\n'
    printf '进程：%s | PID：%s | 用户：%s\n' "${process:-未知}" "$pid" "${user:-未知}"
    info "下一步：可在 Kopia 菜单中选择接管为 NPMCtl 管理的 systemd 服务。"
    return 0
  fi
  printf '启动方式：手工命令、脚本或面板（未识别为 systemd 服务）\n'
  printf '进程：%s | PID：%s | 用户：%s | 父进程：%s（PID %s）\n' \
    "${process:-未知}" "$pid" "${user:-未知}" "${parent_process:-未知}" "${ppid:-未知}"
  info "下一步：请在上述父进程对应的面板、脚本或启动命令中修改监听地址；菜单不会直接接管该进程。"
}

local_service_listener_assistant() {
  local port listener process docker_mapping container_id container_name container_port host_ip

  while true; do
    printf '\n%s本机服务端口监听助手%s\n' "$BOLD" "$RESET"
    info "先列出本机服务，再输入需要查看或修改的端口。可将手工启动的 Kopia 接管为 systemd 服务。"
    show_all_local_listeners
    read -r -p "输入需要管理的 TCP 端口；输入 d 查看全部 Docker 容器内部监听（查询后返回此处；直接回车返回主菜单）：" port
    [[ -n "$port" ]] || return 0
    case "$port" in
      d|D)
        show_all_docker_internal_listeners
        read -r -p "按 Enter 键返回本机服务端口监听助手..." _ || true
        continue
        ;;
    esac
    break
  done
  if ! is_valid_port "$port"; then
    error "端口必须是 1-65535 之间的整数。"
    return 1
  fi
  listener="$(local_tcp_listener_details "$port")"
  if [[ -z "$listener" ]]; then
    warn "未发现 TCP 端口 $port 处于监听状态。"
    return 0
  fi
  printf '\n%s端口 %s 的监听详情%s\n%s\n' "$BOLD" "$port" "$RESET" "$listener"
  docker_mapping="$(docker_mapping_for_host_port "$port")"
  if [[ -n "$docker_mapping" ]]; then
    IFS=$'\t' read -r container_id container_name container_port host_ip <<< "$docker_mapping"
    show_docker_container_internal_listeners "$container_id" "$container_name"
    show_docker_mapping_plan "$container_id" "$container_name" "$container_port" "$host_ip" "$port"
    return
  fi
  process="$(printf '%s\n' "$listener" | listener_process_from_details)"
  if [[ "$process" == "docker-proxy" ]]; then
    warn "该端口由 Docker 发布，但未能读取容器端口映射，不能按通用 systemd 服务修改。"
    show_running_docker_containers
    info "请确认已升级到当前版本，并检查 docker inspect 的 Ports 信息。"
    return 1
  fi
  show_native_listener_launch_info "$listener"
  if [[ "$process" == "kopia" ]]; then
    manage_kopia_listener "$port" "$listener"
  else
    unit="$(systemd_unit_for_pid "$(printf '%s\n' "$listener" | listener_pid_from_details)")"
    if [[ -n "$unit" ]]; then
      manage_generic_systemd_listener "$port" "$listener" "$unit"
    else
      info "已识别进程：${process:-未知}。该服务不由 systemd 直接管理，请在其自身配置或原管理面板中调整监听地址。"
    fi
  fi
}

show_gateway_networks() {
  local rows name gateway ip members member member_ip driver project default_network role
  if ! docker inspect nginx-proxy-manager >/dev/null 2>&1; then
    error 'NPM 容器不存在，无法读取网关设置。'
    return 1
  fi

  printf '\n%sNPM 网关与网络连接%s\n' "$BOLD" "$RESET"
  project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' nginx-proxy-manager 2>/dev/null || true)"
  default_network="${project:-npmctl}_default"
  printf 'NPM 当前加入的 Docker 网络：\n'
  rows="$(docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}|{{$network.Gateway}}|{{$network.IPAddress}}{{"\n"}}{{end}}' nginx-proxy-manager 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    warn 'NPM 当前没有连接到任何 Docker bridge 网络（可能是 host 网络模式）。'
  fi
  local index=0
  while IFS='|' read -r name gateway ip; do
    [[ -n "$name" ]] || continue
    ((index += 1))
    driver="$(docker network inspect --format '{{.Driver}}' "$name" 2>/dev/null || printf '未知')"
    role='附加网络'
    [[ "$name" == "$default_network" || "$name" == 'npmctl_default' ]] && role='NPM 默认 Compose bridge 网络'
    printf '  %d. %s\n' "$index" "$name"
    printf '     类型：%s | 用途：%s\n' "$driver" "$role"
    printf '     网关：%s | NPM 容器 IP：%s\n' "${gateway:--}" "${ip:--}"
    members="$(docker network inspect --format '{{range $id, $container := .Containers}}{{$container.Name}}|{{$container.IPv4Address}}{{"\n"}}{{end}}' "$name" 2>/dev/null || true)"
    if [[ -n "$members" ]]; then
      printf '     同网络容器：\n'
      while IFS='|' read -r member member_ip; do
        [[ -n "$member" ]] || continue
        if [[ "$member" == "nginx-proxy-manager" ]]; then
          printf '       - %s（当前 NPM，IP %s）\n' "$member" "${member_ip:--}"
        else
          printf '       - %s（IP %s）\n' "$member" "${member_ip:--}"
        fi
      done <<< "$members"
    else
      printf '     同网络容器：无\n'
    fi
  done <<< "$rows"
  show_docker_default_bridge_network
  printf '\n网关地址由 Docker 网络决定；同网络容器可直接使用容器名和容器端口互相访问。\n'
  printf '本菜单也可以将任意容器服务连接到 Docker 网络或从网络移除；Compose 重建后如需保留额外网络，应在 Compose 中声明。\n'
}

show_docker_default_bridge_network() {
  local gateway members member member_ip npm_member=0
  docker network inspect bridge >/dev/null 2>&1 || return 0
  gateway="$(docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' bridge 2>/dev/null || true)"
  members="$(docker network inspect --format '{{range $id, $container := .Containers}}{{$container.Name}}|{{$container.IPv4Address}}{{"\n"}}{{end}}' bridge 2>/dev/null || true)"
  printf '\nDocker 系统默认 bridge 网络：\n'
  printf '  网络：bridge | 驱动：bridge | 网关：%s\n' "${gateway:--}"
  if [[ -n "$members" ]]; then
    printf '  网络成员：\n'
    while IFS='|' read -r member member_ip; do
      [[ -n "$member" ]] || continue
      [[ "$member" == 'nginx-proxy-manager' ]] && npm_member=1
      printf '    - %s（IP %s）\n' "$member" "${member_ip:--}"
    done <<< "$members"
  else
    printf '  网络成员：无\n'
  fi
  if (( npm_member == 1 )); then
    printf '  NPM 状态：已加入 Docker 系统默认 bridge 网络。\n'
  else
    printf '  NPM 状态：未加入；NPM 当前使用自己的 Compose 默认网络或 host 网络。\n'
  fi
}

show_all_gateway_services() {
  local network_id network_name driver gateway containers
  local found=0
  printf '\n%sDocker 网关与容器服务%s\n' "$BOLD" "$RESET"
  while IFS= read -r network_id; do
    [[ -n "$network_id" ]] || continue
    found=1
    network_name="$(docker network inspect --format '{{.Name}}' "$network_id" 2>/dev/null || true)"
    driver="$(docker network inspect --format '{{.Driver}}' "$network_id" 2>/dev/null || true)"
    gateway="$(docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$network_id" 2>/dev/null || true)"
    containers="$(docker network inspect --format '{{range $id, $container := .Containers}}{{$container.Name}} ({{$container.IPv4Address}}); {{end}}' "$network_id" 2>/dev/null || true)"
    printf '\n网络：%s\n' "${network_name:-未知}"
    printf '驱动：%s\n' "${driver:-未知}"
    printf '网关：%s\n' "${gateway:--}"
    if [[ -n "$containers" ]]; then
      printf '容器服务：%s\n' "$containers"
    else
      printf '容器服务：无\n'
    fi
  done < <(docker network ls -q 2>/dev/null)
  ((found == 1)) || warn '未找到 Docker 网络。'
}

show_one_container_network_path() {
  local container="$1" mode networks ports network ip gateway
  printf '\n%s服务：%s%s\n' "$BOLD" "$container" "$RESET"
  mode="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$container" 2>/dev/null || true)"
  printf '网络模式：%s\n' "${mode:--}"
  networks="$(docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}|{{$network.IPAddress}}|{{$network.Gateway}}{{"\n"}}{{end}}' "$container" 2>/dev/null || true)"
  if [[ -n "$networks" ]]; then
    printf '加入的网络：\n'
    while IFS='|' read -r network ip gateway; do
      [[ -n "$network" ]] || continue
      printf '  %s：容器 IP %s，网关 %s\n' "$network" "${ip:--}" "${gateway:--}"
      if [[ -n "$gateway" ]]; then
        printf '    路径：容器 %s → %s → 网关 %s → 宿主机/外部网络\n' "${ip:--}" "$network" "$gateway"
      else
        printf '    路径：容器 → %s（该网络没有可用的 Docker 网关）\n' "$network"
      fi
    done <<< "$networks"
  elif [[ "$mode" == host ]]; then
    printf '加入的网络：host（与宿主机共享网络命名空间）\n'
    printf '路径：容器服务 ↔ 宿主机网络，不经过 Docker bridge 网关。\n'
  else
    printf '加入的网络：无\n'
  fi
  ports="$(docker port "$container" 2>/dev/null || true)"
  if [[ -n "$ports" ]]; then
    printf '宿主机端口中转：\n'
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      printf '  %s\n' "$port"
    done <<< "$ports"
    printf '路径：外部/宿主机地址 → docker-proxy（如存在）→ 容器端口。\n'
  else
    printf '宿主机端口中转：无 Docker ports 发布。\n'
  fi
}

show_container_network_paths() {
  local selected container index
  local -a containers=()
  mapfile -t containers < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  ((${#containers[@]} > 0)) || { warn '未找到 Docker 容器。'; return 0; }

  printf '\n%s服务网络与中转路径%s\n' "$BOLD" "$RESET"
  printf '选择具体服务查看其网络、网关和端口中转；直接回车查看全部服务。\n'
  for index in "${!containers[@]}"; do
    printf '  %d. %s\n' "$((index + 1))" "${containers[$index]}"
  done
  read -r -p "请选择 [1-${#containers[@]}，回车查看全部，0取消]：" selected || return 0
  [[ "$selected" == 0 ]] && return 0
  if [[ -z "$selected" ]]; then
    for container in "${containers[@]}"; do
      show_one_container_network_path "$container"
    done
    return 0
  fi
  [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#containers[@]})) || { error '无效选项。'; return 1; }
  show_one_container_network_path "${containers[$((selected - 1))]}"
}

select_docker_container() {
  local selected index
  local -a containers=()
  mapfile -t containers < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  ((${#containers[@]} > 0)) || { warn '未找到 Docker 容器。'; return 1; }

  printf '\nDocker 容器服务：\n'
  for index in "${!containers[@]}"; do
    printf '  %d. %s\n' "$((index + 1))" "${containers[$index]}"
  done
  read -r -p "选择服务 [1-${#containers[@]}，回车取消]：" selected || return 1
  [[ -n "$selected" ]] || return 1
  [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#containers[@]})) || { error '无效选项。'; return 1; }
  SELECTED_DOCKER_CONTAINER="${containers[$((selected - 1))]}"
}

disconnect_service_network() {
  local container selected network index
  local -a networks=()
  select_docker_container || return 0
  container="$SELECTED_DOCKER_CONTAINER"
  mapfile -t networks < <(docker_container_network_names "$container")
  ((${#networks[@]} > 0)) || { warn "服务 ${container} 当前没有可断开的 Docker bridge 网络（可能使用 host/none 网络模式）。"; return 0; }

  printf '\n服务 %s 当前连接的 Docker 网络：\n' "$container"
  for index in "${!networks[@]}"; do
    printf '  %d. %s\n' "$((index + 1))" "${networks[$index]}"
  done
  read -r -p "选择要移除的网络 [1-${#networks[@]}，回车取消]：" selected || return 0
  [[ -n "$selected" ]] || return 0
  [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#networks[@]})) || { error '无效选项。'; return 1; }
  network="${networks[$((selected - 1))]}"
  if ((${#networks[@]} == 1)); then
    warn "这是服务 ${container} 当前唯一的 Docker 网络；移除后它将失去 bridge 网络通信能力。"
  fi
  confirm_action "确认将服务 ${container} 从网络 ${network} 移除？" || { info '已取消。'; return 0; }
  if docker network disconnect "$network" "$container"; then
    success "已将服务 ${container} 从网络 ${network} 移除。"
    info '该网络连接由 Docker 即时修改；Compose 重建容器后可能需要重新配置。'
  else
    error "无法将服务 ${container} 从网络 ${network} 移除。"
    return 1
  fi
}

connect_service_network() {
  local container selected network driver scope attached is_attached index
  local -a networks=() attached_networks=()
  select_docker_container || return 0
  container="$SELECTED_DOCKER_CONTAINER"
  mapfile -t attached_networks < <(docker_container_network_names "$container")
  while IFS= read -r network; do
    [[ -n "$network" ]] || continue
    is_attached=0
    for attached in "${attached_networks[@]}"; do
      [[ "$network" == "$attached" ]] && { is_attached=1; break; }
    done
    ((is_attached == 0)) && networks+=("$network")
  done < <(docker network ls --format '{{.Name}}' 2>/dev/null)

  ((${#networks[@]} > 0)) || { warn "服务 ${container} 已连接所有可用 Docker 网络。"; return 0; }
  printf '\n可供服务 %s 加入的 Docker 网络：\n' "$container"
  for index in "${!networks[@]}"; do
    network="${networks[$index]}"
    driver="$(docker network inspect --format '{{.Driver}}' "$network" 2>/dev/null || printf '%s' '未知')"
    scope="$(docker network inspect --format '{{.Scope}}' "$network" 2>/dev/null || printf '%s' '未知')"
    printf '  %d. %s（驱动：%s，范围：%s）\n' "$((index + 1))" "$network" "$driver" "$scope"
  done
  read -r -p "选择要加入的网络 [1-${#networks[@]}，回车取消]：" selected || return 0
  [[ -n "$selected" ]] || return 0
  [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#networks[@]})) || { error '无效选项。'; return 1; }
  network="${networks[$((selected - 1))]}"
  confirm_action "确认将服务 ${container} 加入网络 ${network}？" || { info '已取消。'; return 0; }
  if docker network connect "$network" "$container"; then
    success "已将服务 ${container} 加入网络 ${network}。"
    info '该网络连接由 Docker 即时修改；Compose 重建容器后可能需要重新配置。'
  else
    error "无法将服务 ${container} 加入网络 ${network}。"
    return 1
  fi
}

gateway_settings_menu() {
  local choice
  require_docker || return 1
  docker inspect nginx-proxy-manager >/dev/null 2>&1 || { error 'NPM 容器不存在，请先部署 Nginx Proxy Manager。'; return 1; }
  while true; do
    printf '\n%s网关设置%s\n' "$BOLD" "$RESET"
    printf '  1. 查看当前网关与网络\n'
    printf '  2. 从 Docker 网络移除服务\n'
    printf '  3. 将服务加入 Docker 网络\n'
    printf '  4. 本机 TCP 服务监听地址\n'
    printf '  0. 返回\n'
    read -r -p '请选择 [0-4]：' choice || return 0
    case "$choice" in
      1) show_gateway_networks; pause_menu ;;
      2) disconnect_service_network; pause_menu ;;
      3) connect_service_network; pause_menu ;;
      4) show_all_local_listeners; pause_menu ;;
      0) return 0 ;;
      *) error '无效选项。'; pause_menu ;;
    esac
  done
}

show_backend_guidance() {
  local mode
  mode="$(current_network_mode)"
  printf '\n%s后端连接建议%s\n' "$BOLD" "$RESET"
  if [[ "$mode" == host ]]; then
    cat <<'GUIDE'
当前为宿主机网络（host）。NPM 与宿主机共享网络命名空间：
  - 原生服务仅监听 127.0.0.1 时，在 NPM 中填写 127.0.0.1:服务端口。
  - Docker 应用可发布端口到宿主机，再以 127.0.0.1:宿主机端口访问。
  - 宿主机的 80、81、443 不可再由其他服务占用。
GUIDE
  else
    cat <<'GUIDE'
当前为官方默认桥接网络（bridge）：
  - 容器内的 127.0.0.1 不是宿主机；不能直接代理宿主机回环服务。
  - 容器化后端优先让 NPM 与应用加入同一 Docker 网络，并填写 服务名:内部端口。
  - 宿主机后端需监听可被 Docker 网关访问的地址，或切换到宿主机网络（host）。
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
  printf '  4. 完全卸载 Docker 与 Compose（删除所有 Docker 资源和运行时数据）\n'
  printf '  0. 返回\n'
  read -r -p '请选择 [0-4]：' choice
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
    4)
      uninstall_docker
      ;;
    0) return 0 ;;
    *) error '无效选项。'; return 1 ;;
  esac
}

status_line() {
  local mode state
  mode="$(current_network_mode)"
  state="$(docker inspect --format '{{.State.Status}}' nginx-proxy-manager 2>/dev/null || true)"
  printf 'NPM：%s | NPM运行状态：%s\n' \
    "$(npm_deployment_status)" \
    "$(colorize_container_state "$state")"
  printf 'Docker：%s | 网络：%s\n' \
    "$(docker_runtime_status)" \
    "${BLUE}$(short_network_mode "$mode")${RESET}"
  printf 'NPMCtl 版本：%s\n' \
    "$MANAGER_VERSION"
}

docker_runtime_status() {
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s未安装%s' "$RED" "$RESET"
  elif docker info >/dev/null 2>&1; then
    printf '%s已就绪%s' "$GREEN" "$RESET"
  else
    printf '%s服务不可用%s' "$RED" "$RESET"
  fi
}

npm_deployment_status() {
  if command -v docker >/dev/null 2>&1 \
      && docker inspect nginx-proxy-manager >/dev/null 2>&1; then
    printf '%s已部署%s' "$GREEN" "$RESET"
  elif [[ -f "$COMPOSE_FILE" ]]; then
    printf '%s配置已创建%s' "$YELLOW" "$RESET"
  else
    printf '%s未部署%s' "$YELLOW" "$RESET"
  fi
}

colorize_container_state() {
  local state="$1" color
  case "$state" in
    running) color="$GREEN" ;;
    created|restarting|paused|'') color="$YELLOW" ;;
    exited|dead) color="$RED" ;;
    *) color="$YELLOW" ;;
  esac
  printf '%s%s%s' "$color" "$(localize_container_state "$state")" "$RESET"
}

draw_menu() {
  clear 2>/dev/null || true
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '%s      NPMCtl · Nginx Proxy Manager 管理菜单%s\n' "$BOLD" "$RESET"
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  status_line
  printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
  printf '  1. 更新 NPMCtl 管理菜单\n'
  printf '  2. 本机服务端口监听助手\n'
  printf '  3. 网关设置（查看、连接或断开 Docker 网络）\n'
  printf '  4. 安装 Docker 与 Compose\n'
  printf '  5. 部署或更新 Nginx Proxy Manager\n'
  printf '  6. 切换网络模式（桥接网络 / 宿主机网络）\n'
  printf '  7. 查看运行状态与 Compose 配置\n'
  printf '  8. 查看后端连接建议\n'
  printf '  9. 查看 NPM 容器日志\n'
  printf ' 10. 查看 NPM 端口监听与 Docker 映射\n'
  printf ' 11. 备份 NPM 数据与证书\n'
  printf ' 12. 卸载 NPM、Docker 或 NPMCtl\n'
  printf '  0. 退出\n'
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '提示：退出后可在终端输入 npmctl 再次打开本菜单。\n'
}

main_menu() {
  local choice
  while true; do
    draw_menu
    read -r -p '请选择 [0-12]：' choice || exit 0
    printf '\n'
    case "$choice" in
      1) update_manager; pause_menu ;;
      2) local_service_listener_assistant; pause_menu ;;
      3) gateway_settings_menu; pause_menu ;;
      4) install_docker; pause_menu ;;
      5) deploy_npm "$(current_network_mode)"; pause_menu ;;
      6) switch_network_mode; pause_menu ;;
      7) show_status; pause_menu ;;
      8) show_backend_guidance; pause_menu ;;
      9) show_logs; pause_menu ;;
      10) show_listeners; pause_menu ;;
      11) backup_data; pause_menu ;;
      12) uninstall_menu; pause_menu ;;
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
