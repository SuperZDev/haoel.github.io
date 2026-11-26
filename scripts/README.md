# 安装脚本

相关的不同平台的安装脚本。

## Ubuntu 24.04 / 26.04 LTS

使用 [install.ubuntu.24.26.new.sh](install.ubuntu.24.26.new.sh)，适用于已经安装 Ubuntu 24.04（noble）或 26.04（resolute）、使用 systemd 的服务器。这是服务安装脚本，不会将 Ubuntu 18.04 操作系统升级到新版本。旧版脚本保留供参考。

在仓库根目录运行：

```bash
sudo bash scripts/install.ubuntu.24.26.new.sh
```

建议依次选择：`2` 安装依赖 → `1` 启用 BBR（可选）→ `3` 安装 Docker → `4` 申请证书 → `5` 启动 Gost。申请证书成功后会自动配置续期，菜单 `6` 可重复配置。

- BBR 使用当前内核提供的能力，配置写入独立的 `sysctl.d` / `modules-load.d` 文件，不再安装 18.04 内核包或自动重启机器。受限容器或缺少 BBR 模块的内核会报错。
- Docker 使用当前发行版的官方 APT 源、独立签名密钥及实际 CPU 架构，不再使用 `apt-key`，也不会回退到其他 Ubuntu 版本的源。已有可用 Docker 安装会保留；冲突软件包或旧源需先手动处理。安装中断后如留下源文件，应检查后再重试。
- Certbot 使用 Ubuntu `universe` 软件源，不再添加旧 PPA。使用 `certbot.timer` 定时检查续期，仅在成功更新证书后重启正在运行的 Gost，不强制每月重新签发。
- 域名的 A/AAAA 记录需要指向服务器，防火墙和云安全组需要放行 TCP 80（申请和续期）及 Gost 监听端口（默认 443）。80 端口需保持空闲；已有 Web 服务时请自行配置匹配的 Certbot 验证方式。
- Gost 沿用原脚本的 `ginuerzh/gost` 镜像和 HTTP/2 参数，设置 `unless-stopped` 重启策略。镜像是否支持服务器架构由镜像发布方决定；启动后检查日志。已存在的同名容器（包括停止状态）不会被覆盖。
- 操作失败时脚本停止并显示原始错误，排除问题后重新运行。脚本不修改防火墙规则。

检查服务及续期：

```bash
sudo docker logs gost
sudo systemctl status certbot.timer
sudo certbot renew --dry-run --no-random-sleep-on-renew
```

如果运行过旧脚本，请通过 `sudo crontab -e` 删除旧的 `certbot renew --force-renewal` 和定时 `docker restart gost` 任务，避免重复调度；同时检查旧 Docker 源和 `ppa:certbot/certbot`，不要将旧发行版源混入新系统。

实现依据：[Docker Ubuntu 安装说明](https://docs.docker.com/engine/install/ubuntu/)、[Certbot 续期及 deploy hook](https://eff-certbot.readthedocs.io/en/stable/using.html#renewing-certificates)。

验证范围：通过 Bash 语法、ShellCheck 和模拟失败流程检查；已在 Ubuntu 26.04.1 LTS ARM64（AWS 内核 7.0.0-1018-aws）实测依赖安装、BBR、Docker 29.10.1、Certbot 4.0.0、Gost 2.12.0 和重复配置。公网证书签发、HTTP/2 代理认证连接、TLS 校验及未认证访问拒绝均通过验证；续期演练及成功后的 Gost 重启 hook 也已通过。Ubuntu 24.04 ARM64 已在容器内验证 Ubuntu / Docker noble 软件源和全部安装包依赖解析，尚未进行完整主机安装、内核及 systemd 验证。
