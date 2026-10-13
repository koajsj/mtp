#!/usr/bin/env bash
set -euo pipefail

MT_PROXY_DIR="/home/mtproxy"
UPSTREAM_URLS=(
  "https://raw.githubusercontent.com/ellermister/mtproxy/master/mtproxy.sh"
  "https://ghproxy.com/https://raw.githubusercontent.com/ellermister/mtproxy/master/mtproxy.sh"
)
: "${MT_PROXY_DEFAULT_PORT:=8443}"
export MT_PROXY_DEFAULT_PORT

log() {
  printf '[MTProxy] %s\n' "$*"
}

ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi

  log "curl not found, trying to install it"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl
  else
    log "no supported package manager was found"
    exit 1
  fi
}

download_upstream_installer() {
  local url
  for url in "${UPSTREAM_URLS[@]}"; do
    log "downloading MTProxy installer from ${url}"
    if curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 1 -o mtproxy.sh "$url"; then
      return 0
    fi
    log "failed to download from ${url}, trying next mirror"
  done

  log "all installer download URLs failed"
  exit 1
}

main() {
  ensure_curl

  mkdir -p "$MT_PROXY_DIR"
  cd "$MT_PROXY_DIR"

  download_upstream_installer
  if grep -q 'default_port=443' mtproxy.sh; then
    sed -i 's/default_port=443/default_port="${MT_PROXY_DEFAULT_PORT:-8443}"/' mtproxy.sh
  else
    log "upstream installer layout changed; refusing to keep 443 as the default port"
    exit 1
  fi
  chmod +x mtproxy.sh

  log "starting upstream installer"
  exec bash ./mtproxy.sh "$@"
}

main "$@"
