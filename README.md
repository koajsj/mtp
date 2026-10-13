# MTProto Proxy VPS 部署

本项目为个人 VPS 部署 MTProto Proxy 提供一个受控的安装脚本。客户端使用 Fake TLS（`ee` Secret），代理引擎使用 [ellermister/MTProxyC](https://github.com/ellermister/MTProxyC) 的固定提交 `93b3530c3543b278c65a21c8bb4843ae7e5662ba`；不修改代理协议代码。脚本在 VPS 本地编译引擎，校验下载的源码归档，再以独立的 `mtp` 用户交给 systemd 长期运行。

> 这是新的独立安装布局。若 VPS 上已有旧版 `/home/mtproxy` 安装，请先查看旧服务并手动迁移。新脚本不会接管、停止或删除旧版，也不会复用旧 Secret。

## 系统要求

- x86_64 Linux VPS，systemd 为 PID 1；Debian/Ubuntu、RHEL 等可用，但目前未完成各发行版的实际 VPS 验收。
- root/sudo；能够访问 GitHub 源码归档、`core.telegram.org` 和公网 IP 查询服务。安装前检查 `systemctl`、`ss`、`curl`、`tar`、`make`、`cc`、`od`、`sha256sum`、`flock`、用户管理命令。
- C 构建依赖：OpenSSL、zlib、zstd 的开发头文件和链接库。Debian/Ubuntu 可预先执行 `sudo apt update && sudo apt install -y build-essential libssl-dev zlib1g-dev libzstd-dev curl iproute2 util-linux`。安装器不会自行升级或安装系统软件。
- VPS 对 Telegram 的出站连接、客户端端口的入站 TCP 放行。当前安装器只支持 IPv4 地址或常规域名作为分享链接地址。

## 安装

先下载并审阅脚本，再执行：

```bash
curl -fsSLo mtp-install.sh https://raw.githubusercontent.com/koajsj/mtp/main/MTP%E4%B8%80%E9%94%AE%E9%83%A8%E7%BD%B2.sh
less mtp-install.sh
sudo bash mtp-install.sh install --port 8443
```

已审阅并信任脚本时，可使用一条命令安装：

```bash
curl -fsSLo mtp-install.sh https://raw.githubusercontent.com/koajsj/mtp/main/MTP%E4%B8%80%E9%94%AE%E9%83%A8%E7%BD%B2.sh && sudo bash mtp-install.sh install --port 8443
```

必须保存为文件后执行，不能直接 `curl | bash`：安装器需要把自身复制为管理命令。安装完成后会输出服务状态、使用端口、Secret、Telegram 链接和管理命令。链接与 Secret 等同于访问凭据，不要公开发布。

本地源码也可复制到 VPS，再执行 `sudo bash ./MTP一键部署.sh install --port 8443`。

可选参数：

```bash
sudo bash ./MTP一键部署.sh install --port 9443 --stats-port 8889 \
  --server proxy.example.com --domain www.cloudflare.com
```

- `--port`：客户端 TCP 端口，默认 8443。可选 443 或其他 1–65535 端口；低于 1024 时，服务仅获得绑定低端口的 `CAP_NET_BIND_SERVICE` 能力。
- `--stats-port`：本地统计 TCP 端口，默认 8888，要求为 1024–65535，不能与客户端端口相同。安装前也会检查冲突。统计端口不应对公网开放。
- `--server`：链接中的公网 IPv4 或域名；省略时通过 HTTPS 查询公网 IPv4。NAT 或多地址 VPS 建议显式填写。
- `--domain`：Fake TLS 伪装域名，默认为 `www.cloudflare.com`；须是有效、可访问的域名。更改后旧链接不再适用。
- `--tag`：可选的 32 位十六进制推广 Tag，由 Telegram 的 @MTProxybot 提供。
- 兼容旧入口环境变量 `MT_PROXY_DEFAULT_PORT`，命令行 `--port` 优先。

安装前使用 `ss` 检查客户端和统计端口；若 Docker 正在运行，还检查容器发布的宿主机端口。若占用，显示监听信息、程序和 PID（能否看到完整进程名取决于权限），或显示占用的容器，然后退出。脚本不会关闭占用进程，不会接管 Nginx、Caddy、Apache 或面板。安装到 `/opt/mtp`、`/etc/mtp`、`/var/log/mtp`，创建 `mtp.service`、每天更新 Telegram 配置的 `mtp-refresh.timer` 及 `/etc/logrotate.d/mtp` 日志轮转配置。如这些路径、服务名或 `mtp` 用户/组已存在，安装会拒绝覆盖。

### 防火墙

请在云厂商安全组与 VPS 现有防火墙中**自行**放行所选客户端 TCP 端口，例如 8443/tcp。安装器不会更改 UFW、firewalld、iptables、nftables 或云安全组，因此卸载也不会删除任何防火墙规则。不要开放统计端口 8888/tcp。仅 `systemctl active` 和本机监听不能证明互联网可达。

这是一项刻意保留的人工步骤：无法可靠识别所有 VPS 的防火墙管理方式及云安全组归属，自动插入/删除规则可能误改现有配置。端口参数和链接会自动同步；防火墙规则需要按当前 VPS 的实际方案配置和验收。

## 端口方案

[Telegram 官方 MTProxy 文档](https://github.com/TelegramMessenger/MTProxy#running) 使用 `-H 443` 作为客户端端口示例，同时[链接格式](https://github.com/TelegramMessenger/MTProxy#running)明确包含 `port=PORT`。因此 443 **不是协议强制端口**，Telegram 客户端可以使用链接指定的其他 TCP 端口。443 可能更容易通过某些网络限制，但常与 HTTPS 网站、反代或面板冲突；8443 更适合已有 Web 服务的 VPS。非 443 端口可能被用户网络或云防火墙屏蔽，需要实际从外部网络验证。脚本会用选定端口生成 `tg://proxy` 和 `https://t.me/proxy` 链接。

## 服务管理与健康检查

```bash
sudo /opt/mtp/mtp status       # systemd 状态、主 PID、端口监听、最近日志
sudo /opt/mtp/mtp start
sudo /opt/mtp/mtp stop
sudo /opt/mtp/mtp restart
sudo /opt/mtp/mtp link         # 再次显示连接链接和 Secret
sudo /opt/mtp/mtp refresh      # 手动刷新 Telegram 配置并重启
systemctl status mtp-refresh.timer
journalctl -u mtp.service -n 50 --no-pager
```

systemd 配置为开机自启和异常退出 5 秒后重启。每日定时下载 `getProxyConfig`，新配置验证后替换；更新导致服务无法启动时尝试恢复旧配置。日志保存在 `/var/log/mtp/mtp.log`，若系统安装并启用 logrotate，则每周轮转并保留 4 期；仍应检查 VPS 磁盘使用情况。服务默认一个工作进程；实际 CPU、内存及流量取决于并发用户和上游连通性。

`/etc/mtp/mtp.conf` 仅 root 和 `mtp` 组可读；引擎要求把 Secret 作为命令行参数传入，因此同机其他有进程查看权限的本地用户可能通过进程列表看到 Secret。适合只有可信账号的个人 VPS；不要在多租户主机上把它当作完全隔离的凭据。

## 一键卸载

```bash
sudo /opt/mtp/mtp uninstall
```

卸载前会列出删除范围，只有输入大写 `YES` 才执行。卸载会停止并禁用本项目的服务和定时器，删除 `/opt/mtp`、`/etc/mtp`、`/var/log/mtp` 、对应 systemd unit 和日志轮转配置，并删除专用 `mtp` 用户/组。卸载不触碰旧安装、其他服务和防火墙。完成后可用 `systemctl status mtp.service`、`ss -ltnp` 和目录存在性复查。卸载删除 Secret，重装会生成新 Secret，旧 Telegram 链接失效。

## 常见问题

- **端口被占用**：先运行 `sudo ss -ltnp '( sport = :8443 )'` 查看进程；选择空闲端口，或由你自行调整已有服务。443 被 Web 服务占用时建议用 8443。
- **安装失败**：检查命令缺失、构建依赖、GitHub/Telegram 网络、发行版和架构；如出现部分安装，检查 `/opt/mtp`、`/etc/mtp`、`/var/log/mtp` 和 systemd 状态后处理。
- **服务异常退出**：执行 `sudo /opt/mtp/mtp status`，再看 `journalctl -u mtp.service -n 100 --no-pager` 和 `/var/log/mtp/mtp.log`。确认配置及端口没有被其他服务抢占。
- **Telegram 无法连接**：确认分享链接里的域名/IP、端口和 Secret；在**另一个网络**检测 TCP 端口；检查云安全组、本机防火墙和服务器到 Telegram 的出站网络。Fake TLS 域名也应可用。
- **重启后不可用**：检查 `systemctl is-enabled mtp.service`、`systemctl status mtp.service`，再检查端口与日志。公网 IP 变化时更新 `/etc/mtp/mtp.conf` 中 `SERVER=`，执行 `sudo /opt/mtp/mtp link` 重新分享链接。

## 审查边界

原版仅有 `MTP一键部署.sh` 和 README；旧脚本会下载并执行未锁定的第三方安装器，而第三方安装器启动时可能按端口 `kill -9` 现有进程。本版本不运行那个安装器。当前本地开发环境为 macOS，不能证明 Linux 安装、VPS 共存、重启和外部 Telegram 连通性；请依照 [VPS 验收清单](docs/vps-acceptance.md) 在可丢弃测试 VPS 上验证，再用于长期运行。
