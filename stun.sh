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
echo "    BRIDGE + AUTO-UPGRADE SSL (ACME FIX)           "
echo "==================================================="

#################################
# ВВОД ДАННЫХ
#################################
read -p "Введите ваш ДОМЕН: " DOMAIN
read -p "Введите ваш EMAIL: " EMAIL
read -p "Введите IP удаленного сервера: " REMOTE_IP
read -p "Входящий порт для моста [8443]: " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-8443}

log "1. Подготовка системы..."
apt update -qq && apt install -y nginx certbot python3-certbot-nginx ufw cron curl dnsutils

systemctl stop nginx || true
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

#################################
# 2. АКТИВАЦИЯ BBR
#################################
log "2. Оптимизация сети (BBR)..."
cat <<EOF > /etc/sysctl.d/99-bridge-performance.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.all.route_localnet = 1
EOF
sysctl --system >/dev/null

#################################
# 3. НАСТРОЙКА SSL (C ПРОВЕРКОЙ БЛОКИРОВКИ)
#################################
log "3. Настройка SSL..."
CURRENT_IP=$(curl -s -4 ifconfig.me || echo "unknown")
RESOLVED_IP=$(dig +short "$DOMAIN" A | tail -n1)

mkdir -p "/etc/letsencrypt/live/$DOMAIN"

ISSUED=false
if [[ "$RESOLVED_IP" == "$CURRENT_IP" ]]; then
    log "DNS совпадает. Пробуем получить настоящий SSL..."
    if certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"; then
        log "Настоящий SSL успешно получен!"
        ISSUED=true
    else
        warn "ACME заблокирован или ошибка. Создаем временный самоподписанный SSL..."
    fi
fi

if [ "$ISSUED" = false ]; then
    # Создаем самоподписанный, только если нет настоящего
    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "/etc/letsencrypt/live/$DOMAIN/privkey.pem" \
            -out "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" \
            -subj "/CN=$DOMAIN"
    fi
fi

#################################
# 4. СОЗДАНИЕ СКРИПТА АВТО-ОБНОВЛЕНИЯ
#################################
log "4. Создание фонового обработчика для перехода на Let's Encrypt..."

cat <<EOF > /usr/local/bin/ssl-upgrade-check.sh
#!/bin/bash
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"

# Проверяем, является ли сертификат самоподписанным
# (Если в поле Issuer нет "Let's Encrypt", значит надо пробовать обновить)
if openssl x509 -in "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" -noout -issuer | grep -q "Let's Encrypt"; then
    # Если сертификат уже настоящий, просто запускаем стандартное продление
    certbot renew --quiet --post-hook "systemctl reload nginx"
else
    # Если все еще самоподписанный, пытаемся получить настоящий
    if certbot certonly --nginx -d "\$DOMAIN" --non-interactive --agree-tos -m "\$EMAIL"; then
        systemctl reload nginx
    fi
fi
EOF

chmod +x /usr/local/bin/ssl-upgrade-check.sh

# Добавляем в cron проверку каждые 12 часов
if ! (crontab -l 2>/dev/null | grep -q "ssl-upgrade-check.sh"); then
    (crontab -l 2>/dev/null || echo ""; echo "0 */12 * * * /usr/local/bin/ssl-upgrade-check.sh > /dev/null 2>&1") | crontab -
fi

#################################
# 5. НАСТРОЙКА NGINX И МОСТА
#################################
log "5. Финальная настройка Nginx и NAT..."
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
echo "<html><body style='background:#111;color:#333;text-align:center;padding-top:20%;font-family:sans-serif;'><h1>Server Online</h1><p>Secure Bridge Active</p></body></html>" > /var/www/html/index.html

systemctl start nginx

# Настройка NAT (UFW)
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

echo "---------------------------------------------------"
log "УСТАНОВКА ЗАВЕРШЕНА"
echo "Мост работает через порт $LOCAL_PORT"
echo "SSL: Временный (самоподписанный). Авто-замена на Let's Encrypt включена."
echo "---------------------------------------------------"
