# VPS 验收清单

在可丢弃的 x86_64 Linux/systemd VPS 执行，记录发行版、systemd 版本和命令输出。开始前备份已有服务配置与端口列表；不要在生产机做破坏性测试。

1. 新 VPS：检查安装依赖和网络。安装默认 8443；检查 `systemctl is-active mtp.service`、`systemctl is-enabled mtp.service`、`ss -ltnp`、`mtp status`、外部网络的 Telegram 连接。
2. 共存：先运行 Nginx 监听 443，记录 PID 与 HTTP 响应；安装默认 8443；再确认 Nginx PID、443 响应与其配置未变化。
3. 冲突：已有服务占用 443 时执行 `install --port 443`，应报占用程序/PID并退出；比较已有服务 PID 与响应。
4. 自定义：卸载后在空闲 9443 上安装，验证链接含 `port=9443`、服务监听与外部连接。
5. 443：卸载后确认 443 空闲，再安装 `--port 443`；验证服务用户为 `mtp`、仅绑定端口能力、外部连接。
6. 恢复：强制结束仅本项目的主 PID，观察 systemd 自动重启；重启 VPS，确认服务和定时器 enabled 且 active。
7. 卸载：先输入非 `YES` 确认不会删除；再输入 `YES`，检查 systemd unit、`mtp` 用户/组、专属路径及端口释放；确认 Nginx 和其他服务仍正常。
8. 重装：在同一空闲端口重新安装，确认新的 Secret 和新链接生效。

当前开发机没有 Linux/systemd、Docker 或可访问的测试 VPS，因此上述项目是人工验收步骤，不应当视为已通过的测试。
