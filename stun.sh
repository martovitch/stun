#!/usr/bin/env bash
set -euo pipefail

#################################
# HELPERS & TRAP
#################################
trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
die() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускать нужно от root (через sudo)"

clear
echo "==================================================="
echo "    BRIDGE + NGINX SSL + AUTO-RENEW SETUP         "
echo "==================================================="

#################################
# ВВОД ДАННЫХ
#################################
read -p "Введите ваш ДОМЕН (A-запись должна вести на этот IP): " DOMAIN
read -p "Введите ваш EMAIL (для Let's Encrypt): " EMAIL
read -p "Введите IP удаленного сервера (Destination): " REMOTE_IP

if [[ ! $REMOTE_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Некорректный формат IP адреса."
fi

read -p "Входящий порт на ЭТОМ сервере для моста [8443]: " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-8443}

log "1. Установка необходимых пакетов..."
apt update -qq && apt install -y nginx certbot python3-certbot-nginx ufw cron

#################################
# 2. ПОЛУЧЕНИЕ И АВТОПРОДЛЕНИЕ SSL
#################################
log "2. Получение SSL сертификата для $DOMAIN..."
# Открываем порты для проверки Certbot
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null

# Получаем сертификат
certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

# Добавляем принудительную задачу в Cron для проверки обновления дважды в сутки
# Certbot обновит его только если до конца срока менее 30 дней
if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    log "Задача на автопродление добавлена в crontab."
fi

#################################
# 3. НАСТРОЙКА NGINX (Заглушка)
#################################
log "3. Настройка Nginx заглушки на порту 443..."
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

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

echo "<html><body style='background:#000;color:#333;text-align:center;padding-top:20%;'><h1>System Online</h1></body></html>" > /var/www/html/index.html
systemctl restart nginx

#################################
# 4. НАСТРОЙКА МОСТА (NAT)
#################################
log "4. Настройка сетевого моста :$LOCAL_PORT -> $REMOTE_IP:443..."

# Включаем Forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-bridge.conf
sysctl --system >/dev/null

LOCAL_IP=$(hostname -I | awk '{print $1}')
cp /etc/ufw/before.rules /etc/ufw/before.rules.bak

# Очищаем старый NAT и записываем новый
sed -i '/\*nat/,/COMMIT/d' /etc/ufw/before.rules
cat <<EOF > /tmp/ufw_rules
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $REMOTE_IP:443
-A PREROUTING -p udp --dport $LOCAL_PORT -j DNAT --to-destination $REMOTE_IP:443
-A POSTROUTING -p tcp -d $REMOTE_IP --dport 443 -j SNAT --to-source $LOCAL_IP
-A POSTROUTING -p udp -d $REMOTE_IP --dport 443 -j SNAT --to-source $LOCAL_IP
COMMIT
EOF

cat /tmp/ufw_rules /etc/ufw/before.rules > /etc/ufw/before.rules.new
mv /etc/ufw/before.rules.new /etc/ufw/before.rules

# Разрешаем форвардинг в UFW
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

ufw allow OpenSSH >/dev/null
ufw allow "$LOCAL_PORT"/tcp
ufw allow "$LOCAL_PORT"/udp
ufw --force enable
ufw reload

echo "---------------------------------------------------"
log "УСПЕШНО ЗАВЕРШЕНО"
echo "Сайт: https://$DOMAIN"
echo "Мост: порт $LOCAL_PORT перенаправляет на $REMOTE_IP:443"
echo "Автопродление SSL: включено (проверка каждые 12 часов)"
echo "---------------------------------------------------"
