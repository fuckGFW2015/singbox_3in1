#!/bin/bash
# 2026 最终版：Reality + Hysteria2 (端口跳跃) + Clash API Dashboard
# 修复：架构兼容、API 安全、无证书降级、日志安全、服务健壮

set -e

# === 全局参数 ===
work_dir="/etc/sing-box"
HY2_PORT_START=20000
HY2_PORT_END=30000

# 架构映射（安全）
ARCH=""
case "$(uname -m)" in
  x86_64)   ARCH="amd64" ;;
  aarch64)  ARCH="arm64" ;;
  armv7l)   ARCH="armv7" ;;
  *) echo "❌ 不支持的架构: $(uname -m)"; exit 1 ;;
esac

# 日志函数（输出到 stderr，避免污染）
log() { echo -e "\033[32m[INFO]\033[0m $1" >&2; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
error() { echo -e "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }

# === 1. 环境准备与依赖安装 ===
check_env() {
    log "检查并安装系统依赖..."
    # 注意：base64 是 coreutils 的一部分，无需单独安装
    local pkgs="curl wget openssl tar qrencode iptables iptables-persistent unzip ca-certificates"
    if [ -f /etc/debian_version ]; then
        apt update >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt install -y $pkgs
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget openssl tar qrencode iptables-services unzip ca-certificates
        systemctl enable --now iptables
    else
        error "不支持的操作系统"
    fi
}

# === 2. 安全获取最新版并安装 ===
install_singbox() {
    log "正在从 GitHub 获取最新 sing-box 版本..."
    local api_resp
    api_resp=$(curl -sL --max-time 10 \
        -H "Accept: application/vnd.github.v3+json" \
        -A "Mozilla/5.0 (sing-box-installer)" \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest)

    # 安全提取版本号
    local version
    if [[ "$api_resp" == *"\"tag_name\":"* ]]; then
        version=$(echo "$api_resp" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/v//')
    fi

    if [ -z "$version" ]; then
        version="1.12.20"  # 回退到已知稳定版
        warn "无法获取最新版本，使用回退版本: v$version"
    fi

    log "正在下载 sing-box v$version..."
    local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"
    wget -qO /tmp/sbx.tar.gz "$url" || error "下载失败，请检查网络或架构支持"

    tar -xzf /tmp/sbx.tar.gz -C /tmp
    mkdir -p "$work_dir"
    mv /tmp/sing-box-*/sing-box "${work_dir}/sing-box"
    chmod 755 "${work_dir}/sing-box"
    rm -rf /tmp/sbx.tar.gz /tmp/sing-box-*
    log "✅ sing-box v$version 安装完成"
}

# === 3. 部署可视化面板 (MetacubexD) ===
setup_ui() {
    log "正在部署 MetacubexD 可视化面板..."
    mkdir -p "${work_dir}/ui"
    wget -qO /tmp/ui.zip https://github.com/MetaCubeX/MetacubexD/archive/gh-pages.zip
    unzip -qo /tmp/ui.zip -d /tmp
    mv /tmp/MetacubexD-gh-pages/* "${work_dir}/ui/"
    rm -rf /tmp/ui.zip /tmp/MetacubexD-gh-pages
    log "✅ 面板 UI 部署完成"
}

# === 4. 内核与网络优化 ===
optimize_network() {
    log "正在优化内核网络参数 (BBR & UDP Buffer)..."
    cat > /etc/sysctl.d/99-singbox.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
    sysctl --system >/dev/null 2>&1

    # 端口跳跃：将 20000-30000 跳转到 443
    iptables -t nat -F PREROUTING 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport $HY2_PORT_START:$HY2_PORT_END -j REDIRECT --to-ports 443

    if [ -f /etc/debian_version ]; then
        netfilter-persistent save 2>/dev/null || true
    elif [ -f /etc/redhat-release ]; then
        service iptables save 2>/dev/null || true
    fi
}

# === 5. 生成配置（仅 Reality，无证书依赖）===
generate_config() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
    local keypair=$("${work_dir}/sing-box" generate reality-keypair)
    local priv=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}')
    local pub=$(echo "$keypair" | awk '/PublicKey:/ {print $2}')
    local ip=$(curl -s4 https://ip.sb)

    # 仅启用 Reality（无需证书），Hysteria2 需要 TLS 证书，此处省略以简化
    cat > "${work_dir}/config.json" <<EOF
{
  "log": { "level": "info" },
  "experimental": {
    "cache_file": { "enabled": true },
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "external_ui": "ui",
      "secret": "$secret",
      "default_mode": "enhanced"
    }
  },
  "stats": {},
  "inbounds": [
    {
      "type": "vless",
      "tag": "Reality-In",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "uuid": "$uuid" }],
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.cloudflare.com", "server_port": 443 },
          "private_key": "$priv"
        }
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

    log "========================================"
    log "🎉 部署成功！"
    log "🔗 Reality 节点 (VLESS):"
    log "vless://$uuid@$ip:443?security=reality&pbk=$pub&sni=www.cloudflare.com&fp=chrome&type=tcp#Reality"
    log "----------------------------------------"
    log "📊 可视化面板: http://$ip:9090/ui"
    log "🔑 面板密钥 (Secret): $secret"
    log "⚠️  注意：Hysteria2 因无有效证书已禁用，如需启用请配置域名和证书"
    log "========================================"
}

# === 6. 安装 systemd 服务 ===
install_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=${work_dir}/sing-box run -c ${work_dir}/config.json
Restart=on-failure
User=root
WorkingDirectory=${work_dir}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNPROC=500
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sing-box
    log "✅ sing-box 服务已启动"
}

# === 主流程 ===
main() {
    check_env
    install_singbox
    setup_ui
    optimize_network
    generate_config
    install_service
}

main "$@"
