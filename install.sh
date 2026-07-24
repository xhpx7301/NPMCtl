#!/usr/bin/env bash

# Bootstrap NPMCtl from the public project repository.
set -Eeuo pipefail

readonly SOURCE_URL="${NPMCTL_SOURCE_URL:-https://raw.githubusercontent.com/xhpx7301/NPMCtl/main/npmctl.sh}"
readonly TEMP_DIR="$(mktemp -d)"
readonly MANAGER_SCRIPT="${TEMP_DIR}/npmctl.sh"

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

cache_busted_github_raw_url() {
  local source_url="$1" separator
  case "$source_url" in
    https://raw.githubusercontent.com/*)
      [[ "$source_url" == *\?* ]] && separator="&" || separator="?"
      printf '%s%snpmctl_cache_bust=%s-%s-%s\n' "$source_url" "$separator" "$(date +%s)" "$$" "$RANDOM"
      ;;
    *) printf '%s\n' "$source_url" ;;
  esac
}

download_manager() {
  local download_url
  download_url="$(cache_busted_github_raw_url "$SOURCE_URL")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 -H 'Cache-Control: no-cache' "$download_url" -o "$MANAGER_SCRIPT"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$MANAGER_SCRIPT" --header='Cache-Control: no-cache' "$download_url"
  else
    printf '需要 curl 或 wget 才能下载安装程序。\n' >&2
    exit 1
  fi
}

download_manager
chmod 0755 "$MANAGER_SCRIPT"

if [[ ! -r /dev/tty ]]; then
  printf '未检测到可交互终端，无法打开 NPMCtl 菜单。请在 SSH 终端中运行此命令。\n' >&2
  exit 1
fi

# `curl | bash` consumes standard input, so hand menu input back to the terminal.
bash "$MANAGER_SCRIPT" --install-manager </dev/tty
