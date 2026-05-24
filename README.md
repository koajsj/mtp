# MTProxy 一键部署

## 适用场景

- Linux VPS 云服务器
- 需要 `root` 权限
- 建议系统：Debian / Ubuntu

## 使用方法

1. 把仓库里的 `MTP一键部署.sh` 上传到 VPS
2. 在 VPS 上执行：

```bash
bash MTP一键部署.sh
```

脚本会自动：

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
- 如果 VPS 开了防火墙，请确认代理端口已放行
- 如果系统里没有 `curl`，脚本会尝试自动安装
