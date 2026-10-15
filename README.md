# MTProto Proxy VPS 部署

本项目为个人 VPS 部署 MTProto Proxy 提供一个受控的安装脚本。客户端使用 Fake TLS（`ee` Secret），代理引擎使用 [ellermister/MTProxyC](https://github.com/ellermister/MTProxyC) 的固定提交 `93b3530c3543b278c65a21c8bb4843ae7e5662ba`；不修改代理协议代码。脚本在 VPS 本地编译引擎，校验下载的源码归档，再以独立的 `mtp` 用户交给 systemd 长期运行。

> 这是新的独立安装布局。若 VPS 上已有旧版 `/home/mtproxy` 安装，请先查看旧服务并手动迁移。新脚本不会接管、停止或删除旧版，也不会复用旧 Secret。

## 系统要求

- x86_64 Linux VPS，systemd 为 PID 1；审查目标为 Ubuntu 22.04、Ubuntu 24.04、Debian 12；脚本使用这些系统的 Bash/GNU 工具和 systemd 接口，目前未完成各发行版的实际 VPS 验收，不承诺其他发行版兼容。
- root/sudo；能够访问 GitHub 源码归档、`core.telegram.org` 和公网 IP 查询服务。安装前检查 `systemctl`、`ss`、`curl`、`tar`、`make`、`cc`、`od`、`sha256sum`、`flock`、GNU `stat`、`logrotate`、用户管理命令。
- C 构建依赖：OpenSSL、zlib、zstd 的开发头文件和链接库。Debian/Ubuntu 可预先执行 `sudo apt update && sudo apt install -y build-essential libssl-dev zlib1g-dev libzstd-dev curl iproute2 util-linux logrotate`。安装器不会自行升级或安装系统软件。
- VPS 对 Telegram 的出站连接、客户端端口的入站 TCP 放行。当前安装器只支持 IPv4 地址或常规域名作为分享链接地址。

## 快速开始

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

安装器生成 `/etc/mtp/mtp.conf`，它是数据文件，不能写 Shell 表达式。必须恰好保留 `PORT`、`STATS_PORT`、`SECRET`、`DOMAIN`、`SERVER`、`TAG` 六个字段；只有 `TAG=` 允许为空。不接受重复字段、空行、未知字段、控制字符或大于 4096 字节的配置。Secret 必须是 32 位小写十六进制。修改时保留 root:mtp 0640 权限，先执行 `self-test` 检查；正常配置的最后一行可以没有换行。

安装前使用 `ss` 检查客户端和统计端口；若 Docker 正在运行，还检查容器发布的宿主机 TCP 端口（包含端口范围，UDP 映射不会误报为 TCP 冲突）；不要求安装 Docker。若占用，显示监听信息、程序和 PID（能否看到完整进程名取决于权限），或显示占用的容器，然后退出。脚本不会关闭占用进程，不会接管 Nginx、Caddy、Apache 或面板。安装到 `/opt/mtp`、`/etc/mtp`、`/var/log/mtp`，创建 `mtp.service`、每天更新 Telegram 配置的 `mtp-refresh.timer` 及 `/etc/logrotate.d/mtp` 日志轮转配置。如这些路径、服务名或 `mtp` 用户/组已存在，安装会拒绝覆盖。

systemd 配置或账号查询失败时也会拒绝继续，不能把查询失败当作资源不存在。账号查询仅将 GNU `getent` 的返回码 2 视为指定账号不存在；其他错误或成功但记录为空均报错。卸载末尾再次查询失败时会保留安装文件，此时服务可能已停止，请先修复查询故障再重试。

### 防火墙

请在云厂商安全组与 VPS 现有防火墙中**自行**放行所选客户端 TCP 端口，例如 8443/tcp。安装器不会更改 UFW、firewalld、iptables、nftables 或云安全组，因此卸载也不会删除任何防火墙规则。不要开放统计端口 8888/tcp。仅 `systemctl active` 和本机监听不能证明互联网可达。

这是一项刻意保留的人工步骤：无法可靠识别所有 VPS 的防火墙管理方式及云安全组归属，自动插入/删除规则可能误改现有配置。端口参数和链接会自动同步；防火墙规则需要按当前 VPS 的实际方案配置和验收。

## 端口方案

[Telegram 官方 MTProxy 文档](https://github.com/TelegramMessenger/MTProxy#running) 使用 `-H 443` 作为客户端端口示例，同时[链接格式](https://github.com/TelegramMessenger/MTProxy#running)明确包含 `port=PORT`。因此 443 **不是协议强制端口**，Telegram 客户端可以使用链接指定的其他 TCP 端口。443 可能更容易通过某些网络限制，但常与 HTTPS 网站、反代或面板冲突；8443 更适合已有 Web 服务的 VPS。非 443 端口可能被用户网络或云防火墙屏蔽，需要实际从外部网络验证。脚本会用选定端口生成 `tg://proxy` 和 `https://t.me/proxy` 链接。

## 服务管理与健康检查

```bash
sudo /opt/mtp/mtp status       # systemd 状态、主 PID、端口监听、最近日志
sudo /opt/mtp/mtp self-test    # 只读检查配置、权限、归属、服务、端口及日志
sudo /opt/mtp/mtp start
sudo /opt/mtp/mtp stop
sudo /opt/mtp/mtp restart
sudo /opt/mtp/mtp link         # 再次显示连接链接和 Secret
sudo /opt/mtp/mtp refresh      # 手动刷新 Telegram 配置并重启
systemctl status mtp-refresh.timer
journalctl -u mtp.service -n 50 --no-pager
```

systemd 配置为开机自启和异常退出 5 秒后重启，关闭启动次数限制以允许持续恢复；依赖 `network-online.target`，但其具体等待行为仍取决于 VPS 的网络管理器。服务只对专属日志目录获得写权限，其余系统路径保持只读。启动和重启最多等待 20 秒，并核对监听进程是否属于 systemd 主 PID；超时会返回错误，需要查看日志，不会杀死占用端口的程序。每日定时下载 `getProxyConfig`，新配置经过文本大小、控制字符及 `proxy_for` 指令格式检查后，在同一目录原子替换；相同内容不重启。下载或校验失败保留旧配置，更新导致服务无法启动时尝试恢复旧配置并核对监听；恢复失败保留备份并提示人工处理。定时刷新不会启动主动停止的服务，下载结束后也会再次检查停止状态。这个检查不能替代引擎完整解析及 Telegram 连接验收，有效更新仍需重启，现有连接可能中断。

管理操作通过同一把锁串行执行。`/run/mtp-install.lock` 保留文件是正常行为；进程退出时内核释放锁，不要通过删除锁文件解除锁定，否则可能使并发进程锁住不同文件。日志保存在 `/var/log/mtp/mtp.log`，安装要求已有 logrotate；配置每天或超过 10 MiB 时轮转、保留 4 期，由 root 执行轮转。`maxsize` 仅在 logrotate 被调度时生效，并非实时硬上限；须确认系统的 logrotate timer/cron 正常运行，并监控磁盘空间。持续启动失败会无限重试，需监控日志和磁盘。服务默认一个工作进程；实际 CPU、内存及流量取决于并发用户和上游连通性。

`self-test` 正常返回 0，发现异常返回非 0，不输出 Secret；检查主服务和刷新 timer 的活动/自启状态，以及统计端口的每条监听是否来自本服务且仅绑定 IPv4/IPv6 回环地址。主动停止的服务也会报告未运行。`status` 在服务未运行时返回非 0。自检只检查本机，不证明 Telegram 握手成功或外部网络可达。

`/etc/mtp/mtp.conf` 仅 root 和 `mtp` 组可读；引擎要求把 Secret 作为命令行参数传入，因此同机其他有进程查看权限的本地用户可能通过进程列表看到 Secret。适合只有可信账号的个人 VPS；不要在多租户主机上把它当作完全隔离的凭据。

## 一键卸载

```bash
sudo /opt/mtp/mtp uninstall
```

卸载前会列出目录、unit、轮转文件及用户/组，只有输入大写 `YES` 才执行。安装记录创建的 UID/GID，并将目录身份及静态文件摘要保存到 root:root 0600 的 `/etc/mtp/manifest`。卸载检查账号身份、其他成员、符号链接、硬链接、挂载点、文件类型、未知文件及 systemd 实际加载路径；确认后和停止服务后再次检查。如目录被替换、静态 unit/程序/轮转文件被修改、组被共用或存在额外 unit 配置，拒绝自动删除。可编辑的 `mtp.conf`、Telegram 数据及日志不纳入静态摘要，但仍检查权限和文件布局。账号删除失败时保留安装文件，便于核验后重试。

卸载会停止并禁用本项目的服务和定时器，删除 `/opt/mtp`、`/etc/mtp`、`/var/log/mtp` 、对应 systemd unit 和日志轮转配置，并删除专用 `mtp` 用户/组。卸载不触碰旧安装、其他服务和防火墙。文件清理后如 `daemon-reload` 失败会明确报错，需人工重新加载并检查缓存 unit 状态。完成后可用 `systemctl status mtp.service`、`ss -ltnp` 和目录存在性复查。卸载删除 Secret，重装会生成新 Secret，旧 Telegram 链接失效。

旧版本安装可能没有 `/etc/mtp/account` 或 `/etc/mtp/manifest`，不能仅凭用户名和内容标记证明完整归属。不要将新版管理脚本直接覆盖到旧安装，也不要手写归属记录绕过保护；新版管理操作和自检会对此报错。现有安装不会因修改本地仓库而自动升级，可继续使用其原有管理脚本，迁移前应人工核验用户、目录与服务配置。专属路径内部不支持额外挂载点；整个 `/var/log` 等父目录独立挂载不受此限制。

## VPS 共存说明

不会修改 Nginx、Apache、Caddy、Docker 或宝塔的配置，不执行按端口杀进程的操作，不修改防火墙或系统网络设置。443 被其他服务使用时可选择 8443 或其他空闲端口。已有 MTProxy、同名目录/账号或 systemd 服务不会被接管。Docker 检测只针对当前默认 Docker daemon 可见的容器，远程 daemon、其他 rootless 实例或手工 NAT 规则仍需要人工核验。

不要将个人文件放进本项目专属目录，也不要复用 `mtp` 账号运行其他服务。卸载只接受本项目的文件布局，发现额外数据会拒绝删除。安装/刷新失败和可捕获的退出信号会清理临时文件；`SIGKILL`、断电等无法执行 trap 的情况可能留下残留，必须核验归属后人工处理。

## 安全说明

Secret 和带 Secret 的 Telegram 链接等同密码，不要公开分享，不要提交到 GitHub。推荐在只有可信账号的单用户个人 VPS 使用。配置不作为 Shell 代码执行，Secret 由系统随机源生成；文件权限无法阻止其他有进程查看权限的本地用户读取引擎命令行中的 Secret。`self-test` 不打印凭据，`link` 和安装完成输出会显示凭据。

## 常见错误排查

- **端口被占用**：先运行 `sudo ss -ltnp '( sport = :8443 )'` 查看进程；选择空闲端口，或由你自行调整已有服务。443 被 Web 服务占用时建议用 8443。
- **安装失败**：检查命令缺失、构建依赖、GitHub/Telegram 网络、发行版和架构；如出现部分安装，检查 `/opt/mtp`、`/etc/mtp`、`/var/log/mtp` 和 systemd 状态后处理。
- **服务异常退出**：执行 `sudo /opt/mtp/mtp status`，再看 `journalctl -u mtp.service -n 100 --no-pager` 和 `/var/log/mtp/mtp.log`。确认配置及端口没有被其他服务抢占。

Telegram 无法连接时按顺序检查：

1. **服务**：运行 `sudo /opt/mtp/mtp status` 和 `sudo /opt/mtp/mtp self-test`。
2. **端口**：运行 `sudo ss -ltnp '( sport = :8443 )'`，核对端口及 PID；从另一个网络检测客户端 TCP 端口。
3. **云安全组**：放行实际客户端 TCP 端口，不开放统计端口。
4. **防火墙**：检查已有 UFW/nftables/iptables 规则，确认入站端口未被阻断。
5. **Telegram 连通性**：核对链接里的公网地址、端口、Secret；确认 VPS 能访问 Telegram 的配置服务和代理上游，Fake TLS 域名可用。下载配置成功和 TCP 建连成功都不能替代 Telegram 客户端的实际连接验收。

- **重启后不可用**：检查 `systemctl is-enabled mtp.service`、`systemctl status mtp.service`，再检查端口与日志。公网 IP 变化时更新 `/etc/mtp/mtp.conf` 中 `SERVER=`，执行 `sudo /opt/mtp/mtp link` 重新分享链接。

## 自动化检查

```bash
bash -n MTP一键部署.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
# 仅在已有 ShellCheck 的环境执行；不会自动安装工具
shellcheck -S warning MTP一键部署.sh
```

测试覆盖参数错误、超长端口、Nginx/Caddy/宝塔/既有代理冲突、Docker TCP 映射及范围、已有目录/unit、失败清理、刷新回滚、卸载确认与账号归属、配置不执行、权限检查及自检输出。系统命令在模拟测试中被替换，所有文件操作使用临时目录，不下载引擎、不操作本机服务。缺少 ShellCheck 时对应测试明确标记为 skipped，不表示 lint 通过。

本次生产审查与验证记录见 [审查报告](docs/production-review.md)。
第二轮失败路径、配置边界及安全审查见 [深度审查报告](docs/deep-security-review.md)。

## 审查边界

原版仅有 `MTP一键部署.sh` 和 README；旧脚本会下载并执行未锁定的第三方安装器，而第三方安装器启动时可能按端口 `kill -9` 现有进程。本版本不运行那个安装器。当前本地开发环境为 macOS，不能证明 Linux 安装、VPS 共存、重启和外部 Telegram 连通性；请依照 [VPS 验收清单](docs/vps-acceptance.md) 在可丢弃测试 VPS 上验证，再用于长期运行。
