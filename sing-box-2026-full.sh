#!/bin/bash
# 2026 旗舰版：acme.sh 证书申请 + Reality + Hy2 (端口跳跃) + DashBoard
set -e

work_dir="/etc/sing-box"
HY2_PORT_START=20000
HY2_PORT_END=30000
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

log() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; exit 1; }

# === 1. 证书申请逻辑 (acme.sh) ===
setup_cert() {
    read -rp "请输入你的解析域名: " domain
    [[ -z "$domain" ]] && error "域名不能为空"

    log "开始部署 acme.sh 并申请证书..."
    if ! command -v socat >/dev/null; then
        apt update && apt install -y socat || yum install -y socat
    fi

    curl https://get.acme.sh | sh -s email=my@example.com
    alias acme.sh='/root/.acme.sh/acme.sh'
    
    # 停止占用 80 端口的服务
    systemctl stop nginx apache2 2>/dev/null || true

    if /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256; then
        /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --fullchain-file "${work_dir}/cert.pem" \
            --key-file "${work_dir}/key.pem"
        log "✅ 证书申请成功并安装至 ${work_dir}"
    else
        error "证书申请失败，请检查防火墙是否开启 80 端口或域名解析是否生效"
    fi
}

# === 2. 优化内核与防火墙 ===
optimize_system() {
    log "优化内核参数..."
    cat > /etc/sysctl.d/99-singbox.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
    sysctl --system >/dev/null 2>&1

    log "配置 Hysteria2 端口跳跃..."
    iptables -t nat -F PREROUTING 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport $HY2_PORT_START:$HY2_PORT_END -j REDIRECT --to-ports 443
    # 存储规则
    if [ -f /etc/debian_version ]; then
        apt install -y iptables-persistent && netfilter-persistent save
    fi
}

# === 3. 核心安装逻辑 ===
install_singbox() {
    local version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//')
    log "安装 sing-box v$version..."
    mkdir -p "$work_dir"
    wget -qO /tmp/sbx.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"
    tar -xzf /tmp/sbx.tar.gz -C /tmp
    mv /tmp/sing-box-*/sing-box "${work_dir}/sing-box"
    chmod 755 "${work_dir}/sing-box"
    
    # UI 面板下载
    mkdir -p "${work_dir}/ui"
    wget -qO /tmp/ui.zip https://github.com/MetaCubeX/MetacubexD/archive/gh-pages.zip
    unzip -qo /tmp/ui.zip -d /tmp && mv /tmp/MetacubexD-gh-pages/* "${work_dir}/ui/"
}

# === 4. 生成配置 ===
generate_config() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local hy2_pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    local secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
    local keypair=$("${work_dir}/sing-box" generate reality-keypair)
    local priv=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}')
    local pub=$(echo "$keypair" | awk '/PublicKey:/ {print $2}')
    local ip=$(curl -s4 ip.sb)

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
  "inbounds": [
    {
      "type": "vless",
      "tag": "Reality",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "uuid": "$uuid" }],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.apple.com", "server_port": 443 },
          "private_key": "$priv"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "Hy2",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "password": "$hy2_pass" }],
      "tls": { "enabled": true, "server_name": "$domain", "cert_path": "${work_dir}/cert.pem", "key_path": "${work_dir}/key.pem" }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

    log "========================================"
    log "✅ 部署完成！"
    log "域名: $domain"
    log "VLESS (Reality): vless://$uuid@$ip:443?security=reality&pbk=$pub&sni=www.apple.com&fp=chrome&type=tcp#Reality"
    log "Hy2 (跳跃端口): $ip:$HY2_PORT_START-$HY2_PORT_END (密码: $hy2_pass)"
    log "📊 可视化面板: http://$ip:9090/ui (密钥: $secret)"
    log "========================================"
}

# === 5. 服务启动 ===
start_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=${work_dir}/sing-box run -c ${work_dir}/config.json
Restart=on-failure
User=root
WorkingDirectory=${work_dir}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now sing-box
}

main() {
    setup_cert
    install_singbox
    optimize_system
    generate_config
    start_service
}

main "$@"
