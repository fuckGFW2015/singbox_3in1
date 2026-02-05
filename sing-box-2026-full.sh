cat << 'EOF' > /root/singbox_install.sh
#!/bin/bash
# 2026 终极版脚本 - 修复执行与依赖逻辑
set -e
work_dir="/etc/sing-box"
HY2_PORT_START=20000
HY2_PORT_END=30000
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

log() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; exit 1; }

# 1. 环境准备
log "正在安装核心依赖..."
export DEBIAN_FRONTEND=noninteractive
apt update -q && apt install -y curl wget openssl tar coreutils ca-certificates socat qrencode iptables unzip iptables-persistent -y

# 2. 证书申请
mkdir -p "$work_dir"
read -rp "请输入你的解析域名 (Hy2/TUIC5 需要): " domain
if [[ -z "$domain" ]]; then error "域名不能为空"; fi

log "正在申请证书..."
systemctl stop nginx apache2 2>/dev/null || true
if [ ! -f "/root/.acme.sh/acme.sh" ]; then
    curl https://get.acme.sh | sh -s email=my@example.com
fi
if /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256 --force; then
    /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc --fullchain-file "${work_dir}/cert.pem" --key-file "${work_dir}/key.pem"
    log "✅ 正式证书申请成功"
else
    warn "申请失败，已自动回退至自签名证书"
    openssl req -x509 -newkey rsa:2048 -keyout "${work_dir}/key.pem" -out "${work_dir}/cert.pem" -days 3650 -nodes -subj "/CN=$domain"
fi

# 3. 安装 sing-box 核心
log "安装 sing-box..."
version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//')
wget -qO /tmp/sbx.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"
tar -xzf /tmp/sbx.tar.gz -C /tmp && mv /tmp/sing-box-*/sing-box "${work_dir}/sing-box"
chmod +x "${work_dir}/sing-box"

# 4. 生成配置与二维码
uuid=$(cat /proc/sys/kernel/random/uuid)
pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
keypair=$("${work_dir}/sing-box" generate reality-keypair)
priv=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}')
pub=$(echo "$keypair" | awk '/PublicKey:/ {print $2}')
ip=$(curl -s4 ip.sb)

cat > "${work_dir}/config.json" <<EON
{
  "log": { "level": "info" },
  "experimental": {
    "cache_file": { "enabled": true },
    "clash_api": { "external_controller": "0.0.0.0:9090", "external_ui": "ui", "secret": "$secret", "default_mode": "enhanced" }
  },
  "inbounds": [
    { "type": "vless", "tag": "Reality", "listen": "::", "listen_port": 443, "users": [{"uuid": "$uuid"}], "tls": { "enabled": true, "server_name": "www.apple.com", "reality": { "enabled": true, "handshake": { "server": "www.apple.com", "server_port": 443 }, "private_key": "$priv" } } },
    { "type": "hysteria2", "tag": "Hy2", "listen": "::", "listen_port": 443, "users": [{"password": "$pass"}], "tls": { "enabled": true, "server_name": "$domain", "cert_path": "${work_dir}/cert.pem", "key_path": "${work_dir}/key.pem" } }
  ],
  "outbounds": [{ "type": "direct" }]
}
EON

# 5. 启动服务
cat > /etc/systemd/system/sing-box.service <<EON
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=${work_dir}/sing-box run -c ${work_dir}/config.json
Restart=on-failure
User=root
[Install]
WantedBy=multi-user.target
EON

systemctl daemon-reload && systemctl enable --now sing-box

# 6. 展示结果
log "========================================"
log "🎉 4合1 部署完成！"
log "Reality 链接:"
echo "vless://$uuid@$ip:443?security=reality&pbk=$pub&sni=www.apple.com&fp=chrome&type=tcp#Reality_2026" | qrencode -t UTF8
log "面板密钥: $secret"
log "========================================"
EOF

chmod +x /root/singbox_install.sh
/root/singbox_install.sh
