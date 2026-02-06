#!/bin/bash
# 2026 Ubuntu 专用加固版：Reality + Hy2 + TUIC5
# 特点：深度清理 ufw/iptables，修复二维码显示，自动安装依赖

set -e
work_dir="/etc/sing-box"

log() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; exit 1; }

prepare_env() {
    log "正在配置 Ubuntu 环境与放行防火墙..."
    # 强制更新并安装 qrencode (二维码核心)
    apt-get update -y
    apt-get install -y curl wget openssl tar qrencode iptables unzip iptables-persistent net-tools dnsutils

    # 1. 彻底关闭 Ubuntu 默认防火墙 ufw
    if command -v ufw >/dev/null; then
        log "检测到 ufw，正在强行关闭并清理规则..."
        ufw disable || true
    fi

    # 2. 暴力重置所有 iptables 规则
    # Ubuntu 的阿里云镜像有时会在 INPUT 链末尾加 REJECT
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    
    # 3. 显式放行端口 (双重保险)
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p udp --dport 443 -j ACCEPT
    iptables -A INPUT -p udp --dport 8443 -j ACCEPT
    iptables -A INPUT -p tcp --dport 9090 -j ACCEPT

    # 4. 解决 iptables 重启失效问题
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    netfilter-persistent save || true
}

create_user() {
    if ! id "sing-box" &>/dev/null; then 
        useradd -r -s /usr/sbin/nologin -d "$work_dir" sing-box 
    fi
    mkdir -p "$work_dir" && chown -R sing-box:sing-box "$work_dir"
}

install_singbox() {
    log "安装 sing-box 核心..."
    local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local tag=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -qO /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$tag/sing-box-${tag#v}-linux-$arch.tar.gz"
    tar -xzf /tmp/sb.tar.gz -C /tmp && mv /tmp/sing-box-*/sing-box "$work_dir/sing-box"
    chmod +x "$work_dir/sing-box"
}

setup_config() {
    read -p "请输入解析域名 (Hy2用): " domain
    [[ -z "$domain" ]] && domain="www.bing.com"
    
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
    local secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    local keypair=$("$work_dir/sing-box" generate reality-keypair)
    local priv=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}')
    local pub=$(echo "$keypair" | awk '/PublicKey:/ {print $2}')
    local ip=$(curl -s4 ip.sb)

    # 1. 强制确保证书目录权限（防止 sing-box 读取失败）
    mkdir -p "$work_dir/ui"
    touch "$work_dir/ui/index.html" # 即使面板下载失败，占位符也能防止报错
    openssl req -x509 -newkey rsa:2048 -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" -days 3650 -nodes -subj "/CN=$domain" >/dev/null 2>&1
    chown -R root:root "$work_dir"

    # 2. 写入 JSON (确保格式严谨)
    cat <<EOF > "$work_dir/config.json"
{
  "log": { "level": "info" },
  "experimental": {
    "cache_file": { "enabled": true },
    "clash_api": { "external_controller": "127.0.0.1:9090", "external_ui": "ui", "secret": "$secret" }
  },
  "inbounds": [
    { "type": "vless", "tag": "Reality", "listen": "::", "listen_port": 443, "users": [{"uuid": "$uuid"}], "tls": { "enabled": true, "server_name": "www.apple.com", "reality": { "enabled": true, "handshake": { "server": "www.apple.com", "server_port": 443 }, "private_key": "$priv" } } },
    { "type": "hysteria2", "tag": "Hy2", "listen": "::", "listen_port": 443, "users": [{"password": "$pass"}], "tls": { "enabled": true, "server_name": "$domain", "cert_path": "$work_dir/cert.pem", "key_path": "$work_dir/key.pem" } },
    { "type": "tuic", "tag": "TUIC5", "listen": "::", "listen_port": 8443, "users": [{"uuid": "$uuid", "password": "$pass"}], "tls": { "enabled": true, "server_name": "$domain", "cert_path": "$work_dir/cert.pem", "key_path": "$work_dir/key.pem" } }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

    # 3. 语法预检 (这一步最重要，失败会直接停止脚本)
    log "正在校验 sing-box 配置文件格式..."
    "$work_dir/sing-box" check -c "$work_dir/config.json" || error "配置文件校验失败！请检查是否有特殊字符。"

    # 4. 写入 Service (保持 User=root)
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=$work_dir/sing-box run -c $work_dir/config.json
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

    # 5. 重启并验证状态
    systemctl daemon-reload
    systemctl enable --now sing-box
    
    log "等待服务启动..."
    sleep 3
    if systemctl is-active --quiet sing-box; then
        log "✅ 服务已成功在 Ubuntu 上启动并运行！"
    else
        warn "❌ 服务未能运行，请执行: journalctl -u sing-box --no-pager -n 20"
        exit 1
    fi

    # 6. 生成二维码输出 (Reality)
    echo -e "\n\033[35m========== 最终配置详情 ==========\033[0m"
    local rel_url="vless://$uuid@$ip:443?security=reality&pbk=$pub&sni=www.apple.com&fp=chrome&type=tcp#Reality_Ubuntu"
    echo -e "Reality 链接: \033[36m$rel_url\033[0m"
    qrencode -t UTF8 "$rel_url"
}
uninstall() {
    log "正在卸载并恢复 Ubuntu 网络设置..."
    systemctl stop sing-box || true
    rm -rf "$work_dir" /etc/systemd/system/sing-box.service
    iptables -F && iptables -t nat -F && iptables -X
    log "✅ 卸载完成。"
}

if [[ "$1" == "uninstall" ]]; then uninstall; else prepare_env; create_user; install_singbox; setup_config; fi
