#!/usr/bin/env bash
# Automated fresh-server setup for Ubuntu 24.04: AWG 3.1 + HTTPS web panel.
# Run locally on VPS as root: bash install-amneziawg31-auto.sh
set -Eeuo pipefail
umask 077
STATE_DIR=/var/lib/awg31-autosetup
CONFIG="$STATE_DIR/config"
SCRIPT_PATH=/usr/local/sbin/awg31-autosetup
SERVICE=/etc/systemd/system/awg31-autosetup.service
LOG=/var/log/awg31-autosetup.log
REPO=https://github.com/wiresock/awg-server-tools.git
RAW=https://raw.githubusercontent.com/wiresock/awg-server-tools/main
fail(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
trap 'rc=$?; echo "FAILED at line $LINENO (exit $rc). See $LOG or journalctl -u awg31-autosetup" >&2' ERR
[[ $EUID == 0 ]] || fail 'Run as root.'
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || fail 'Requires Ubuntu 24.04.'
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1

if [[ ${1:-} == --resume ]]; then
  [[ -f $CONFIG ]] || fail 'Setup config not found.'
  # config is generated only by this script, owned by root, with escaped values.
  source "$CONFIG"
else
  [[ ! -e $CONFIG ]] || fail "Installation already initialized. Check systemctl status awg31-autosetup."
  [[ ! -e /etc/amnezia/amneziawg/awg0.conf ]] || fail 'Existing AWG installation detected; refusing overwrite.'
  [[ ! -e /etc/amneziawg-web/env.conf ]] || fail 'Existing web panel detected; refusing overwrite.'
  echo '=== New Ubuntu 24.04 VPS: AWG 3.1 + HTTPS Web ==='
  read -r -p 'Public IPv4 (Enter = detect automatically): ' PUBLIC_IP
  if [[ -z $PUBLIC_IP ]]; then
    command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl ca-certificates; }
    PUBLIC_IP=$(curl -fsS4 --max-time 15 https://api.ipify.org) || fail 'IPv4 autodetection failed'
  fi
  python3 - "$PUBLIC_IP" <<'PY' || fail 'Invalid public IPv4'
import ipaddress,sys
x=ipaddress.ip_address(sys.argv[1]); assert x.version == 4 and x.is_global
PY
  read -r -p 'AmneziaWG UDP port [585]: ' AWG_PORT
  AWG_PORT=${AWG_PORT:-585}
  [[ $AWG_PORT =~ ^[0-9]+$ ]] && ((AWG_PORT>=1 && AWG_PORT<=65535)) || fail 'Invalid UDP port'
  read -r -p "Email for Let's Encrypt notices: " EMAIL
  [[ $EMAIL == *@*.* ]] || fail 'Valid email required.'
  read -r -p 'Web panel username [admin]: ' ADMIN_USER
  ADMIN_USER=${ADMIN_USER:-admin}
  [[ $ADMIN_USER =~ ^[a-zA-Z0-9_.-]{1,32}$ ]] || fail 'Invalid username'
  read -r -s -p 'Web panel password (min 16 characters): ' ADMIN_PASS; echo
  [[ ${#ADMIN_PASS} -ge 16 ]] || fail 'Password too short.'
  read -r -s -p 'Repeat password: ' ADMIN_PASS_2; echo
  [[ $ADMIN_PASS == "$ADMIN_PASS_2" ]] || fail 'Passwords do not match.'
  unset ADMIN_PASS_2
  echo 'Ports required at your hosting provider: 22/TCP, 80/TCP, 443/TCP and the chosen AWG UDP port.'
  echo 'The script cannot change the external provider firewall or prove UDP accessibility from Russia.'
  read -r -p 'Start unattended installation, including an automatic reboot? [y/N]: ' CONFIRM
  [[ $CONFIRM == y || $CONFIRM == Y ]] || exit 0
  export DEBIAN_FRONTEND=noninteractive
  log 'Installing prerequisites and new kernel/header packages'
  apt-get update
  apt-get install -y linux-image-generic linux-headers-generic curl ca-certificates git build-essential libc6-dev pkg-config libssl-dev python3-argon2 zstd python3 nginx snapd tcpdump
  ADMIN_HASH=$(ADMIN_PASS="$ADMIN_PASS" python3 - <<'PY'
import os
from argon2 import PasswordHasher
print(PasswordHasher().hash(os.environ['ADMIN_PASS']))
PY
)
  unset ADMIN_PASS
  {
    printf 'PUBLIC_IP=%q\n' "$PUBLIC_IP"
    printf 'AWG_PORT=%q\n' "$AWG_PORT"
    printf 'EMAIL=%q\n' "$EMAIL"
    printf 'ADMIN_USER=%q\n' "$ADMIN_USER"
    printf 'ADMIN_HASH=%q\n' "$ADMIN_HASH"
  } > "$CONFIG"
  chmod 600 "$CONFIG"
  install -m 700 "$(realpath "$0")" "$SCRIPT_PATH"
  cat > "$SERVICE" <<'UNIT'
[Unit]
Description=Complete unattended AmneziaWG 3.1 setup after boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/awg31-autosetup/config
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/awg31-autosetup --resume
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable awg31-autosetup.service
  log 'First phase complete; rebooting to load matching kernel headers.'
  systemctl reboot
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
log 'Resuming installation after reboot'
[[ -e /lib/modules/$(uname -r)/build ]] || fail "Headers missing for running kernel $(uname -r)"
cd /root
if [[ ! -f /root/amneziawg-install.sh ]]; then
  curl -fL --retry 3 "$RAW/amneziawg-install.sh" -o /root/amneziawg-install.sh
  chmod 700 /root/amneziawg-install.sh
fi
if [[ ! -f /etc/amnezia/amneziawg/awg0.conf ]]; then
  log 'Installing AmneziaWG'
  AUTO_INSTALL=y SERVER_PUB_IP="$PUBLIC_IP" SERVER_PORT="$AWG_PORT" ENABLE_IPV6=n CLIENT_DNS_1=1.1.1.1 CLIENT_DNS_2=1.0.0.1 CREATE_INITIAL_CLIENT=no /root/amneziawg-install.sh
fi
modprobe amneziawg
if ! /root/amneziawg-install.sh --protocol-status | grep -Eq '(^|[^0-9])3\.1([^0-9]|$)'; then
  log 'Enabling AWG 3.1'
  AUTO_INSTALL=y /root/amneziawg-install.sh --enable-awg31
fi
PARAMS=/etc/amnezia/amneziawg/params
AWG_CONF=/etc/amnezia/amneziawg/awg0.conf
[[ -f $PARAMS && -f $AWG_CONF ]] || fail 'AWG configuration missing.'
cp -a "$PARAMS" "$PARAMS.pre-autosetup.bak"
cp -a "$AWG_CONF" "$AWG_CONF.pre-autosetup.bak"
for i in 1 2 3 4; do
  if grep -q "^SERVER_AWG_S${i}=" "$PARAMS"; then
    sed -i -E "s/^SERVER_AWG_S${i}=.*/SERVER_AWG_S${i}=54/" "$PARAMS"
  else
    printf 'SERVER_AWG_S%s=54\n' "$i" >> "$PARAMS"
  fi
  if grep -qE "^S${i}[[:space:]]*=" "$AWG_CONF"; then
    sed -i -E "s/^S${i}[[:space:]]*=.*/S${i} = 54/" "$AWG_CONF"
  else
    fail "S${i} not found in AWG config; manual inspection required."
  fi
done
systemctl enable --now awg-quick@awg0
systemctl restart awg-quick@awg0
systemctl is-active --quiet awg-quick@awg0 || fail 'AWG service inactive'

log 'Installing web control panel'
if [[ ! -f /etc/amneziawg-web/env.conf ]]; then
  if [[ ! -d /opt/awg-server-tools/.git ]]; then
    [[ ! -e /opt/awg-server-tools ]] || fail "Existing /opt/awg-server-tools is not a git repository"
    git clone --depth 1 "$REPO" /opt/awg-server-tools
  fi
  bash /opt/awg-server-tools/amneziawg-web.sh install \
    --non-interactive --install-rust \
    --source-dir /opt/awg-server-tools/amneziawg-web \
    --username "$ADMIN_USER" --password-hash "$ADMIN_HASH" \
    --host 127.0.0.1 --port 8080
fi
if grep -q '^AUTH_SECURE_COOKIE=' /etc/amneziawg-web/env.conf; then
  sed -i 's/^AUTH_SECURE_COOKIE=.*/AUTH_SECURE_COOKIE=true/' /etc/amneziawg-web/env.conf
else
  echo 'AUTH_SECURE_COOKIE=true' >> /etc/amneziawg-web/env.conf
fi
systemctl restart amneziawg-web
systemctl is-active --quiet amneziawg-web || fail 'Web panel inactive'
ss -lnt | grep -Eq '127\.0\.0\.1:8080[[:space:]]' || fail 'Web panel not bound to localhost:8080'

log 'Configuring nginx ACME HTTP challenge'
mkdir -p /var/www/html/.well-known/acme-challenge
cat >/etc/nginx/sites-available/awg31 <<EOF
server {
    listen 80 default_server;
    server_name ${PUBLIC_IP};
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sfn /etc/nginx/sites-available/awg31 /etc/nginx/sites-enabled/awg31
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx

log 'Installing recent Certbot via snap'
systemctl enable --now snapd.socket
snap wait system seed.loaded
if ! snap list certbot &>/dev/null; then
  snap install core
  snap install --classic certbot
fi
ln -sfn /snap/bin/certbot /usr/local/bin/certbot
CERTBOT_VERSION=$(certbot --version 2>&1 | awk '{print $2}')
python3 - "$CERTBOT_VERSION" <<'PY' || fail 'Certbot 5.4+ required'
import sys
v=[int(x) for x in sys.argv[1].split('.')[:2]]
assert v >= [5,4]
PY
log 'Obtaining short-lived Lets Encrypt IP certificate'
certbot certonly --non-interactive --agree-tos --email "$EMAIL" \
  --preferred-profile shortlived --webroot --webroot-path /var/www/html \
  --ip-address "$PUBLIC_IP" --keep-until-expiring
[[ -s /etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem ]] || fail 'Certificate missing'
cat >/etc/nginx/sites-available/awg31 <<EOF
server {
    listen 80 default_server;
    server_name ${PUBLIC_IP};
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    server_name ${PUBLIC_IP};
    ssl_certificate /etc/letsencrypt/live/${PUBLIC_IP}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PUBLIC_IP}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 10s;
        proxy_read_timeout 60s;
    }
}
EOF
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/sh
/usr/bin/systemctl reload nginx
HOOK
chmod 700 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
nginx -t
systemctl reload nginx
systemctl is-active --quiet nginx || fail 'nginx inactive'
# Verify local HTTPS (independent of whether upstream network allows access).
curl -fsSI --resolve "${PUBLIC_IP}:443:127.0.0.1" "https://${PUBLIC_IP}/" >/dev/null || fail 'HTTPS local check failed'
# Basic checks, do not mistake these for an external reachability test.
/root/amneziawg-install.sh --protocol-status
awg show
ss -lun | grep -F ":${AWG_PORT}" || fail 'AWG UDP listening socket not found'
ss -lnt | grep -F '127.0.0.1:8080' || fail 'Panel bind check failed'
systemctl disable awg31-autosetup.service
rm -f "$CONFIG"
log "SUCCESS: web panel https://${PUBLIC_IP}/ ; login ${ADMIN_USER}; AWG UDP port ${AWG_PORT}"
log 'NEXT: confirm provider firewall allows 80/TCP, 443/TCP, AWG UDP, and test client handshake externally.'
