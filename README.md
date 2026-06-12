# MTProxy 一键部署

## 适用场景

- Linux VPS 云服务器
- 需要 `root` 权限
- 建议系统：Debian / Ubuntu

## 一条命令部署

在 VPS 上直接执行这一条命令即可：

```bash
curl -fsSL https://raw.githubusercontent.com/koajsj/mtp/main/MTP一键部署.sh | bash
```

这个命令会自动：

- 下载仓库里的部署脚本
- 检查 `curl`
- 按需安装 `curl`
- 创建 `/home/mtproxy`
- 下载上游安装脚本
- 启动 MTProxy 安装流程

## 常用操作

```bash
bash /home/mtproxy/mtproxy.sh start
bash /home/mtproxy/mtproxy.sh debug
bash /home/mtproxy/mtproxy.sh stop
bash /home/mtproxy/mtproxy.sh restart
```

## 卸载

```bash
rm -rf /home/mtproxy
```

## 说明

- 首次安装后，请按脚本提示完成配置
- 如果 VPS 开了防火墙，请确认代理端口已经放行
- 如果系统里没有 `curl`，脚本会尝试自动安装
## Default Port

- The default client port is `8443`, not `443`.
- Override it by setting `MT_PROXY_DEFAULT_PORT` before running the installer.
