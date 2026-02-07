#!/bin/bash
set -e

# 配置
PORT=443
SNI="www.cloudflare.com"
WORK_DIR="/etc/sing-box"
BIN_PATH="$WORK_DIR/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

log() { echo -e "\033[32m[INFO]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }

# 检查 root
[[ $EUID -ne 0 ]] && error "请以 root 身份运行"

# 停止旧服务
systemctl stop sing-box 2>/dev/null || true
pkill -f sing-box 2>/dev/null || true

# 安装依赖
log "安装依赖..."
apt-get update -qq
apt-get install -y -qq curl wget tar openssl jq

# 获取公网 IPv4
IP=$(curl -s4m5 ip.sb || curl -s4m5 ifconfig.me)
[[ -z "$IP" ]] && error "无法获取公网 IPv4"

# 下载 sing-box
log "下载 sing-box..."
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${ARCH}.tar.gz"

mkdir -p "$WORK_DIR"
wget -qO /tmp/sb.tar.gz "$URL"
tar -xzf /tmp/sb.tar.gz -C /tmp
mv /tmp/sing-box-*-linux-*/sing-box "$BIN_PATH"
chmod +x "$BIN_PATH"
rm -rf /tmp/sb*

# 生成密钥
log "生成 Reality 密钥..."
KEYPAIR=$("$BIN_PATH" generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey:/ {print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/PublicKey:/ {print $2}')
UUID=$("$BIN_PATH" generate uuid)
SHORT_ID=$(openssl rand -hex 4)

# 写入配置
cat > "$WORK_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# systemd 服务
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box Reality Service
After=network.target

[Service]
ExecStart=$BIN_PATH run -c $WORK_DIR/config.json
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

# 生成分享链接
SHARE_LINK="vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#Reality-Test"

log "✅ 安装完成！"
echo
echo "🔗 分享链接："
echo "$SHARE_LINK"
echo
echo "📱 扫码（需支持 Reality 的客户端，如 Clash Meta）："
qrencode -t UTF8 "$SHARE_LINK" 2>/dev/null || echo "未安装 qrencode，可手动复制链接"
