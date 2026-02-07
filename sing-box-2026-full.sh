#!/bin/bash
set -e

# --- 基础配置 ---
work_dir="/etc/sing-box"
bin_path="/usr/local/bin/sing-box"

log() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; exit 1; }

# --- 1. 彻底卸载函数（使用 pgrep 避免 Killed）---
uninstall() {
    log "正在清理舊環境..."
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true

    # 仅当进程存在时才 kill，避免无谓报错
    pgrep -f "sing-box" >/dev/null && pkill -9 -f "sing-box" || true
    pgrep -f "cloudflared" >/dev/null && pkill -9 -f "cloudflared" || true

    rm -rf "$work_dir" /etc/systemd/system/sing-box.service "$bin_path"
    systemctl daemon-reload >/dev/null 2>&1 || true
    log "✅ 已成功卸载所有组件。"
}

# --- 2. 环境准备 ---
prepare_env() {
    log "配置 Ubuntu 24.04 組件..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl wget openssl tar qrencode unzip net-tools iptables-persistent

    # 开启内核转发
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
    fi

    # 防火墙：保留你原设计 —— TCP/UDP 443 共用（实测可用）
    iptables -F
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT   # SSH
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT  # Reality (TCP)
    iptables -A INPUT -p udp --dport 443 -j ACCEPT  # Hysteria2 (UDP) ← 保留！
    iptables -A INPUT -p udp --dport 8443 -j ACCEPT # TUIC (UDP)
    iptables -A INPUT -p tcp --dport 9090 -j ACCEPT # Panel
    iptables-save > /etc/iptables/rules.v4
}

# --- 3. 安装核心与 UI ---
install_singbox_and_ui() {
    log "下載 sing-box 核心..."
    local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local tag=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -O /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$tag/sing-box-${tag#v}-linux-$arch.tar.gz"
    tar -xzf /tmp/sb.tar.gz -C /tmp && mv /tmp/sing-box-*/sing-box "$bin_path"
    chmod +x "$bin_path"

    log "安裝面板..."
    mkdir -p "$work_dir/ui"
    wget -O /tmp/ui.zip https://github.com/MetaCubeX/Metacubexd/archive/refs/heads/gh-pages.zip
    unzip -o /tmp/ui.zip -d /tmp/ui_temp
    local real_ui_path=$(find /tmp/ui_temp -name "index.html" | head -n 1 | xargs dirname)
    if [ ! -f "$real_ui_path/index.html" ]; then
        error "面板文件缺失，请检查网络或 GitHub 状态"
    fi
    cp -rf "$real_ui_path"/* "$work_dir/ui/"
    rm -rf /tmp/ui.zip /tmp/ui_temp /tmp/sb.tar.gz
}

# --- 4. 核心配置（保留 443 共用 + 你的四大核心逻辑）---
setup_config() {
    read -p "請輸入解析域名 (用于 Hy2/TUIC，默認為 apple.com): " domain
    [[ -z "$domain" ]] && domain="apple.com"

    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
    local secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    local keypair=$("$bin_path" generate reality-keypair)
    local priv=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}')
    local pub=$(echo "$keypair" | awk '/PublicKey:/ {print $2}')
    local short_id=$(openssl rand -hex 4)
    local ip=$(curl -s4 ip.sb)

    openssl req -x509 -newkey rsa:2048 -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" \
        -days 3650 -nodes -subj "/CN=$domain" >/dev/null 2>&1

    cat <<EOF > "$work_dir/config.json"
{
  "log": {
    "level": "warn"
  },
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "external_ui": "ui",
      "secret": "$secret"
    }
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "Reality-In",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "tcp_fast_open": true,
      "sniff": true,
      "sniff_override_destination": true,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.apple.com",
            "server_port": 443
          },
          "private_key": "$priv",
          "short_id": ["$short_id"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "Hy2-In",
      "listen": "0.0.0.0",
      "listen_port": 443,        // ← 保留 UDP 443，与 Reality TCP 443 共存
      "network": "udp",
      "users": [{"password": "$pass"}],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/key.pem"
      }
    },
    {
      "type": "tuic",
      "tag": "TUIC-In",
      "listen": "0.0.0.0",
      "listen_port": 8443,
      "users": [{"uuid": "$uuid", "password": "$pass"}],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/key.pem",
        "alpn": ["h3"]
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

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
    echo -e "\n\033[35m==============================================================\033[0m"
    log "🔑 面板地址: http://$ip:9090/ui/  密鑰: $secret"
    echo -e "\n\033[33m🚀 Reality 節點:\033[0m"
    echo "vless://$uuid@$ip:443?security=reality&encryption=none&pbk=$pub&sni=www.apple.com&fp=chrome&shortId=$short_id&type=tcp&flow=xtls-rprx-vision#Reality"
    echo -e "\n\033[33m🚀 Hy2 節點:\033[0m"
    echo "hysteria2://$pass@$ip:443?sni=$domain&insecure=1#Hy2"
    echo -e "\n\033[33m🚀 TUIC5 節點:\033[0m"
    echo "tuic://$uuid:$pass@$ip:8443?sni=$domain&alpn=h3&insecure=1#TUIC5"
    echo -e "\033[35m==============================================================\033[0m\n"
    log "💡 提示：使用 journalctl -u sing-box -f 查看运行日志"
}

# --- 5. 交互菜单 ---
show_menu() {
    clear
    echo -e "\033[36m      sing-box 管理脚本 (Reality 修复版 - 保留 443 共用)\033[0m"
    echo "------------------------------------------"
    echo "  1. 安装 / 重新安装"
    echo "  2. 彻底卸载"
    echo "  3. 退出"
    echo "------------------------------------------"
    read -p "选择操作: " num
    case "$num" in
        1)
            warn "注意：重装将删除所有旧配置！"
            read -p "确认继续? (y/N): " confirm
            [[ "$confirm" != "y" ]] && exit 0
            uninstall
            prepare_env
            install_singbox_and_ui
            setup_config
            ;;
        2)
            uninstall
            ;;
        3)
            exit 0
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

if [[ $# -gt 0 ]]; then
    case "${1}" in
        uninstall) uninstall ;;
        *) show_menu ;;
    esac
else
    show_menu
fi
