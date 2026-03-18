#!/usr/bin/env bash
set -euo pipefail

#################################
# HELPERS & TRAP
#################################
trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускать нужно от root"

clear
echo "==================================================="
echo "    BRIDGE + NGINX SSL + BBR + AUTO-RENEW          "
echo "==================================================="

#################################
# ВВОД ДАННЫХ
#################################
read -p "Введите ваш ДОМЕН: " DOMAIN
read -p "Введите ваш EMAIL: " EMAIL
read -p "Введите IP удаленного сервера (Destination): " REMOTE_IP
read -p "Входящий порт для моста [8443]: " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-8443}

log "1. Подготовка системы и установка пакетов..."
apt update -qq && apt install -y nginx certbot python3-certbot-nginx ufw cron curl dnsutils

# Принудительно останавливаем Nginx и убираем старый конфиг, который мешает запуску
log "Очистка старых конфигураций Nginx..."
systemctl stop nginx || true
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

#################################
# 2. АКТИВАЦИЯ BBR
#################################
log "2. Активация BBR и оптимизация..."
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

#################################
# 3. РАБОТА С SSL
#################################
log "3. Получение SSL сертификата..."
CURRENT_IP=$(curl -s -4 ifconfig.me || echo "unknown")
RESOLVED_IP=$(dig +short "$DOMAIN" A | tail -n1)

ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null

if [[ "$RESOLVED_IP" == "$CURRENT_IP" ]]; then
    log "DNS совпадает. Используем Certbot..."
    # Используем standalone режим, так как Nginx мы временно выключили для чистоты
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || warn "Certbot не смог получить новый сертификат (возможно, он уже есть)."
    
    # Настройка автопродления
    if ! (crontab -l 2>/dev/null | grep -q "certbot renew"); then
        (crontab -l 2>/dev/null || echo ""; echo "0 0,12 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    fi
else
    warn "IP не совпадают. Создаем самоподписанный сертификат..."
    mkdir -p /etc/letsencrypt/live/"$DOMAIN"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/letsencrypt/live/"$DOMAIN"/privkey.pem \
        -out /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem \
        -subj "/CN=$DOMAIN" || true
fi

#################################
# 4. НАСТРОЙКА NGINX
#################################
log "4. Настройка Nginx заглушки (новая конфигурация)..."
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
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
mkdir -p /var/www/html
echo "<html><body style='background:#000;color:#222;text-align:center;padding-top:20%;font-family:sans-serif;'><h1>Server Online</h1></body></html>" > /var/www/html/index.html

# Проверяем конфиг перед запуском
nginx -t && systemctl start nginx || die "Nginx не смог запуститься даже с новым конфигом."

#################################
# 5. НАСТРОЙКА МОСТА (NAT)
#################################
log "5. Настройка моста :$LOCAL_PORT -> $REMOTE_IP:443..."
LOCAL_IP4=$(hostname -I | awk '{print $1}')

# Чистим before.rules от старых записей
cp /etc/ufw/before.rules /etc/ufw/before.rules.bak
sed -i '/\*nat/,/COMMIT/d' /etc/ufw/before.rules

# Генерируем новый блок NAT
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

# Сшиваем файлы
cat /tmp/ufw_rules /etc/ufw/before.rules > /etc/ufw/before.rules.new
mv /etc/ufw/before.rules.new /etc/ufw/before.rules

# Разрешаем форвардинг
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

ufw allow OpenSSH >/dev/null
ufw allow "$LOCAL_PORT"/tcp
ufw allow "$LOCAL_PORT"/udp
ufw --force enable
ufw reload

echo "---------------------------------------------------"
log "УСПЕШНО ЗАВЕРШЕНО"
echo "Домен: https://$DOMAIN"
echo "Мост: :$LOCAL_PORT -> $REMOTE_IP:443"
echo "---------------------------------------------------"
