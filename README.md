# MTProxy 一键部署

## 适用场景

- Linux VPS 云服务器
- 需要 `root` 权限
- 建议系统：Debian / Ubuntu

## 使用方法

### Linux VPS

先从 GitHub 拉取仓库里的部署脚本。推荐 `curl`，没有 `curl` 时可用 `wget` 兜底：

```bash
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o MTP一键部署.sh https://raw.githubusercontent.com/koajsj/mtp/main/MTP一键部署.sh
elif command -v wget >/dev/null 2>&1; then
  wget -O MTP一键部署.sh https://raw.githubusercontent.com/koajsj/mtp/main/MTP一键部署.sh
else
  echo "请先安装 curl 或 wget"
  exit 1
fi
```

然后执行：

```bash
bash MTP一键部署.sh
```

### Windows 本机

如果你只是想先把脚本下载到本机查看或转存，可以用 PowerShell：

```powershell
Invoke-WebRequest -OutFile MTP一键部署.sh https://raw.githubusercontent.com/koajsj/mtp/main/MTP一键部署.sh
```

## 脚本会自动完成

- 检查 `curl`
- 按需安装 `curl`
- 创建 `/home/mtproxy`
- 下载上游安装脚本
- 启动 MTProxy 安装流程

## 常用操作

```bash
bash mtproxy.sh start
bash mtproxy.sh debug
bash mtproxy.sh stop
bash mtproxy.sh restart
```

## 卸载

```bash
rm -rf /home/mtproxy
```

## 说明

- 首次安装后，请按脚本提示完成配置
- 如果 VPS 开了防火墙，请确认代理端口已经放行
- 如果系统里没有 `curl`，脚本会尝试自动安装
