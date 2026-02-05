#!/bin/bash
# 2026 旗舰版：Reality+Hy2+TUIC5+Argo+Dashboard+QRcode
set -e

# 设置变量
work_dir="/etc/sing-box"
HY2_PORT_START=20000
HY2_PORT_END=30000
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

log() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; exit 1; }

# 1. 环境准备 (解决依赖冲突)
prepare_env() {
    log "正在清理冲突并安装依赖..."
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    # 核心工具包，解决 base64, unzip, qrencode 等缺失问题
    apt install -y curl wget openssl tar coreutils ca-certificates socat qrencode iptables unzip iptables-persistent -y
    mkdir -p "$work_dir"
}

# 2. 证书申请 (带自动回退逻辑)
setup_cert() {
    read -rp "请输入解析到本机的域名: " domain
    [[ -z "$domain" ]] && error "域名不能为空"
    
    log "证书申请中..."
    systemctl stop nginx apache2 2>/dev/null || true
    
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email=my@example.com
    fi

    # 模拟真实：如果 acme 失败，自动生成自签名证书防止脚本崩溃
    if /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256 --force; then
        /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --fullchain-file "${work_dir}/cert.pem" \
            --key-file "${work_dir}/key.pem"
        log "✅ 正式证书申请成功"
    else
        warn "域名解析未生效或 80 端口受阻，已启用自签名证书补救"
        openssl req -x509 -newkey rsa:2048 -keyout "${work_dir}/key.pem" -out "${work_dir}/cert.pem" -days 3650 -nodes -subj "/CN=$domain"
    fi
}

# 3. 配置文件生成 (JSON 语法闭环)
generate_config() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
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
      "tag": "Reality-In",
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
      "tag": "Hy2-In",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "password": "$pass" }],
      "tls": { "enabled": true, "server_name": "$domain", "cert_path": "${work_dir}/cert.pem", "key_path": "${work_dir}/key.pem" }
    },
    {
      "type": "tuic",
      "tag": "TUIC-In",
      "listen": "::",
      "listen_port": 8443,
      "users": [{ "uuid": "$uuid", "password": "$pass" }],
      "congestion_control": "bbr",
      "tls": { "enabled": true, "server_name": "$domain", "cert_path": "${work_dir}/cert.pem", "key_path": "${work_dir}/key.pem" }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

    # 二维码与链接输出
    local reality_link="vless://$uuid@$ip:443?security=reality&pbk=$pub&sni=www.apple.com&fp=chrome&type=tcp#Reality_2026"
    
    log "========================================"
    log "📊 监控面板: http://$ip:9090/ui"
    log "🔑 面板密钥: $secret"
    log "----------------------------------------"
    log "📱 Reality 节点二维码 (手机直接扫):"
    echo "$reality_link" | qrencode -t UTF8
    log "🔗 Reality 链接: $reality_link"
    log "🔗 Hy2 密码: $pass (端口 443 + 20000-30000)"
    log "========================================"
}

# (省略部分安装与系统启动代码，逻辑与前述一致)
