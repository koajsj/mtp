#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
# 管理命令使用固定系统 PATH，避免 sudo 保留的用户 PATH。
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
SCRIPT_PATH=${BASH_SOURCE[0]}
APP=/opt/mtp
CONFIG=/etc/mtp
LOG=/var/log/mtp
UNIT=/etc/systemd/system/mtp.service
TIMER=/etc/systemd/system/mtp-refresh.timer
REFRESH=/etc/systemd/system/mtp-refresh.service
ROTATE=/etc/logrotate.d/mtp
MOUNTINFO=/proc/self/mountinfo
LOCK=/run/mtp-install.lock
ENGINE_SHA=93b3530c3543b278c65a21c8bb4843ae7e5662ba
ENGINE_ARCHIVE_SHA256=dec55722e908e51f8bf1ff211ee4efcfca5cd93b3f3c877aa78b4e2881fe5615
say() { printf '[mtp] %s\n' "$*"; }
die() { printf '[mtp] 错误：%s\n' "$*" >&2; exit 1; }
usage() { printf '用法：bash MTP一键部署.sh install [--port 8443] [--stats-port 8888] [--domain 域名] [--server 公网IP或域名] [--tag 32位十六进制]\n       /opt/mtp/mtp {start|stop|restart|status|self-test|link|refresh|uninstall}\n'; }
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
valid_host() { [[ ${#1} -le 253 && $1 =~ ^[a-zA-Z0-9.-]+$ && $1 != .* && $1 != *. && $1 != *..* ]]; }
root_only() { [[ $EUID -eq 0 ]] || die '请使用 sudo'; }
lock() {
  command -v flock >/dev/null || die '缺少 flock'
  if [[ -e $LOCK || -L $LOCK ]]; then
    [[ -f $LOCK && ! -L $LOCK && $(stat -c %u "$LOCK") == 0 && $(stat -c %h "$LOCK") == 1 ]] || die '锁文件不安全，拒绝操作'
    (( (8#$(stat -c %a "$LOCK") & 0022) == 0 )) || die '锁文件允许其他用户写入，拒绝操作'
  fi
  # 不截断现有文件，也不 unlink 锁：删除后重建会让不同进程锁住不同 inode。
  exec 9>>"$LOCK"
  flock -n 9 || die '另一个 mtp 操作正在进行'
}
preflight() {
  [[ $(uname -s) == Linux && -d /run/systemd/system ]] || die '需要 Linux/systemd';
  [[ $(uname -m) == x86_64 ]] || die '当前固定版本的引擎仅支持 x86_64';
  [[ -f /etc/os-release ]] || die '无法识别发行版';
  [[ -x /usr/sbin/nologin ]] || die '缺少 /usr/sbin/nologin';
  for c in systemctl ss curl tar make cc od useradd userdel groupadd groupdel getent sha256sum stat find install logrotate cmp; do command -v "$c" >/dev/null || die "缺少 $c"; done
  [[ -d /tmp && ! -L /tmp && $(stat -c %u /tmp) == 0 ]] || die '/tmp 必须是 root 所有的常规目录'
  local mode
  mode=$(stat -c %a /tmp) || die '无法检查临时目录权限'
  (( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || die '/tmp 可被其他用户写入但没有 sticky bit，拒绝构建'
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
    docker_lines=$(printf '%s\n' "$docker_lines" | awk -v port="$1" '
      { original=$0; gsub(/,/, " ")
        for (i=2; i<=NF; i++) {
          if ($i !~ /->.*\/tcp$/) continue
          split($i, mapping, "->"); sub(/^.*:/, "", mapping[1])
          n=split(mapping[1], range, "-"); high=(n==2 ? range[2] : range[1])
          if (range[1] ~ /^[0-9]+$/ && high ~ /^[0-9]+$/ && port>=range[1]+0 && port<=high+0) {print original; break}
        }
      }') || die '无法解析 Docker 端口映射'
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
  local line key value seen='|' count=0
  [[ -f $CONFIG/mtp.conf && ! -L $CONFIG/mtp.conf ]] || die '配置不存在或为符号链接'
  # 先校验原始字节：Bash 会丢弃 NUL，wc -l 会漏掉没有换行的末尾字段。
  [[ $(wc -c < "$CONFIG/mtp.conf") -le 4096 ]] || die '配置过大'
  [[ $(LC_ALL=C tr -d '\12\40-\176' < "$CONFIG/mtp.conf" | wc -c) -eq 0 ]] || die '配置包含非文本或控制字符'
  PORT=; STATS_PORT=; SECRET=; DOMAIN=; SERVER=; TAG=
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *=* ]] || die '配置包含空行或无效字段'
    key=${line%%=*}; value=${line#*=}
    [[ $seen != *"|$key|"* ]] || die '配置字段重复'
    case "$key" in
      PORT) PORT=$value;; STATS_PORT) STATS_PORT=$value;; SECRET) SECRET=$value;;
      DOMAIN) DOMAIN=$value;; SERVER) SERVER=$value;; TAG) TAG=$value;;
      *) die '配置包含未知字段';;
    esac
    seen+="$key|"; count=$((count + 1))
  done < "$CONFIG/mtp.conf"
  [[ $count -eq 6 ]] || die '配置缺失'
  valid_port "$PORT" && valid_port "$STATS_PORT" && [[ $PORT != "$STATS_PORT" && $SECRET =~ ^[0-9a-f]{32}$ ]] && valid_host "$DOMAIN" && valid_host "$SERVER" && (( STATS_PORT >= 1024 )) || die '配置无效'
  [[ -z $TAG || $TAG =~ ^[0-9a-fA-F]{32}$ ]] || die 'Tag 无效'
}
show_link() {
  local hex
  hex=$(printf '%s' "$DOMAIN" | od -An -tx1 | tr -d ' \n')
  printf 'tg://proxy?server=%s&port=%s&secret=ee%s%s\n' "$SERVER" "$PORT" "$SECRET" "$hex"
  printf 'https://t.me/proxy?server=%s&port=%s&secret=ee%s%s\n' "$SERVER" "$PORT" "$SECRET" "$hex"
}
fetch() {
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --noproxy '*' -fsSL --connect-timeout 8 --max-time 60 "$1" -o "$2" || return 1
  [[ -s $2 ]] || die "下载为空：$1"
}
valid_telegram_config() {
  [[ -f $1 && ! -L $1 && $(wc -c < "$1") -gt 0 && $(wc -c < "$1") -le 1048576 ]] || return 1
  [[ $(LC_ALL=C tr -d '\11\12\15\40-\176' < "$1" | wc -c) -eq 0 ]] || return 1
  # 只校验已使用的 proxy_for 指令，不重写引擎配置语法。
  LC_ALL=C awk '
    { sub(/\r$/, "")
      if ($0 ~ /<[!\/[:alpha:]]/) bad=1
      if ($1 == "proxy_for") {
        if ($0 !~ "^[[:space:]]*proxy_for[[:space:]]+-?[0-9]+[[:space:]]+[^[:space:];]+:[0-9]+;([[:space:]]*(#.*|//.*)?)?$") bad=1
        port=$3; sub(/;.*/, "", port); sub(/^.*:/, "", port)
        if (length(port)>5 || port+0<1 || port+0>65535) bad=1
        found=1
      }
    } END { exit (bad || !found) }' "$1"
}
safe_layout() {
  local dir file
  for dir in "$APP" "$CONFIG" "$LOG" "$APP/bin"; do
    [[ -d $dir && ! -L $dir ]] || die "$dir 不是安全目录"
    [[ $(stat -c %u "$dir") == 0 ]] || die "$dir 必须归 root 所有"
    (( (8#$(stat -c %a "$dir") & 0022) == 0 )) || die "$dir 不可允许组/其他用户写入"
  done
  for file in "$CONFIG/mtp.conf" "$CONFIG/proxy-secret" "$CONFIG/proxy-multi.conf" "$APP/mtp" "$APP/bin/mtproto-proxy"; do
    [[ -f $file && ! -L $file && $(stat -c %u "$file") == 0 ]] || die "$file 不是 root 所有的常规文件"
    (( (8#$(stat -c %a "$file") & 0022) == 0 )) || die "$file 不可允许组/其他用户写入"
  done
  for file in "$CONFIG/mtp.conf" "$CONFIG/proxy-secret"; do
    (( (8#$(stat -c %a "$file") & 0007) == 0 )) || die "$file 不可允许其他用户访问"
  done
  [[ -f $LOG/mtp.log && ! -L $LOG/mtp.log ]] || die '日志不存在或为符号链接'
}
runtime_permissions() {
  local uid gid file
  uid=$(id -u mtp) && gid=$(id -g mtp) || die 'mtp 账号不存在'
  for file in "$CONFIG/mtp.conf" "$CONFIG/proxy-secret"; do
    [[ $(stat -c %g "$file") == "$gid" && $(stat -c %a "$file") == 640 ]] || die "$file 需要 root:mtp 0640，确保 mtp 可以读取"
  done
  for file in "$CONFIG" "$LOG"; do
    [[ $(stat -c %g "$file") == "$gid" && $(stat -c %a "$file") == 750 ]] || die "$file 需要 root:mtp 0750"
  done
  [[ $(stat -c %u "$LOG/mtp.log") == "$uid" && $(stat -c %g "$LOG/mtp.log") == "$gid" && $(stat -c %a "$LOG/mtp.log") == 640 ]] || die '日志需要 mtp:mtp 0640'
  for file in "$APP/mtp" "$APP/bin/mtproto-proxy"; do
    [[ $(stat -c %a "$file") == 755 ]] || die "$file 需要 0755，确保 mtp 可以执行"
  done
  [[ $(wc -c < "$CONFIG/proxy-secret") -ge 64 ]] && valid_telegram_config "$CONFIG/proxy-multi.conf" || die 'Telegram 数据文件不完整'
}
mtp_account_entry() {
  local entry result
  if entry=$(getent "$1" mtp); then
    [[ -n $entry ]] || die "查询 mtp $1 返回空记录，拒绝操作"
    printf '%s' "$entry"
  else
    result=$?
    # GNU getent 的 2 表示指定账号不存在；其他错误不能视为不存在。
    [[ $result == 2 ]] || die "无法查询 mtp $1（getent 返回 $result），拒绝操作"
  fi
}
account_check() {
  local uid gid entry group_entry other
  [[ -f $CONFIG/account && ! -L $CONFIG/account && $(stat -c %u "$CONFIG/account") == 0 ]] || die '缺少安全的用户归属记录；旧安装请先人工核验用户，不能自动删除'
  [[ $(stat -c %a "$CONFIG/account") == 600 ]] || die '用户归属记录必须为 0600'
  read -r uid gid < "$CONFIG/account"
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $uid != 0 && $gid != 0 ]] || die '用户归属记录无效'
  entry=$(mtp_account_entry passwd) || die '无法核验 mtp 用户'
  if [[ -n $entry ]]; then
    [[ $(printf '%s' "$entry" | cut -d: -f3-4) == "$uid:$gid" && $(printf '%s' "$entry" | cut -d: -f6-7) == /nonexistent:/usr/sbin/nologin ]] || die 'mtp 用户已更换或不属于本安装，拒绝删除'
  fi
  group_entry=$(mtp_account_entry group) || die '无法核验 mtp 组'
  if [[ -n $group_entry ]]; then
    [[ $(printf '%s' "$group_entry" | cut -d: -f3-4) == "$gid:" ]] || die 'mtp 组已更换或包含其他成员，拒绝删除'
  fi
  other=$(getent passwd | awk -F: -v gid="$gid" -v uid="$uid" '($4 == gid || $3 == uid) && $1 != "mtp" {print $1}') || die '无法枚举系统账号，拒绝删除'
  [[ -z $other ]] || die "mtp 组被其他用户使用：$other"
}
# 可编辑配置和日志不参与摘要；静态安装文件及目录身份必须保持一致。
manifest_content() {
  local dir identity
  for dir in "$APP" "$APP/bin" "$CONFIG" "$LOG"; do
    identity=$(stat -c '%d:%i' "$dir") || return 1
    printf '%s %s\n' "$identity" "$dir"
  done
  sha256sum -- "$APP/mtp" "$APP/bin/mtproto-proxy" "$CONFIG/account" "$UNIT" "$TIMER" "$REFRESH" "$ROTATE"
}
manifest_check() {
  local actual recorded
  [[ -f $CONFIG/manifest && ! -L $CONFIG/manifest && $(stat -c %u "$CONFIG/manifest") == 0 && $(stat -c %a "$CONFIG/manifest") == 600 ]] || die '缺少安全的安装归属记录；拒绝自动管理'
  actual=$(manifest_content) || die '无法核验安装归属记录'
  recorded=$(cat "$CONFIG/manifest") || die '无法读取安装归属记录'
  [[ $actual == "$recorded" ]] || die '安装文件或目录已变更，与归属记录不符；拒绝自动管理'
}
no_mounts() {
  local mounted
  mounted=$(awk -v app="$APP" -v config="$CONFIG" -v logdir="$LOG" -v unit="$UNIT" -v timer="$TIMER" -v refresh="$REFRESH" -v rotate="$ROTATE" '
    $5==app || index($5,app "/")==1 || $5==config || index($5,config "/")==1 ||
    $5==logdir || index($5,logdir "/")==1 || $5==unit || $5==timer || $5==refresh || $5==rotate {print $5}
  ' "$MOUNTINFO") || die '无法检查安装路径的挂载状态'
  [[ -z $mounted ]] || die "安装路径包含挂载点，拒绝自动管理：$mounted"
}
owner_check() {
  safe_layout
  no_mounts
  manifest_check
  for dir in "$APP" "$CONFIG" "$LOG"; do
    [[ -d $dir && ! -L $dir && -f $dir/.owner && ! -L $dir/.owner ]] || die "$dir 无归属标记"
    [[ $(stat -c %u "$dir/.owner") == 0 ]] && (( (8#$(stat -c %a "$dir/.owner") & 0022) == 0 )) || die "$dir 归属标记权限不安全"
    [[ $(cat "$dir/.owner") == mtp-owned-v1 ]] || die "$dir 归属标记不匹配"
  done
  [[ -f $UNIT && ! -L $UNIT ]] && grep -q '^Description=MTProto Proxy (mtp-owned)$' "$UNIT" || die '服务文件不是本项目的'
  [[ -f $TIMER && ! -L $TIMER && -f $REFRESH && ! -L $REFRESH && -f $APP/mtp && ! -L $APP/mtp && -f $ROTATE && ! -L $ROTATE ]] || die '安装文件不完整'
  grep -q '^# mtp-owned-v1$' "$TIMER" && grep -q '^# mtp-owned-v1$' "$REFRESH" || die '定时任务不是本项目的'
  grep -q '^# mtp-owned-v1$' "$ROTATE" || die '日志轮转配置不是本项目的'
  local name expected actual dropins
  for name in mtp.service mtp-refresh.service mtp-refresh.timer; do
    case "$name" in mtp.service) expected=$UNIT;; mtp-refresh.service) expected=$REFRESH;; *) expected=$TIMER;; esac
    [[ $(stat -c %u "$expected") == 0 ]] && (( (8#$(stat -c %a "$expected") & 0022) == 0 )) || die "$expected 权限不安全"
    actual=$(systemctl show -p FragmentPath --value "$name") || die "无法检查 $name"
    [[ $actual == "$expected" ]] || die "$name 实际加载了其他配置：$actual"
    dropins=$(systemctl show -p DropInPaths --value "$name") || die "无法检查 $name 的额外配置"
    [[ -z $dropins ]] || die "$name 存在额外配置，请人工核验后管理"
  done
}
no_unrelated_files() {
  local path paths special roots=()
  for path in "$APP" "$CONFIG" "$LOG"; do
    [[ ! -e $path && ! -L $path ]] || roots+=("$path")
  done
  ((${#roots[@]})) || return 0
  special=$(find "${roots[@]}" -name $'*\n*' -print) || die '无法枚举卸载目录'
  [[ -z $special ]] || die '发现包含换行的文件名，拒绝自动删除'
  paths=$(find "${roots[@]}" -print) || die '无法枚举卸载目录'
  while IFS= read -r path; do
    [[ ! -L $path ]] || die "发现符号链接 ${path}；拒绝自动删除"
    case "$path" in
      "$APP"|"$APP/bin"|"$CONFIG"|"$LOG") [[ -d $path ]] || die "${path} 目录类型已变更"; continue;;
      "$APP/.owner"|"$APP/mtp"|"$APP/bin/mtproto-proxy"|\
      "$CONFIG/.owner"|"$CONFIG/account"|"$CONFIG/manifest"|"$CONFIG/mtp.conf"|"$CONFIG/proxy-secret"|"$CONFIG/proxy-multi.conf"|\
      "$LOG/.owner"|"$LOG/mtp.log") ;;
      *) [[ $path == "$LOG/"* && ${path#"$LOG/"} =~ ^mtp\.log\.[0-9]+(\.gz)?$ ]] || die "发现非本项目文件 ${path}；拒绝自动删除";;
    esac
    [[ -f $path && $(stat -c %h "$path") == 1 ]] || die "${path} 不是独立常规文件，拒绝自动删除"
  done <<< "$paths"
}
track_created() {
  local identity
  identity=$(stat -c '%d:%i' "$1") || { tracking_failed=1; die "无法记录 ${1} 的归属，保留残留供人工核验"; }
  created_paths+=("$1")
  created_ids+=("$identity")
}
create_install_file() {
  (set -C; : > "$1") || die "$1 已存在或无法创建，拒绝覆盖"
  track_created "$1"
}
install_proxy() (
  root_only; preflight; lock
  for path in "$APP" "$CONFIG" "$LOG" "$UNIT" "$TIMER" "$REFRESH" "$ROTATE"; do
    [[ ! -e $path && ! -L $path ]] || die "$path 已存在，拒绝覆盖"
  done
  local unit_name fragment load_state dropins entry group_entry
  for unit_name in mtp.service mtp-refresh.service mtp-refresh.timer; do
    fragment=$(systemctl show -p FragmentPath --value "$unit_name") || die "无法检查 $unit_name"
    load_state=$(systemctl show -p LoadState --value "$unit_name") || die "无法检查 $unit_name 状态"
    dropins=$(systemctl show -p DropInPaths --value "$unit_name") || die "无法检查 $unit_name 的额外配置"
    [[ -z $fragment && $load_state == not-found && -z $dropins ]] || die "systemd 中已存在 $unit_name ($fragment)，拒绝覆盖"
  done
  entry=$(mtp_account_entry passwd) || die '无法核验 mtp 用户'
  group_entry=$(mtp_account_entry group) || die '无法核验 mtp 组'
  [[ -z $entry && -z $group_entry ]] || die 'mtp 用户或组已存在，拒绝复用'
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
  work=; user_created=0; group_created=0; install_complete=0
  service_attempted=0; timer_attempted=0; tracking_failed=0; created_paths=(); created_ids=()
  trap 'result=$?; trap - EXIT; if (( ! install_complete )); then cleanup_failed_install || :; fi; [[ -z $work ]] || rm -rf -- "$work"; exit "$result"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  work=$(mktemp -d /tmp/mtp-install.XXXXXX)
  fetch "https://codeload.github.com/ellermister/MTProxyC/tar.gz/$ENGINE_SHA" "$work/engine.tar.gz"
  printf '%s  %s\n' "$ENGINE_ARCHIVE_SHA256" "$work/engine.tar.gz" | sha256sum -c - >/dev/null || die '引擎源码校验失败'
  tar -tzf "$work/engine.tar.gz" | awk '($0 ~ /^\// || $0 ~ /(^|\/)\.\.(\/|$)/) {bad=1} END {exit bad}' || die '源码包路径不安全'
  mkdir "$work/src"
  tar -xzf "$work/engine.tar.gz" -C "$work/src" --strip-components=1
  [[ -f $work/src/Makefile ]] || die '引擎源码包格式不符'
  make -C "$work/src" -j2 >/dev/null
  [[ -x $work/src/objs/bin/mtproto-proxy ]] || die '编译失败'
  fetch https://core.telegram.org/getProxySecret "$work/proxy-secret"
  fetch https://core.telegram.org/getProxyConfig "$work/proxy-multi.conf"
  [[ $(wc -c < "$work/proxy-secret") -ge 64 ]] && valid_telegram_config "$work/proxy-multi.conf" || die 'Telegram 配置数据无效'
  require_free_port "$PORT"; require_free_port "$STATS_PORT"
  groupadd --system mtp
  group_created=1
  useradd --system --gid mtp --home-dir /nonexistent --shell /usr/sbin/nologin mtp
  user_created=1
  mkdir -m 0755 "$APP"
  track_created "$APP"
  printf 'mtp-owned-v1\n' > "$APP/.owner"
  mkdir -m 0755 "$APP/bin"
  mkdir -m 0750 "$CONFIG"
  track_created "$CONFIG"
  printf 'mtp-owned-v1\n' > "$CONFIG/.owner"
  mkdir -m 0750 "$LOG"
  track_created "$LOG"
  printf 'mtp-owned-v1\n' > "$LOG/.owner"
  chown root:mtp "$CONFIG" "$LOG"
  install -m 0755 "$work/src/objs/bin/mtproto-proxy" "$APP/bin/mtproto-proxy"
  install -m 0755 "$SCRIPT_PATH" "$APP/mtp"
  install -m 0640 -g mtp "$work/proxy-secret" "$CONFIG/proxy-secret"
  install -m 0644 "$work/proxy-multi.conf" "$CONFIG/proxy-multi.conf"
  SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [[ $SECRET =~ ^[0-9a-f]{32}$ ]] || die '随机 Secret 生成失败'
  (umask 027; printf 'PORT=%s\nSTATS_PORT=%s\nSECRET=%s\nDOMAIN=%s\nSERVER=%s\nTAG=%s\n' "$PORT" "$STATS_PORT" "$SECRET" "$DOMAIN" "$SERVER" "$TAG" > "$CONFIG/mtp.conf")
  chown root:mtp "$CONFIG/mtp.conf"
  (umask 077; printf '%s %s\n' "$(id -u mtp)" "$(id -g mtp)" > "$CONFIG/account")
  touch "$LOG/mtp.log"
  chown mtp:mtp "$LOG/mtp.log"
  chmod 0640 "$LOG/mtp.log"
  local capabilities=
  if (( PORT < 1024 )); then capabilities=CAP_NET_BIND_SERVICE; fi
  create_install_file "$UNIT"
  cat > "$UNIT" <<EOF
[Unit]
Description=MTProto Proxy (mtp-owned)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
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
ReadWritePaths=/var/log/mtp
UMask=0027
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=$capabilities
AmbientCapabilities=$capabilities
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
EOF
  create_install_file "$REFRESH"
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
  create_install_file "$TIMER"
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
  create_install_file "$ROTATE"
  cat > "$ROTATE" <<'EOF'
# mtp-owned-v1
/var/log/mtp/mtp.log {
    daily
    maxsize 10M
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
EOF
  chmod 0644 "$UNIT" "$TIMER" "$REFRESH" "$ROTATE"
  (umask 077; manifest_content > "$CONFIG/manifest")
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$UNIT" "$REFRESH" "$TIMER" || die 'systemd 配置检查失败'
  fi
  systemctl daemon-reload
  service_attempted=1
  systemctl enable --now mtp.service
  wait_running || die '服务启动失败或未由本服务监听指定端口，请查日志'
  timer_attempted=1
  systemctl enable --now mtp-refresh.timer
  install_complete=1
  say "运行中，TCP ${PORT}，Secret：$SECRET"
  show_link
  say '管理：sudo /opt/mtp/mtp status|self-test|start|stop|restart|link|uninstall'
  say "请手动在云安全组及既有防火墙中允许 TCP ${PORT}；本程序未改动防火墙"
)
cleanup_failed_install() {
  [[ ${group_created:-0} == 1 ]] || return 0
  (( ! tracking_failed )) || { say '无法确认资源身份，保留安装残留'; return 1; }
  local i dir existing=()
  say '安装失败，清理本次创建的资源'
  # 文件可能只写了一部分，使用本次创建时记录的 inode，不凭名称/内容认领。
  for ((i=0; i<${#created_paths[@]}; i++)); do
    dir=${created_paths[i]}
    [[ ! -e $dir && ! -L $dir ]] && continue
    if [[ -L $dir || $(stat -c '%d:%i' "$dir") != "${created_ids[i]}" ]]; then
      say "${dir} 已被替换；保留安装残留，请人工核验"; return 1
    fi
  done
  for dir in "$APP" "$CONFIG" "$LOG"; do
    [[ ! -d $dir ]] || existing+=("$dir")
  done
  if ((${#existing[@]})); then
    # 临时/部分安装也不能吞掉外部新增数据。
    if ! (no_mounts && no_unrelated_files); then say '发现异常文件或挂载；保留安装残留，请人工核验'; return 1; fi
  fi
  if [[ -e $CONFIG/account || -L $CONFIG/account ]] && ! (account_check); then say '账号归属检查失败；保留安装残留'; return 1; fi
  if (( service_attempted || timer_attempted )) && ! (owner_check); then say '服务归属检查失败；保留安装残留'; return 1; fi
  if (( timer_attempted )); then
    systemctl disable --now mtp-refresh.timer || return 1
    systemctl stop mtp-refresh.service || return 1
  fi
  if (( service_attempted )); then systemctl disable --now mtp.service || return 1; fi
  if (( user_created )); then userdel mtp || { say '账号清理失败；保留安装文件'; return 1; }; fi
  groupdel mtp || { say '组清理失败；保留安装文件'; return 1; }
  for ((i=${#created_paths[@]}-1; i>=0; i--)); do
    rm -rf -- "${created_paths[i]}" || return 1
  done
  systemctl daemon-reload || { say '文件已清理，但 systemd 重新加载失败，请人工核验'; return 1; }
}
run_proxy() {
  load_config
  local -a args=(-p "$STATS_PORT" -H "$PORT" -S "$SECRET" --aes-pwd "$CONFIG/proxy-secret" "$CONFIG/proxy-multi.conf" --domain "$DOMAIN")
  [[ -z $TAG ]] || args+=(-P "$TAG")
  exec "$APP/bin/mtproto-proxy" "${args[@]}"
}
wait_running() {
  local attempt pid lines
  for ((attempt=0; attempt<20; attempt++)); do
    if systemctl is-active --quiet mtp.service; then
      pid=$(systemctl show -p MainPID --value mtp.service) || pid=
      lines=$(port_lines "$PORT") || lines=
      [[ $pid =~ ^[1-9][0-9]*$ && $lines == *"pid=$pid,"* ]] && return 0
    fi
    sleep 1
  done
  return 1
}
private_stats_listener() {
  [[ $2 =~ ^[1-9][0-9]*$ && -n $1 ]] || return 1
  printf '%s\n' "$1" | awk -v pid="$2" -v port="$STATS_PORT" '
    { if (!index($0,"pid=" pid ",")) bad=1
      if ($4 !~ ("^127[.][0-9]+[.][0-9]+[.][0-9]+:" port "$") && $4 != "[::1]:" port && $4 != "::1:" port) bad=1
      found=1
    } END { exit (bad || !found) }'
}
status_proxy() {
  load_config
  systemctl --no-pager --full status mtp.service || :
  printf '客户端 TCP %s；统计 TCP %s；PID %s\n' "$PORT" "$STATS_PORT" "$(systemctl show -p MainPID --value mtp.service)"
  ss -H -ltnp "( sport = :$PORT )" || :
  if [[ -f $LOG/mtp.log && ! -L $LOG/mtp.log ]]; then tail -n 20 "$LOG/mtp.log" || :;
  else say '日志不存在或为符号链接'; fi
  systemctl is-active --quiet mtp.service
}
finish_refresh() {
  # TERM/INT 可能落在 mv 成功与赋值之间：临时文件已消失也意味着完成替换。
  if (( backup_ready && ! completed )) && { (( replaced )) || { (( replacing )) && [[ ! -e $temp ]]; }; }; then
    if mv -f -- "$backup" "$CONFIG/proxy-multi.conf"; then
      if ! systemctl restart mtp.service || ! wait_running; then say '旧配置已恢复，但服务仍未正常监听，请查看日志'; fi
    else
      say "旧配置恢复失败，保留备份 ${backup}；请人工处理"
      backup=
    fi
  fi
  [[ -z $temp ]] || rm -f -- "$temp"
  [[ -z $backup ]] || rm -f -- "$backup"
}
refresh_proxy() (
  root_only; lock; owner_check
  # 定时刷新尊重用户主动停止，不能把停止状态当作故障。
  if ! systemctl is-active --quiet mtp.service; then say '服务未运行，跳过刷新'; exit 0; fi
  load_config; runtime_permissions
  temp=; backup=; replaced=0; replacing=0; backup_ready=0; completed=0
  trap 'result=$?; trap - EXIT; finish_refresh || :; exit "$result"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  temp=$(mktemp "$CONFIG/.new.XXXXXX")
  backup=$(mktemp "$CONFIG/.old.XXXXXX")
  fetch https://core.telegram.org/getProxyConfig "$temp"
  valid_telegram_config "$temp" || die '新配置无效，保留旧配置'
  if cmp -s -- "$temp" "$CONFIG/proxy-multi.conf"; then say 'Telegram 配置未变化，无需重启'; exit 0; fi
  if ! systemctl is-active --quiet mtp.service; then say '下载期间服务已停止，保留旧配置'; exit 0; fi
  cp -p -- "$CONFIG/proxy-multi.conf" "$backup"
  backup_ready=1
  chmod 0644 "$temp"
  replacing=1
  mv -f -- "$temp" "$CONFIG/proxy-multi.conf"
  replaced=1
  systemctl restart mtp.service || die '新配置启动失败，将恢复旧配置'
  wait_running || die '新配置未正常监听，将恢复旧配置'
  completed=1
  say 'Telegram 配置已更新'
)
self_test() (
  local failed=0
  if (load_config); then say '配置及 Secret 格式：正常'; else say '配置及 Secret 格式：失败'; failed=1; fi
  if (owner_check && account_check && runtime_permissions && no_unrelated_files); then say '归属与文件权限：正常'; else say '归属与文件权限：失败'; failed=1; fi
  if systemctl is-enabled --quiet mtp.service && systemctl is-active --quiet mtp.service; then
    say "systemd：自启且运行；PID $(systemctl show -p MainPID --value mtp.service)"
  else say 'systemd：未自启或未运行'; failed=1; fi
  if systemctl is-enabled --quiet mtp-refresh.timer && systemctl is-active --quiet mtp-refresh.timer; then say '刷新定时器：自启且运行';
  else say '刷新定时器：未自启或未运行'; failed=1; fi
  if (load_config); then
    load_config
    local pid lines
    pid=$(systemctl show -p MainPID --value mtp.service)
    lines=$(port_lines "$PORT") || lines=
    if [[ $pid =~ ^[1-9][0-9]*$ && $lines == *"pid=$pid,"* ]]; then say "客户端 TCP ${PORT}：本服务监听";
    else say "客户端 TCP ${PORT}：缺少本服务监听"; failed=1; fi
    lines=$(port_lines "$STATS_PORT") || lines=
    if private_stats_listener "$lines" "$pid"; then say '统计端口：本机监听';
    else say '统计端口：缺少监听或存在公网绑定，请核验'; failed=1; fi
  fi
  if [[ -f $LOG/mtp.log && ! -L $LOG/mtp.log ]] && command -v logrotate >/dev/null && logrotate -d "$ROTATE" >/dev/null 2>&1; then
    say "日志与轮转：可读 $(wc -c < "$LOG/mtp.log") 字节；请检查系统 logrotate 调度"
  else say '日志或轮转配置：异常'; failed=1; fi
  say '本机检查不能证明云安全组、防火墙及 Telegram 外部连通性'
  exit "$failed"
)
uninstall_proxy() {
  root_only; lock; owner_check; account_check; no_unrelated_files
  local old_port
  old_port=$(read_value PORT || :)
  printf '将停止并删除 mtp.service、mtp-refresh.service、mtp-refresh.timer，删除 mtp 用户/组及下列路径：\n'
  printf '%s\n' "$APP" "$CONFIG" "$LOG" "$UNIT" "$REFRESH" "$TIMER" "$ROTATE"
  say '不触碰其他服务、旧版 /home/mtproxy 安装或防火墙'
  local answer
  read -r -p '输入 YES 确认删除：' answer
  [[ $answer == YES ]] || die '已取消'
  # 等待确认期间可能有人新增数据/修改服务；在任何破坏性动作前重新核验。
  owner_check; account_check; no_unrelated_files
  systemctl disable --now mtp-refresh.timer mtp.service
  systemctl stop mtp-refresh.service
  owner_check; account_check; no_unrelated_files
  # 先删除账号：失败时保留文件和归属记录，便于核验后重试。
  local entry group_entry
  entry=$(mtp_account_entry passwd) || die '无法核验 mtp 用户，保留安装文件'
  group_entry=$(mtp_account_entry group) || die '无法核验 mtp 组，保留安装文件'
  if [[ -n $entry ]]; then userdel mtp; fi
  if [[ -n $group_entry ]]; then groupdel mtp; fi
  rm -f -- "$UNIT" "$TIMER" "$REFRESH" "$ROTATE"
  rm -rf -- "$APP" "$CONFIG" "$LOG"
  [[ ! -e $UNIT && ! -e $TIMER && ! -e $REFRESH && ! -e $ROTATE && ! -e $APP && ! -e $CONFIG && ! -e $LOG ]] || die '文件清理不完整'
  systemctl daemon-reload || die '文件与账号已清理，但 systemd 重新加载失败；请人工执行 systemctl daemon-reload 并核验'
  [[ $(systemctl show -p LoadState --value mtp.service) == not-found ]] || die '服务仍存在'
  local remaining
  if ! valid_port "$old_port"; then
    say '卸载完成；原配置端口无效，未验证端口释放'
  else
    remaining=$(port_lines "$old_port") || die '文件与账号已清理，但无法检查原端口监听状态'
    if [[ -n $remaining ]]; then
      say "卸载完成，但 TCP ${old_port} 仍有监听；请用 ss -ltnp 查看是否被其他服务使用"
    else say '卸载完成；原客户端端口当前未监听'; fi
  fi
}
main() {
  local action=${1:-}
  [[ $# -gt 0 ]] && shift || :
  [[ $action == install || $# -eq 0 ]] || die "管理命令 $action 不接受参数"
  case "$action" in
    install) install_proxy "$@";;
    run) run_proxy;;
    status) root_only; status_proxy;;
    self-test) root_only; self_test;;
    link) root_only; load_config; show_link;;
    refresh) refresh_proxy;;
    start|stop|restart)
      root_only; lock; owner_check; load_config
      [[ $action == stop ]] || runtime_permissions
      systemctl "$action" mtp.service
      [[ $action == stop ]] || wait_running || die '服务未正常运行，请查看 status 与 self-test';;
    uninstall) uninstall_proxy;;
    *) usage >&2; return 2;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
