# 1. 环境清理：强行杀掉占用 443 端口的所有进程
echo "清理端口占用中..."
fuser -k 443/tcp 443/udp 8443/udp 2>/dev/null || true
systemctl stop nginx apache2 2>/dev/null || true

# 2. 安装必备组件
apt update && apt install -y curl qrencode unzip socat tar coreutils

# 3. 变量定义
work_dir="/etc/sing-box"
mkdir -p "$work_dir"
read -p "请输入你的解析域名 (Hy2/TUIC5 需要): " domain
uuid=$(cat /proc/sys/kernel/random/uuid)
pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
ip=$(curl -s4 ip.sb)

# 4. 下载并安装 sing-box 核心
arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
tag=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -Lo /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$tag/sing-box-${tag#v}-linux-$arch.tar.gz"
tar -xzf /tmp/sb.tar.gz -C /tmp
mv /tmp/sing-box-*/sing-box "$work_dir/sing-box"
chmod +x "$work_dir/sing-box"

# 5. Reality 密钥对生成
keypair=$("$work_dir/sing-box" generate reality-keypair)
priv=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}')
pub=$(echo "$keypair" | awk '/PublicKey:/ {print $2}')

# 6. 证书处理 (简单自签名，确保脚本 100% 跑通)
openssl req -x509 -newkey rsa:2048 -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" -days 3650 -nodes -subj "/CN=$domain"

# 7. 写入 4合一 配置文件
cat <<EOF > "$work_dir/config.json"
{
  "log": { "level": "info" },
  "experimental": {
    "cache_file": { "enabled": true },
    "clash_api": { "external_controller": "0.0.0.0:9090", "external_ui": "ui", "secret": "$secret" }
  },
  "inbounds": [
    { "type": "vless", "tag": "Reality", "listen": "::", "listen_port": 443, "users": [{"uuid": "$uuid"}], "tls": { "enabled": true, "server_name": "www.apple.com", "reality": { "enabled": true, "handshake": { "server": "www.apple.com", "server_port": 443 }, "private_key": "$priv" } } },
    { "type": "hysteria2", "tag": "Hy2", "listen": "::", "listen_port": 443, "users": [{"password": "$pass"}], "tls": { "enabled": true, "server_name": "$domain", "cert_path": "$work_dir/cert.pem", "key_path": "$work_dir/key.pem" } },
    { "type": "tuic", "tag": "TUIC5", "listen": "::", "listen_port": 8443, "users": [{"uuid": "$uuid", "password": "$pass"}], "tls": { "enabled": true, "server_name": "$domain", "cert_path": "$work_dir/cert.pem", "key_path": "$work_dir/key.pem" } },
    { "type": "vmess", "tag": "Argo-In", "listen": "127.0.0.1", "listen_port": 8080, "users": [{"uuid": "$uuid"}] }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

# 8. 启动 sing-box 服务
cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=$work_dir/sing-box run -c $work_dir/config.json
Restart=on-failure
User=root
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable --now sing-box

# 9. 打印 4合一 结果
echo -e "\n\033[32m--- 2026 旗舰版 4合一部署成功 ---\033[0m"
echo "1. Reality (TCP 443):"
link="vless://$uuid@$ip:443?security=reality&pbk=$pub&sni=www.apple.com&fp=chrome&type=tcp#Reality_2026"
echo "$link"
echo "$link" | qrencode -t UTF8
echo -e "\n2. Hy2 (UDP 443): hysteria2://$pass@$ip:443?sni=$domain#Hy2_2026"
echo "3. TUIC5 (UDP 8443): tuic://$uuid:$pass@$ip:8443?sni=$domain&alpn=h3#TUIC5_2026"
echo "4. Argo: 监听 127.0.0.1:8080 (请自行绑定 cloudflared)"
echo -e "\n📊 面板地址: http://$ip:9090/ui  密钥: $secret"
