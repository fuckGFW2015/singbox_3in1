#!/bin/bash
set -e
work_dir="/etc/sing-box"
bin_path="/usr/local/bin/sing-box"

log() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; exit 1; }

prepare_env() {
    log "正在清理環境、安裝依賴並自動配置防火牆..."
    apt-get update -y && apt-get install -y curl wget openssl tar qrencode iptables unzip net-tools iptables-persistent
    
    # 禁用 UFW (如果存在)
    if command -v ufw >/dev/null; then ufw disable || true; fi
    
    # 刷新並配置 iptables
    iptables -P INPUT ACCEPT
    iptables -F
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p udp --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp --dport 2053 -j ACCEPT
    iptables -A INPUT -p udp --dport 8443 -j ACCEPT
    iptables -A INPUT -p tcp --dport 9090 -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # 規則持久化
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    log "✅ 防火牆規則已生效 (放行: 443, 2053, 8443, 9090)"
}

uninstall() {
    log "正在徹底卸載舊環境..."
    systemctl stop sing-box || true
    systemctl disable sing-box || true
    pkill -9 cloudflared || true
    rm -rf "$work_dir" /usr/local/bin/cloudflared
    rm -f /etc/systemd/system/sing-box.service /usr/local/bin/sing-box
    systemctl daemon-reload
}

install_singbox_and_ui() {
    log "正在安裝最新版 sing-box 核心..."
    local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local tag=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -O /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$tag/sing-box-${tag#v}-linux-$arch.tar.gz"
    tar -xzf /tmp/sb.tar.gz -C /tmp && mv /tmp/sing-box-*/sing-box "$bin_path"
    chmod +x "$bin_path"
    
    log "正在安裝 Metacubexd 面板..."
    mkdir -p "$work_dir/ui"
    wget -O /tmp/ui.zip https://github.com/MetaCubeX/Metacubexd/archive/refs/heads/gh-pages.zip
    unzip -o /tmp/ui.zip -d /tmp && cp -rf /tmp/Metacubexd-gh-pages/* "$work_dir/ui/"
    rm -rf /tmp/ui.zip /tmp/sb.tar.gz /tmp/Metacubexd-gh-pages
}

setup_config() {
    read -p "請輸入解析域名 (Hy2/TUIC/VLESS-WS用): " domain
    [[ -z "$domain" ]] && domain="apple.com"
    read -p "是否配置 Argo 隧道 (VMess 用)？(y/n): " do_argo
    
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
    local secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    local keypair=$("$bin_path" generate reality-keypair)
    local priv=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}')
    local pub=$(echo "$keypair" | awk '/PublicKey:/ {print $2}')
    local short_id=$(openssl rand -hex 4)
    local ip=$(curl -s4 ip.sb)

    openssl req -x509 -newkey rsa:2048 -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" -days 3650 -nodes -subj "/CN=$domain" >/dev/null 2>&1

    cat <<EOF > "$work_dir/config.json"
{
  "log": { "level": "info" },
  "experimental": {
    "clash_api": { "external_controller": "0.0.0.0:9090", "external_ui": "ui", "secret": "$secret" }
  },
  "inbounds": [
    { "type": "vless", "tag": "Reality", "listen": "::", "listen_port": 443, "users": [{"uuid": "$uuid"}], "tls": { "enabled": true, "server_name": "www.apple.com", "reality": { "enabled": true, "handshake": { "server": "www.apple.com", "server_port": 443 }, "private_key": "$priv", "short_id": ["$short_id"] } } },
    { "type": "vless", "tag": "VLESS-WS-TLS", "listen": "::", "listen_port": 2053, "users": [{"uuid": "$uuid"}], "tls": { "enabled": true, "server_name": "$domain", "certificate_path": "$work_dir/cert.pem", "key_path": "$work_dir/key.pem" }, "transport": { "type": "ws", "path": "/vless" } },
    { "type": "hysteria2", "tag": "Hy2", "listen": "::", "listen_port": 443, "users": [{"password": "$pass"}], "tls": { "enabled": true, "server_name": "$domain", "certificate_path": "$work_dir/cert.pem", "key_path": "$work_dir/key.pem" } },
    { "type": "tuic", "tag": "TUIC5", "listen": "::", "listen_port": 8443, "users": [{"uuid": "$uuid", "password": "$pass"}], "tls": { "enabled": true, "server_name": "$domain", "certificate_path": "$work_dir/cert.pem", "key_path": "$work_dir/key.pem", "alpn": ["h3"] } },
    { "type": "vmess", "tag": "Argo-In", "listen": "127.0.0.1", "listen_port": 8080, "users": [{"uuid": "$uuid"}], "transport": { "type": "ws", "path": "/vmess" } }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

    if [[ "$do_argo" == "y" ]]; then
        local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
        wget -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
        chmod +x /usr/local/bin/cloudflared
        nohup /usr/local/bin/cloudflared tunnel --url http://127.0.0.1:8080 > /tmp/argo.log 2>&1 &
        sleep 5
        argo_domain=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' /tmp/argo.log | head -n 1 | sed 's/https:\/\///')
    fi

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
    
    clear
    echo -e "\033[32m✅ 部署完成！Metacubexd 面板及防火牆已就緒\033[0m"
    echo -e "--------------------------------------------------------------"
    echo -e "可視化面板: http://$ip:9090/ui/  (密鑰: $secret)"
    echo -e "--------------------------------------------------------------"

    local rel_url="vless://$uuid@$ip:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=$pub&sid=$short_id&type=tcp#Reality-$ip"
    echo -e "\033[33m🚀 [Reality]\033[0m\n\033[36m$rel_url\033[0m\n"

    local vws_url="vless://$uuid@$ip:2053?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=%2fvless#VLESS-WS-$ip"
    echo -e "\033[33m🚀 [VLESS-WS-TLS]\033[0m (端口2053)\n\033[36m$vws_url\033[0m\n"

    local hy2_url="hysteria2://$pass@$ip:443?sni=$domain&insecure=1&alpn=h3#Hy2-$ip"
    echo -e "\033[33m🚀 [Hysteria2]\033[0m\n\033[36m$hy2_url\033[0m\n"

    local tuic_url="tuic://$uuid:$pass@$ip:8443?sni=$domain&alpn=h3&insecure=1#TUIC5-$ip"
    echo -e "\033[33m🚀 [TUIC5]\033[0m\n\033[36m$tuic_url\033[0m\n"

    if [[ ! -z "$argo_domain" ]]; then
        local vmess_json='{"v":"2","ps":"Argo-VMess","add":"'$argo_domain'","port":"443","id":"'$uuid'","aid":"0","scy":"auto","net":"ws","type":"none","host":"'$argo_domain'","path":"/vmess","tls":"tls"}'
        local vmess_url="vmess://$(echo -n $vmess_json | base64 -w 0)"
        echo -e "\033[33m🚀 [Argo VMess]\033[0m (Cloudflare 穿透)\n\033[36m$vmess_url\033[0m\n"
    fi
}

# 執行邏輯
uninstall
prepare_env
install_singbox_and_ui
setup_config
