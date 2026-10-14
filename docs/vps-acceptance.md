# VPS 验收清单

在可丢弃的 x86_64 Linux/systemd VPS 执行，记录发行版、systemd 版本和命令输出。开始前备份已有服务配置与端口列表；不要在生产机做破坏性测试。

先分别在 Ubuntu 22.04、Ubuntu 24.04、Debian 12 的 x86_64 测试机执行下列流程，不能用一次测试代替三个发行版。

1. 新 VPS：检查安装依赖和网络。安装默认 8443；检查 `systemctl is-active mtp.service`、`systemctl is-enabled mtp.service`、`ss -ltnp`、`/opt/mtp/mtp status`、`/opt/mtp/mtp self-test`、外部网络的 Telegram 连接。
2. 共存：先运行 Nginx 监听 443，记录 PID 与 HTTP 响应；安装默认 8443；再确认 Nginx PID、443 响应与其配置未变化。
3. 冲突：已有服务占用 443 时执行 `install --port 443`，应报占用程序/PID并退出；比较已有服务 PID 与响应。
4. 自定义：卸载后在空闲 9443 上安装，验证链接含 `port=9443`、服务监听与外部连接。
5. 443：卸载后确认 443 空闲，再安装 `--port 443`；验证服务用户为 `mtp`、仅绑定端口能力、外部连接。
6. 恢复：强制结束仅本项目的主 PID，观察 systemd 自动重启；重启 VPS，确认服务和定时器 enabled 且 active。
7. 卸载：先输入非 `YES` 确认不会删除；再输入 `YES`，检查 systemd unit、`mtp` 用户/组、专属路径及端口释放；确认 Nginx 和其他服务仍正常。
8. 刷新与日志：主动停止 mtp，再执行 refresh，确认没有重新启动；运行时模拟仅 Telegram 配置下载失败，确认旧配置与服务保留；测试无效新配置启动失败时回滚；执行 `sudo logrotate -d /etc/logrotate.d/mtp`，确认系统轮转调度与磁盘监控正常。
9. 账号与路径：确认 `/etc/mtp/account` 为 root:root 0600；更换测试账号身份、加入组成员、添加无关文件或 unit drop-in 后，卸载应拒绝，不应删除账号或额外数据。
10. 重装：在同一空闲端口重新安装，确认新的 Secret 和新链接生效。

第二轮补充验收（仍须在可丢弃测试 VPS 执行）：

- 在各发行版使用已有 ShellCheck、systemd-analyze 和 logrotate 执行原生检查；本机模拟不能替代它们。
- 修改测试 unit 后，管理、刷新和卸载应因静态摘要不一致拒绝；恢复原始文件字节后重新测试。替换目录、添加嵌套 bind mount、将日志换成硬链接时应拒绝自动删除；先确认外部目标数据没有变化。
- 停用刷新 timer 后 `self-test` 应失败。检查统计端口只绑定 127.0.0.0/8 或 ::1；具体公网地址和混合监听不能被判为本机安全监听。
- 同内容 refresh 不应更换主 PID；无效配置、网络超时和下载中手动停止不应重启代理；有效更新后的现有客户端重连时间须实际记录。
- 在安装各阶段及配置替换前后发送 INT/TERM，核对退出码、目录/账号/unit 清理及旧配置恢复；SIGKILL、断电和底层文件系统故障不保证自动回滚，不要据此测试生产 VPS。
- 卸载确认等待期间增加测试数据，应拒绝并保留数据；卸载中重载失败时核对文件清理与错误提示，再人工执行 daemon-reload。测试文件删除、账号删除失败时保留情况。

当前开发机没有 Linux/systemd、Docker 或可访问的测试 VPS，因此上述项目是人工验收步骤，不应当视为已通过的测试。
