#!/bin/bash
set -e
work_dir="/etc/sing-box"
bin_path="/usr/local/bin/sing-box"

log() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; exit 1; }

# --- 卸载函数 ---
uninstall() {
    log "正在徹底卸載 sing-box 及相關組件..."
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    pkill -9 sing-box >/dev/null 2>&1 || true
    pkill -9 cloudflared >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    rm -f /etc/systemd/system/sing-box.service
    rm -f "$bin_path"
    rm -f /usr/local/bin/cloudflared
    systemctl daemon-reload
    log "✅ 所有文件已清除，服務已卸載。"
}

# --- 环境准备 ---
prepare_env() {
    log "正在配置環境與防火牆..."
    apt-get update -y && apt-get install -y curl wget openssl tar qrencode iptables unzip net-tools iptables-persistent
    if command -v ufw >/dev/null; then ufw disable || true; fi
    iptables -P INPUT ACCEPT && iptables -F
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p udp --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp --dport 2053 -j ACCEPT
    iptables -A INPUT -p udp --dport 8443 -j ACCEPT
    iptables -A INPUT -p tcp --dport 9090 -j ACCEPT
    iptables-save > /etc/iptables/rules.v4
}

# --- 安装核心 ---
install_singbox_and_ui() {
    log "正在安裝最新版 sing-box 核心与 Metacubexd 面板..."
    local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local tag=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -O /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$tag/sing-box-${tag#v}-linux-$arch.tar.gz"
    tar -xzf /tmp/sb.tar.gz -C /tmp && mv /tmp/sing-box-*/sing-box "$bin_path"
    chmod +x "$bin_path"
    mkdir -p "$work_dir/ui"
    wget -O /tmp/ui.zip https://github.com/MetaCubeX/Metacubexd/archive/refs/heads/gh-pages.zip
    unzip -o /tmp/ui.zip -d /tmp && cp -rf /tmp/Metacubexd-gh-pages/* "$work_dir/ui/"
    rm -rf /tmp/ui.zip /tmp/sb.tar.gz /tmp/sing-box-* /tmp/Metacubexd-gh-pages
}

# --- 配置与启动 ---
setup_config() {
    read -p "請輸入解析域名: " domain
    [[ -z "$domain" ]] && domain="apple.com"
    read -p "是否配置 Argo 隧道？(y/n): " do_argo

    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
    local secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    local keypair=$("$bin_path" generate reality-keypair)
    local priv=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}')
    local pub=$(echo "$keypair" | awk '/PublicKey:/ {print $2}')
    local short_id=$(openssl rand -hex 4)
    local ip=$(curl -s4 ip.sb)

    # 生成自签名证书
    openssl req -x509 -newkey rsa:2048 -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" -days 3650 -nodes -subj "/CN=$domain" >/dev/null 2>&1
    chmod 600 "$work_dir/cert.pem" "$work_dir/key.pem"  # 🔑 关键修复：权限安全

    # 生成配置文件（使用正确的 cert_path 字段）
    cat <<EOF > "$work_dir/config.json"
{
  "log": { "level": "info" },
  "experimental": {
    "clash_api": { "external_controller": "0.0.0.0:9090", "external_ui": "ui", "secret": "$secret" }
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "Reality",
      "listen": "::",
      "listen_port": 443,
      "users": [{"uuid": "$uuid"}],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.apple.com", "server_port": 443 },
          "private_key": "$priv",
          "short_id": ["$short_id"]
        }
      }
    },
    {
      "type": "vless",
      "tag": "VLESS-WS-TLS",
      "listen": "::",
      "listen_port": 2053,
      "users": [{"uuid": "$uuid"}],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "cert_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/key.pem"
      },
      "transport": { "type": "ws", "path": "/vless" }
    },
    {
      "type": "hysteria2",
      "tag": "Hy2",
      "listen": "::",
      "listen_port": 443,
      "users": [{"password": "$pass"}],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "cert_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/key.pem"
      }
    },
    {
      "type": "tuic",
      "tag": "TUIC5",
      "listen": "::",
      "listen_port": 8443,
      "users": [{"uuid": "$uuid", "password": "$pass"}],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "cert_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/key.pem",
        "alpn": ["h3"]
      }
    },
    {
      "type": "vmess",
      "tag": "Argo-In",
      "listen": "127.0.0.1",
      "listen_port": 8080,
      "users": [{"uuid": "$uuid"}],
      "transport": { "type": "ws", "path": "/vmess" }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

    # 验证配置合法性
    "$bin_path" check -c "$work_dir/config.json" || error "配置文件校验失败！"

    # 配置 Argo（如需要）
    if [[ "$do_argo" == "y" ]]; then
        local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
        wget -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
        chmod +x /usr/local/bin/cloudflared
        nohup /usr/local/bin/cloudflared tunnel --url http://127.0.0.1:8080 > /tmp/argo.log 2>&1 &
        sleep 5
        argo_domain=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' /tmp/argo.log | head -n 1 | sed 's/https:\/\///')
        [[ -z "$argo_domain" ]] && argo_domain="获取中... 请查看 /tmp/argo.log"
    fi

    # 创建 systemd 服务
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=$bin_path run -c $work_dir/config.json
Restart=on-failure
User=root
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now sing-box
    log "✅ 部署完成！"

    # === 输出信息 ===
    clear
    echo -e "\n\033[35m==============================================================\033[0m"
    log "🌐 公网 IP: $ip"
    log "🔑 面板密钥: $secret"
    echo -e "\033[36m管理面板: http://$ip:9090/ui/\033[0m"

    if [[ "$do_argo" == "y" ]]; then
        echo -e "\n\033[33m🚇 Argo 隧道地址:\033[0m"
        echo -e "\033[36mhttps://$argo_domain/vmess\033[0m"
    fi

    echo -e "\n\033[33m🚀 [Reality 节点]\033[0m"
    local rel_url="vless://$uuid@$ip:443?security=reality&pbk=$pub&sni=www.apple.com&fp=chrome&shortId=$short_id&type=tcp#Reality"
    echo -e "\033[32m$rel_url\033[0m"
    echo "$rel_url" | qrencode -t UTF8

    echo -e "\n\033[33m🚀 [Hysteria2 节点]\033[0m"
    local hy2_url="hysteria2://$pass@$ip:443?sni=$domain&insecure=1#Hy2"
    echo -e "\033[32m$hy2_url\033[0m"
    echo "$hy2_url" | qrencode -t UTF8

    echo -e "\n\033[33m🚀 [TUIC v5 节点]\033[0m"
    local tuic_url="tuic://$uuid:$pass@$ip:8443?sni=$domain&alpn=h3&insecure=1#TUIC5"
    echo -e "\033[32m$tuic_url\033[0m"

    echo -e "\n\033[35m==============================================================\033[0m\n"
}

# --- 脚本执行入口 ---
case "$1" in
    uninstall)
        uninstall
        ;;
    *)
        uninstall  # 先清理旧版本
        prepare_env
        install_singbox_and_ui
        setup_config
        ;;
esac
