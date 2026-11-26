#!/bin/bash

# Author
# original author:https://github.com/gongzili456
# modified by:https://github.com/haoel
# modified by:https://github.com/superzdev 2024年07月09日12:09:37

set -euo pipefail

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

check_system() {
    [[ -r /etc/os-release ]] || fail "无法读取 /etc/os-release。"
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ ${ID:-} == ubuntu ]] || fail "仅支持 Ubuntu 24.04 / 26.04。"
    case "${VERSION_ID:-}" in
        24.04) REPO_CODENAME=noble ;;
        26.04) REPO_CODENAME=resolute ;;
        *) fail "不支持 Ubuntu ${VERSION_ID:-unknown}，请使用 24.04 或 26.04 LTS。" ;;
    esac
    [[ $EUID -eq 0 ]] || fail "请使用 sudo bash $0 运行。"
    [[ -d /run/systemd/system ]] || fail "需要使用 systemd 的 Ubuntu 主机。"
    printf '当前系统：Ubuntu %s，内核：%s\n' "$VERSION_ID" "$(uname -r)"
}

apt_get() {
    apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=60 "$@"
}

apt_update() {
    apt_get update --error-on=any || fail "APT 索引更新失败，请检查网络及报错的软件源，修复后重新运行。"
}

install_preinstall() {
    [[ ${PREINSTALL_DONE:-0} == 1 ]] && return 0
    printf '正在刷新 APT 索引并安装必要依赖……\n'
    apt_update
    apt_get install -y ca-certificates curl kmod procps python3 software-properties-common
    PREINSTALL_DONE=1
}

configure_docker_service() {
    systemctl enable --now docker
    docker info >/dev/null
    if docker container inspect gost >/dev/null 2>&1; then
        docker update --restart=always gost
        printf '已将现有 Gost 容器的重启策略设为 always。\n'
    fi
}

install_bbr() {
    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    if [[ " $available " != *" bbr "* ]]; then
        modprobe tcp_bbr || fail "当前内核不提供 tcp_bbr，请检查宿主机内核或安装匹配的内核模块后重试。"
    fi
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    [[ " $available " == *" bbr "* ]] || fail "当前内核不支持 BBR。"
    install -d -m 0755 /etc/modules-load.d /etc/sysctl.d
    if [[ -d /sys/module/tcp_bbr ]]; then
        printf 'tcp_bbr\n' > /etc/modules-load.d/90-gost-bbr.conf
    fi
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/90-gost-bbr.conf
    sysctl -p /etc/sysctl.d/90-gost-bbr.conf
    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]] || fail "BBR 未生效。"
}

install_docker() {
    local arch package
    if command -v docker >/dev/null 2>&1; then
        configure_docker_service
        printf '现有 Docker 服务可用，保留当前安装。\n'
        return
    fi
    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
        if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) == 'install ok installed' ]]; then
            fail "发现可能冲突的包 $package，请评估现有服务并手动处理后重试。"
        fi
    done
    if grep -qs 'download.docker.com/linux/ubuntu' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; then
        fail "已有 Docker APT 源，请检查并移除重复或旧版本源后重试。"
    fi
    install_preinstall
    arch=$(dpkg --print-architecture)
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 120 \
        "https://download.docker.com/linux/ubuntu/dists/${REPO_CODENAME}/InRelease" -o /dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 120 \
        https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${REPO_CODENAME}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt_update
    apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    configure_docker_service
}

install_certbot() {
    install_preinstall
    add-apt-repository -y universe
    apt_update
    apt_get install -y certbot
}

read_domain() {
    read -r -p '请输入域名（例如 proxy.example.com）：' DOMAIN
    [[ ${#DOMAIN} -le 253 && $DOMAIN == *.* && $DOMAIN != *..* && $DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || fail "域名格式无效。"
    DOMAIN=${DOMAIN,,}
}

create_cert() {
    local has_record
    [[ -x /usr/bin/certbot ]] || install_certbot
    printf '域名的 A/AAAA 记录需指向本机，公网 TCP 80 必须可达且未被其他服务占用；续期同样需要该端口。\n'
    read -r -p '已完成以上配置？[y/N] ' has_record
    case "$has_record" in
        y|Y|yes|YES) ;;
        *) return ;;
    esac
    read_domain
    /usr/bin/certbot certonly --standalone --cert-name "$DOMAIN" -d "$DOMAIN"
    create_renewal_job
}

install_gost() {
    local proxy_user proxy_password port cert key encoded_user encoded_password
    command -v docker >/dev/null 2>&1 || fail "请先安装 Docker。"
    docker info >/dev/null
    if docker container inspect gost >/dev/null 2>&1; then
        fail "已存在名为 gost 的容器（可能已停止），请先检查并手动处理。"
    fi
    command -v python3 >/dev/null 2>&1 || apt_get install -y python3
    read_domain
    cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    [[ -s $cert && -s $key ]] || fail "未找到域名对应的证书，请先创建 SSL 证书。"
    read -r -p '请输入用户名：' proxy_user
    read -r -s -p '请输入密码：' proxy_password
    printf '\n'
    [[ -n $proxy_user && -n $proxy_password ]] || fail "用户名和密码不能为空。"
    read -r -p '请输入 HTTP/2 监听端口 [443]：' port
    port=${port:-443}
    [[ $port =~ ^[0-9]{1,5}$ ]] || fail "端口必须是 1–65535 的整数。"
    port=$((10#$port))
    (( port >= 1 && port <= 65535 && port != 80 )) || fail "端口必须在 1–65535 之间，且不能占用续期所需的 80 端口。"
    encoded_user=$(printf '%s' "$proxy_user" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')
    encoded_password=$(printf '%s' "$proxy_password" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')
    docker run -d --name gost --restart=always \
        -v /etc/letsencrypt:/etc/letsencrypt:ro \
        --net=host ginuerzh/gost \
        -L "http2://${encoded_user}:${encoded_password}@0.0.0.0:${port}?cert=${cert}&key=${key}&probe_resist=code:400&knock=www.google.com"
    printf 'Gost 容器已创建，请放行 TCP %s，并使用 docker logs gost 检查启动状态。\n' "$port"
}

create_renewal_job() {
    [[ -x /usr/bin/certbot ]] || fail "请先通过菜单创建证书，或安装 Ubuntu 的 certbot 包。"
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/90-restart-gost <<'EOF'
#!/bin/sh
set -eu
if [ -x /usr/bin/docker ] && [ "$(/usr/bin/docker container inspect -f '{{.State.Running}}' gost 2>/dev/null)" = true ]; then
    /usr/bin/docker restart gost
fi
EOF
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/90-restart-gost
    systemctl enable --now certbot.timer
    printf '已启用 certbot.timer；证书成功更新后才重启正在运行的 Gost。\n'
    printf '请运行 sudo certbot renew --dry-run 验证续期；旧脚本的强制续期 cron 任务需通过 sudo crontab -e 手动移除。\n'
}

init() {
    local choice
    check_system
    install_preinstall
    if command -v docker >/dev/null 2>&1; then
        configure_docker_service
    fi
    while true; do
        printf '\n1) 启用 TCP BBR\n2) 安装系统必要依赖\n3) 安装 Docker\n4) 创建 SSL 证书\n5) 安装 Gost HTTP/2 代理\n6) 配置证书自动续期\n7) 退出\n'
        read -r -p '请选择 [1-7]：' choice || return 0
        case "$choice" in
            1) install_bbr ;;
            2) PREINSTALL_DONE=0; install_preinstall ;;
            3) install_docker ;;
            4) create_cert ;;
            5) install_gost ;;
            6) create_renewal_job ;;
            7) return ;;
            *) printf '无效选项，请输入 1–7。\n' ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    init
fi
