#!/usr/bin/env bash
set -euo pipefail
APP=/opt/mtp
CONFIG=/etc/mtp
LOG=/var/log/mtp
UNIT=/etc/systemd/system/mtp.service
TIMER=/etc/systemd/system/mtp-refresh.timer
REFRESH=/etc/systemd/system/mtp-refresh.service
ROTATE=/etc/logrotate.d/mtp
ENGINE_SHA=93b3530c3543b278c65a21c8bb4843ae7e5662ba
ENGINE_ARCHIVE_SHA256=dec55722e908e51f8bf1ff211ee4efcfca5cd93b3f3c877aa78b4e2881fe5615
say() { printf '[mtp] %s\n' "$*"; }
die() { printf '[mtp] 错误：%s\n' "$*" >&2; return 1; }
usage() { printf '用法：bash MTP一键部署.sh install [--port 8443] [--stats-port 8888] [--domain 域名] [--server 公网IP或域名] [--tag 32位十六进制]\n       /opt/mtp/mtp {start|stop|restart|status|link|refresh|uninstall}\n'; }
valid_port() { [[ $1 =~ ^[1-9][0-9]*$ ]] && (( 10#$1 <= 65535 )); }
valid_host() { [[ ${#1} -le 253 && $1 =~ ^[a-zA-Z0-9.-]+$ && $1 != .* && $1 != *. && $1 != *..* ]]; }
root_only() { [[ $EUID -eq 0 ]] || die '请使用 sudo'; }
lock() { command -v flock >/dev/null || die '缺少 flock'; exec 9>/run/mtp-install.lock; flock -n 9 || die '另一个 mtp 操作正在进行'; }
preflight() {
  [[ $(uname -s) == Linux && -d /run/systemd/system ]] || die '需要 Linux/systemd';
  [[ $(uname -m) == x86_64 ]] || die '当前固定版本的引擎仅支持 x86_64';
  [[ -f /etc/os-release ]] || die '无法识别发行版';
  [[ -x /usr/sbin/nologin ]] || die '缺少 /usr/sbin/nologin';
  for c in systemctl ss curl tar make cc od useradd groupadd getent sha256sum; do command -v "$c" >/dev/null || die "缺少 $c"; done
}
port_lines() { ss -H -ltnp "( sport = :$1 )"; }
require_free_port() {
  local lines docker_lines
  lines=$(port_lines "$1") || die "无法检查 TCP $1"
  if [[ -n $lines ]]; then
    printf '[mtp] TCP %s 已占用：\n%s\n' "$1" "$lines" >&2
    die '请保留现有服务，选择其他端口；不会终止占用进程'
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker_lines=$(docker ps --format '{{.Names}} {{.Ports}}') || die '无法检查 Docker 端口映射'
    docker_lines=$(printf '%s\n' "$docker_lines" | grep -E "(^|[[:space:],])[^[:space:],]*:$1->" || :)
    if [[ -n $docker_lines ]]; then
      printf '[mtp] TCP %s 已由 Docker 容器发布：\n%s\n' "$1" "$docker_lines" >&2
      die '请保留现有容器并选择其他端口'
    fi
  fi
}
read_value() {
  local key=$1 value
  [[ $(grep -c "^${key}=" "$CONFIG/mtp.conf") -eq 1 ]] || return 1
  value=$(sed -n "s/^${key}=//p" "$CONFIG/mtp.conf")
  printf '%s' "$value"
}
load_config() {
  [[ -f $CONFIG/mtp.conf && ! -L $CONFIG/mtp.conf ]] || die '配置不存在或为符号链接'
  PORT=$(read_value PORT) && STATS_PORT=$(read_value STATS_PORT) && SECRET=$(read_value SECRET) && DOMAIN=$(read_value DOMAIN) && SERVER=$(read_value SERVER) && TAG=$(read_value TAG) || die '配置缺失或字段重复'
  valid_port "$PORT" && valid_port "$STATS_PORT" && [[ $PORT != "$STATS_PORT" && $SECRET =~ ^[0-9a-f]{32}$ ]] && valid_host "$DOMAIN" && valid_host "$SERVER" || die '配置无效'
  [[ -z $TAG || $TAG =~ ^[0-9a-fA-F]{32}$ ]] || die 'Tag 无效'
  [[ $(wc -l < "$CONFIG/mtp.conf") -eq 6 ]] || die '配置包含未知字段'
}
show_link() {
  local hex
  hex=$(printf '%s' "$DOMAIN" | od -An -tx1 | tr -d ' \n')
  printf 'tg://proxy?server=%s&port=%s&secret=ee%s%s\n' "$SERVER" "$PORT" "$SECRET" "$hex"
  printf 'https://t.me/proxy?server=%s&port=%s&secret=ee%s%s\n' "$SERVER" "$PORT" "$SECRET" "$hex"
}
fetch() {
  curl --proto '=https' --tlsv1.2 --noproxy '*' -fsSL --connect-timeout 8 --max-time 60 "$1" -o "$2"
  [[ -s $2 ]] || die "下载为空：$1"
}
owner_check() {
  for dir in "$APP" "$CONFIG" "$LOG"; do
    [[ -d $dir && ! -L $dir && -f $dir/.owner && ! -L $dir/.owner ]] || die "$dir 无归属标记"
    [[ $(cat "$dir/.owner") == mtp-owned-v1 ]] || die "$dir 归属标记不匹配"
  done
  [[ -f $UNIT && ! -L $UNIT ]] && grep -q '^Description=MTProto Proxy (mtp-owned)$' "$UNIT" || die '服务文件不是本项目的'
  [[ -f $TIMER && ! -L $TIMER && -f $REFRESH && ! -L $REFRESH && -f $APP/mtp && ! -L $APP/mtp && -f $ROTATE && ! -L $ROTATE ]] || die '安装文件不完整'
  grep -q '^# mtp-owned-v1$' "$TIMER" && grep -q '^# mtp-owned-v1$' "$REFRESH" || die '定时任务不是本项目的'
  grep -q '^# mtp-owned-v1$' "$ROTATE" || die '日志轮转配置不是本项目的'
}
no_unrelated_files() {
  local path
  while IFS= read -r path; do
    case "$path" in
      "$APP"|"$APP/bin"|"$APP/.owner"|"$APP/mtp"|"$APP/bin/mtproto-proxy"|\
      "$CONFIG"|"$CONFIG/.owner"|"$CONFIG/mtp.conf"|"$CONFIG/proxy-secret"|"$CONFIG/proxy-multi.conf"|\
      "$LOG"|"$LOG/.owner"|"$LOG/mtp.log"|"$LOG/mtp.log".[0-9]*|"$LOG/mtp.log".[0-9]*.gz) ;;
      *) die "发现非本项目文件 ${path}；拒绝自动删除";;
    esac
  done < <(find "$APP" "$CONFIG" "$LOG" -print)
}
install_proxy() {
  root_only; preflight; lock
  for path in "$APP" "$CONFIG" "$LOG" "$UNIT" "$TIMER" "$REFRESH" "$ROTATE"; do
    [[ ! -e $path && ! -L $path ]] || die "$path 已存在，拒绝覆盖"
  done
  local unit_name fragment
  for unit_name in mtp.service mtp-refresh.service mtp-refresh.timer; do
    fragment=$(systemctl show -p FragmentPath --value "$unit_name") || die "无法检查 $unit_name"
    [[ -z $fragment ]] || die "systemd 中已存在 $unit_name ($fragment)，拒绝覆盖"
  done
  [[ -z $(getent passwd mtp || :) && -z $(getent group mtp || :) ]] || die 'mtp 用户或组已存在，拒绝复用'
  PORT=${MT_PROXY_DEFAULT_PORT:-8443}; STATS_PORT=8888; DOMAIN=www.cloudflare.com; SERVER=; TAG=
  while (($#)); do
    case "$1" in
      --port|--stats-port|--domain|--server|--tag)
        (($# >= 2)) || die "$1 缺少值"
        case "$1" in
          --port) PORT=$2;; --stats-port) STATS_PORT=$2;; --domain) DOMAIN=$2;; --server) SERVER=$2;; --tag) TAG=$2;;
        esac
        shift 2;;
      *) die "未知参数：$1";;
    esac
  done
  valid_port "$PORT" && valid_port "$STATS_PORT" && [[ $PORT != "$STATS_PORT" ]] || die '端口必须为 1-65535，且客户端与统计端口不同'
  (( STATS_PORT >= 1024 )) || die '统计端口必须在 1024-65535 范围'
  valid_host "$DOMAIN" || die 'Fake TLS 域名无效'
  [[ -z $SERVER ]] || valid_host "$SERVER" || die '服务器地址无效'
  [[ -z $TAG || $TAG =~ ^[0-9a-fA-F]{32}$ ]] || die 'Tag 必须是 32 位十六进制'
  require_free_port "$PORT"; require_free_port "$STATS_PORT"
  if [[ -z $SERVER ]]; then
    SERVER=$(curl --noproxy '*' -4fsS --connect-timeout 5 --max-time 12 https://api.ipify.org) || die '无法获取公网 IPv4，请指定 --server'
    valid_host "$SERVER" || die '公网 IP 响应无效'
  fi
  local work
  work=$(mktemp -d)
  trap 'rm -rf "$work"' RETURN
  fetch "https://codeload.github.com/ellermister/MTProxyC/tar.gz/$ENGINE_SHA" "$work/engine.tar.gz"
  printf '%s  %s\n' "$ENGINE_ARCHIVE_SHA256" "$work/engine.tar.gz" | sha256sum -c - >/dev/null || die '引擎源码校验失败'
  tar -tzf "$work/engine.tar.gz" | awk '($0 ~ /^\/|$0 ~ /(^|\/)\.\.\//) {bad=1} END {exit bad}' || die '源码包路径不安全'
  mkdir "$work/src"
  tar -xzf "$work/engine.tar.gz" -C "$work/src" --strip-components=1
  [[ -f $work/src/Makefile ]] || die '引擎源码包格式不符'
  make -C "$work/src" -j2 >/dev/null
  [[ -x $work/src/objs/bin/mtproto-proxy ]] || die '编译失败'
  fetch https://core.telegram.org/getProxySecret "$work/proxy-secret"
  fetch https://core.telegram.org/getProxyConfig "$work/proxy-multi.conf"
  [[ $(wc -c < "$work/proxy-secret") -ge 64 ]] && grep -q '^proxy_for ' "$work/proxy-multi.conf" || die 'Telegram 配置数据无效'
  require_free_port "$PORT"; require_free_port "$STATS_PORT"
  groupadd --system mtp
  local user_created=0
  trap 'cleanup_failed_install' ERR
  useradd --system --gid mtp --home-dir /nonexistent --shell /usr/sbin/nologin mtp
  user_created=1
  mkdir -m 0755 "$APP"
  printf 'mtp-owned-v1\n' > "$APP/.owner"
  mkdir -m 0755 "$APP/bin"
  mkdir -m 0750 "$CONFIG"
  printf 'mtp-owned-v1\n' > "$CONFIG/.owner"
  mkdir -m 0750 "$LOG"
  printf 'mtp-owned-v1\n' > "$LOG/.owner"
  chown root:mtp "$CONFIG" "$LOG"
  install -m 0755 "$work/src/objs/bin/mtproto-proxy" "$APP/bin/mtproto-proxy"
  install -m 0755 "${BASH_SOURCE[0]}" "$APP/mtp"
  install -m 0640 -g mtp "$work/proxy-secret" "$CONFIG/proxy-secret"
  install -m 0644 "$work/proxy-multi.conf" "$CONFIG/proxy-multi.conf"
  SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  (umask 027; printf 'PORT=%s\nSTATS_PORT=%s\nSECRET=%s\nDOMAIN=%s\nSERVER=%s\nTAG=%s\n' "$PORT" "$STATS_PORT" "$SECRET" "$DOMAIN" "$SERVER" "$TAG" > "$CONFIG/mtp.conf")
  chown root:mtp "$CONFIG/mtp.conf"
  touch "$LOG/mtp.log"
  chown mtp:mtp "$LOG/mtp.log"
  chmod 0640 "$LOG/mtp.log"
  set -C
  cat > "$UNIT" <<'EOF'
[Unit]
Description=MTProto Proxy (mtp-owned)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=mtp
Group=mtp
WorkingDirectory=/opt/mtp
ExecStart=/bin/bash -c 'exec /opt/mtp/mtp run >> /var/log/mtp/mtp.log 2>&1'
Restart=always
RestartSec=5s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
EOF
  cat > "$REFRESH" <<'EOF'
# mtp-owned-v1
[Unit]
Description=Refresh MTProxy Telegram configuration (mtp-owned)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/mtp/mtp refresh
EOF
  cat > "$TIMER" <<'EOF'
# mtp-owned-v1
[Unit]
Description=Daily MTProxy Telegram configuration refresh (mtp-owned)
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
Unit=mtp-refresh.service
[Install]
WantedBy=timers.target
EOF
  cat > "$ROTATE" <<'EOF'
# mtp-owned-v1
/var/log/mtp/mtp.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su mtp mtp
}
EOF
  set +C
  if (( PORT < 1024 )); then
    sed -i 's/^CapabilityBoundingSet=$/CapabilityBoundingSet=CAP_NET_BIND_SERVICE/; s/^AmbientCapabilities=$/AmbientCapabilities=CAP_NET_BIND_SERVICE/' "$UNIT"
  fi
  chmod 0644 "$UNIT" "$TIMER" "$REFRESH" "$ROTATE"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$UNIT" "$REFRESH" "$TIMER" || die 'systemd 配置检查失败'
  fi
  systemctl daemon-reload
  systemctl enable --now mtp.service
  sleep 2
  systemctl is-active --quiet mtp.service || die '服务启动失败，请查 mtp 日志'
  ss -H -ltn "( sport = :$PORT )" | grep -q . || die '服务未监听指定端口'
  systemctl enable --now mtp-refresh.timer
  trap - ERR
  say "运行中，TCP ${PORT}，Secret：$SECRET"
  show_link
  say '管理：sudo /opt/mtp/mtp status|start|stop|restart|link|uninstall'
  say "请手动在云安全组及既有防火墙中允许 TCP ${PORT}；本程序未改动防火墙"
}
cleanup_failed_install() {
  say '安装失败，清理本次创建的资源'
  if [[ -f $UNIT ]] && grep -q '^Description=MTProto Proxy (mtp-owned)$' "$UNIT"; then
    systemctl disable --now mtp-refresh.timer mtp.service >/dev/null 2>&1 || :
  fi
  [[ -f $UNIT ]] && grep -q '^Description=MTProto Proxy (mtp-owned)$' "$UNIT" && rm -f -- "$UNIT" || :
  for file in "$TIMER" "$REFRESH" "$ROTATE"; do
    [[ -f $file ]] && grep -q '^# mtp-owned-v1$' "$file" && rm -f -- "$file" || :
  done
  systemctl daemon-reload >/dev/null 2>&1 || :
  for dir in "$APP" "$CONFIG" "$LOG"; do
    [[ -f $dir/.owner && ! -L $dir && $(cat "$dir/.owner") == mtp-owned-v1 ]] && rm -rf -- "$dir" || :
  done
  if [[ ${user_created:-0} == 1 ]]; then userdel mtp >/dev/null 2>&1 || :; fi
  groupdel mtp >/dev/null 2>&1 || :
}
run_proxy() {
  load_config
  local -a args=(-p "$STATS_PORT" -H "$PORT" -S "$SECRET" --aes-pwd "$CONFIG/proxy-secret" "$CONFIG/proxy-multi.conf" --domain "$DOMAIN")
  [[ -z $TAG ]] || args+=(-P "$TAG")
  exec "$APP/bin/mtproto-proxy" "${args[@]}"
}
status_proxy() {
  load_config
  systemctl --no-pager --full status mtp.service || :
  printf '客户端 TCP %s；统计 TCP %s；PID %s\n' "$PORT" "$STATS_PORT" "$(systemctl show -p MainPID --value mtp.service)"
  ss -H -ltnp "( sport = :$PORT )" || :
  tail -n 20 "$LOG/mtp.log" || :
}
refresh_proxy() {
  root_only; lock; owner_check
  local temp backup
  temp=$(mktemp "$CONFIG/.new.XXXXXX"); backup=$(mktemp "$CONFIG/.old.XXXXXX")
  trap 'rm -f "$temp" "$backup"' RETURN
  fetch https://core.telegram.org/getProxyConfig "$temp"
  grep -q '^proxy_for ' "$temp" || die '新配置无效，保留旧配置'
  cp -p "$CONFIG/proxy-multi.conf" "$backup"
  chmod 0644 "$temp"
  mv -f "$temp" "$CONFIG/proxy-multi.conf"
  if ! systemctl restart mtp.service; then
    mv -f "$backup" "$CONFIG/proxy-multi.conf"
    systemctl restart mtp.service || :
    die '新配置启动失败，已恢复旧配置'
  fi
  sleep 2
  load_config
  if ! systemctl is-active --quiet mtp.service || [[ -z $(ss -H -ltn "( sport = :$PORT )") ]]; then
    mv -f "$backup" "$CONFIG/proxy-multi.conf"
    systemctl restart mtp.service || :
    die '新配置启动失败，已恢复旧配置'
  fi
  say 'Telegram 配置已更新'
}
uninstall_proxy() {
  root_only; lock; owner_check; no_unrelated_files
  local old_port
  old_port=$(read_value PORT || :)
  cat <<'EOF'
将停止并删除 mtp.service、mtp-refresh.timer，删除 mtp 用户/组及专属目录：
/opt/mtp /etc/mtp /var/log/mtp
/etc/systemd/system/mtp.service /etc/systemd/system/mtp-refresh.service /etc/systemd/system/mtp-refresh.timer
/etc/logrotate.d/mtp
不会删除其他服务、旧版 /home/mtproxy 安装或更改防火墙。
EOF
  local answer
  read -r -p '输入 YES 确认删除：' answer
  [[ $answer == YES ]] || die '已取消'
  systemctl disable --now mtp-refresh.timer mtp.service
  rm -f -- "$UNIT" "$TIMER" "$REFRESH" "$ROTATE"
  systemctl daemon-reload
  rm -rf -- "$APP" "$CONFIG" "$LOG"
  userdel mtp
  groupdel mtp 2>/dev/null || :
  [[ ! -e $UNIT && ! -e $APP && ! -e $CONFIG && ! -e $LOG ]] || die '文件清理不完整'
  [[ $(systemctl show -p LoadState --value mtp.service) == not-found ]] || die '服务仍存在'
  if valid_port "$old_port" && [[ -n $(port_lines "$old_port") ]]; then
    say "卸载完成，但 TCP ${old_port} 仍有监听；请用 ss -ltnp 查看是否被其他服务使用"
  else
    say '卸载完成；原客户端端口当前未监听'
  fi
}
main() {
  local action=${1:-}
  [[ $# -gt 0 ]] && shift || :
  case "$action" in
    install) install_proxy "$@";;
    run) run_proxy;;
    status) root_only; status_proxy;;
    link) root_only; load_config; show_link;;
    refresh) refresh_proxy;;
    start|stop|restart) root_only; owner_check; systemctl "$action" mtp.service;;
    uninstall) uninstall_proxy;;
    *) usage >&2; return 2;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
