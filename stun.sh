#!/usr/bin/env bash
set -euo pipefail

trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR
log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускать нужно от root"

clear
echo "==================================================="
echo "    BRIDGE + NGINX SSL + BBR + AUTO-RENEW          "
echo "==================================================="

read -p "Введите ваш ДОМЕН: " DOMAIN
read -p "Введите ваш EMAIL: " EMAIL
read -p "Введите IP удаленного сервера: " REMOTE_IP
read -p "Входящий порт для моста [8443]: " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-8443}

log "1. Установка пакетов..."
apt update -qq && apt install -y nginx certbot python3-certbot-nginx ufw cron curl dnsutils

log "2. Активация BBR..."
cat <<EOF > /etc/sysctl.d/99-bridge-performance.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.core.netdev_max_backlog = 250000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl --system >/dev/null

log "3. Работа с SSL..."
CURRENT_IP=$(curl -s -4 ifconfig.me || echo "unknown")
RESOLVED_IP=$(dig +short "$DOMAIN" A | tail -n1)

ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null

if [[ "$RESOLVED_IP" == "$CURRENT_IP" ]]; then
    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || true
    sleep 2
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    fi
else
    warn "Используем самоподписанный SSL (IP не совпали)"
    mkdir -p /etc/letsencrypt/live/"$DOMAIN"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/letsencrypt/live/"$DOMAIN"/privkey.pem \
        -out /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem \
        -subj "/CN=$DOMAIN" || true
fi

log "4. Настройка Nginx..."
cat <<EOF > /etc/nginx/sites-available/default
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
systemctl restart nginx

log "5. Настройка моста..."
LOCAL_IP4=$(hostname -I | awk '{print $1}')
cp /etc/ufw/before.rules /etc/ufw/before.rules.bak
sed -i '/\*nat/,/COMMIT/d' /etc/ufw/before.rules
cat <<EOF > /tmp/ufw_rules
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $REMOTE_IP:443
-A PREROUTING -p udp --dport $LOCAL_PORT -j DNAT --to-destination $REMOTE_IP:443
-A POSTROUTING -p tcp -d $REMOTE_IP --dport 443 -j SNAT --to-source $LOCAL_IP4
-A POSTROUTING -p udp -d $REMOTE_IP --dport 443 -j SNAT --to-source $LOCAL_IP4
COMMIT
EOF
cat /tmp/ufw_rules /etc/ufw/before.rules > /etc/ufw/before.rules.new
mv /etc/ufw/before.rules.new /etc/ufw/before.rules
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

ufw allow OpenSSH >/dev/null
ufw allow "$LOCAL_PORT"/tcp
ufw allow "$LOCAL_PORT"/udp
ufw --force enable
ufw reload

log "УСПЕШНО ЗАВЕРШЕНО"
