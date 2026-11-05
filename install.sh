#!/usr/bin/env bash
# Version 1.1: automated fresh-server setup for Ubuntu 24.04: AWG 3.1 + HTTPS web panel.
# Run locally on VPS as root: bash install.sh
set -Eeuo pipefail
umask 077
STATE_DIR=/var/lib/awg31-autosetup
CONFIG="$STATE_DIR/config"
SCRIPT_PATH=/usr/local/sbin/awg31-autosetup
SERVICE=/etc/systemd/system/awg31-autosetup.service
LOG=/var/log/awg31-autosetup.log
REPO=https://github.com/wiresock/awg-server-tools.git
# Upstream commit verified 2026-11-05. Update deliberately, never track moving main.
UPSTREAM_COMMIT=1e0b321f9b481ab21ee68ca709c5ca84ab68041f
fail(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
validate_email() {
  # ACME contact URI must be ASCII; reject Cyrillic input-method accidents.
  [[ ${EMAIL:-} =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
    fail 'Invalid ASCII email for Lets Encrypt. Use Latin letters only; correct EMAIL in root-only saved config before resuming.'
}
trap 'rc=$?; echo "FAILED at line $LINENO (exit $rc). See $LOG or journalctl -u awg31-autosetup. Once fixed: systemctl restart awg31-autosetup" >&2' ERR
[[ $EUID == 0 ]] || fail 'Run as root.'
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || fail 'Requires Ubuntu 24.04.'
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1

# Do not depend on inherited stdin for interactive prompts: ssh/terminal clients
# may close that stream even while the controlling TTY remains available.
prompt_input() {
  local name="$1" prompt="$2" answer
  [[ -r /dev/tty && -w /dev/tty ]] || fail 'No controlling terminal; connect via interactive SSH.'
  if ! IFS= read -r -p "$prompt" answer </dev/tty; then
    fail "Input interrupted: $prompt"
  fi
  printf -v "$name" '%s' "$answer"
}
prompt_secret() {
  local name="$1" prompt="$2" answer
  [[ -r /dev/tty && -w /dev/tty ]] || fail 'No controlling terminal; connect via interactive SSH.'
  if ! IFS= read -r -s -p "$prompt" answer </dev/tty; then
    printf '\n' >/dev/tty
    fail 'Password input interrupted. Installation has not started.'
  fi
  printf '\n' >/dev/tty
  printf -v "$name" '%s' "$answer"
}
# A 1 GiB VPS needs swap before kernel packages and Rust builds.
ensure_build_swap() {
  local mem_kib swap_kib free_kib build_swap
  mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  swap_kib=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
  if (( mem_kib >= 1572864 || swap_kib >= 2097152 )); then return 0; fi

  # A fresh VPS can already have its own /swapfile (often just 1 GiB).
  # Never modify or reformat it. Use an installer-owned swap file instead.
  build_swap="$STATE_DIR/build.swap"
  if [[ ! -e "$build_swap" ]]; then
    free_kib=$(df -Pk "$STATE_DIR" | awk 'NR==2 {print $4}')
    (( free_kib >= 6291456 )) || fail 'Less than 6 GiB disk space free. Need space for a 2 GiB build swap and Rust compilation.'
    log 'Low RAM detected: allocating dedicated 2 GiB build swap without touching existing /swapfile'
  else
    [[ -f "$build_swap" && ! -L "$build_swap" ]] || fail 'Dedicated build.swap is not a regular file.'
    [[ $(stat -c %u "$build_swap") == 0 ]] || fail 'Dedicated build.swap must be owned by root.'
  fi
  if ! swapon --noheadings --raw --show=NAME | grep -Fxq "$build_swap"; then
    # Reinitialize only the dedicated (and currently inactive) file.
    # This is also safe after a previous interrupted fallocate/mkswap.
    fallocate -l 2G "$build_swap"
    chmod 600 "$build_swap"
    mkswap "$build_swap" >/dev/null
    swapon "$build_swap"
  fi
  grep -Eq '^[[:space:]]*/var/lib/awg31-autosetup/build[.]swap[[:space:]]' /etc/fstab ||
    printf '%s none swap sw 0 0\n' "$build_swap" >> /etc/fstab
  log 'Dedicated build swap enabled; existing swap files preserved'
}

if [[ ${1:-} == --resume ]]; then
  [[ -f $CONFIG ]] || fail 'Setup config not found.'
  [[ $(stat -c %a "$CONFIG") == 600 && $(stat -c %u "$CONFIG") == 0 ]] || fail 'Setup config permissions/ownership unsafe.'
  # config is generated only by this script, owned by root, with escaped values.
  source "$CONFIG"
  validate_email
else
  [[ ! -e $CONFIG ]] || fail "Installation already initialized. Check systemctl status awg31-autosetup."
  [[ ! -e /etc/amnezia/amneziawg/awg0.conf ]] || fail 'Existing AWG installation detected; refusing overwrite.'
  [[ ! -e /etc/amneziawg-web/env.conf ]] || fail 'Existing web panel detected; refusing overwrite.'
  [[ ! -e /etc/nginx/sites-available/awg31 ]] || fail 'Existing awg31 nginx configuration detected; refusing overwrite.'
  echo '=== New Ubuntu 24.04 VPS: AWG 3.1 + HTTPS Web ==='
  prompt_input PUBLIC_IP 'Public IPv4 (Enter = detect automatically): '
  if [[ -z $PUBLIC_IP ]]; then
    command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl ca-certificates; }
    PUBLIC_IP=$(curl -fsS4 --max-time 15 https://api.ipify.org) || fail 'IPv4 autodetection failed'
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    apt-get update
    apt-get install -y python3
  fi
  python3 - "$PUBLIC_IP" <<'PY' || fail 'Invalid public IPv4'
import ipaddress,sys
x=ipaddress.ip_address(sys.argv[1]); assert x.version == 4 and x.is_global
PY
  prompt_input AWG_PORT 'AmneziaWG UDP port [585]: '
  AWG_PORT=${AWG_PORT:-585}
  [[ $AWG_PORT =~ ^[0-9]+$ ]] && ((AWG_PORT>=1 && AWG_PORT<=65535)) || fail 'Invalid UDP port'
  prompt_input EMAIL "Email for Let's Encrypt notices: "
  validate_email
  prompt_input ADMIN_USER 'Web panel username [admin]: '
  ADMIN_USER=${ADMIN_USER:-admin}
  [[ $ADMIN_USER =~ ^[a-zA-Z0-9_.-]{1,32}$ ]] || fail 'Invalid username'
  prompt_secret ADMIN_PASS 'Web panel password (min 6 characters): '
  [[ ${#ADMIN_PASS} -ge 6 ]] || fail 'Password too short.'
  prompt_secret ADMIN_PASS_2 'Repeat password: '
  [[ $ADMIN_PASS == "$ADMIN_PASS_2" ]] || fail 'Passwords do not match.'
  unset ADMIN_PASS_2
  echo 'Ports required at your hosting provider: 22/TCP, 80/TCP, 443/TCP and the chosen AWG UDP port.'
  echo 'The script cannot change the external provider firewall or prove UDP accessibility from Russia.'
  prompt_input CONFIRM 'Start unattended installation, including an automatic reboot? [y/N]: '
  [[ $CONFIRM == y || $CONFIRM == Y ]] || exit 0
  export DEBIAN_FRONTEND=noninteractive
  ensure_build_swap
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
  # After reboot, systemd runs the installed copy, not a GitHub checkout.
  cat > "$SERVICE" <<'UNIT'
[Unit]
Description=Complete unattended AmneziaWG 3.1 setup after boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/awg31-autosetup/config
[Service]
Type=oneshot
Environment=HOME=/root
WorkingDirectory=/root
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

# systemd does not reliably supply HOME for oneshot services; rustup needs it.
export HOME=/root
export PATH="/root/.cargo/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive
# Guard against hosts whose swap was removed before resuming.
ensure_build_swap
export CARGO_BUILD_JOBS=1
export CARGO_INCREMENTAL=0
log 'Resuming installation after reboot'
[[ -e /lib/modules/$(uname -r)/build ]] || fail "Headers missing for running kernel $(uname -r)"
cd /root
# Resume safely if a prior git fetch/checkout was interrupted.
UPSTREAM_DIR=/opt/awg-server-tools
if [[ ! -d $UPSTREAM_DIR/.git ]]; then
  [[ ! -e $UPSTREAM_DIR ]] || fail 'Non-git upstream directory exists; inspect manually.'
  mkdir -p "$UPSTREAM_DIR"
  git -C "$UPSTREAM_DIR" init -q
fi
# An interrupted init may have created .git before 'remote add origin'.
if ! git -C "$UPSTREAM_DIR" remote get-url origin >/dev/null 2>&1; then
  git -C "$UPSTREAM_DIR" remote add origin "$REPO"
fi
[[ $(git -C "$UPSTREAM_DIR" remote get-url origin) == "$REPO" ]] || fail 'Unexpected upstream origin URL.'
if [[ $(git -C "$UPSTREAM_DIR" rev-parse HEAD 2>/dev/null || true) != "$UPSTREAM_COMMIT" ]]; then
  log 'Fetching pinned upstream commit (safe to retry)'
  git -C "$UPSTREAM_DIR" fetch --depth 1 origin "$UPSTREAM_COMMIT"
  git -C "$UPSTREAM_DIR" checkout -q --detach FETCH_HEAD
fi
[[ $(git -C "$UPSTREAM_DIR" rev-parse HEAD) == "$UPSTREAM_COMMIT" ]] || fail 'Upstream checkout SHA mismatch.'
[[ -f /opt/awg-server-tools/amneziawg-install.sh && -f /opt/awg-server-tools/amneziawg-web.sh ]] || fail 'Pinned upstream files missing.'
# Deliberately refresh the local lifecycle installer from the pinned checkout.
install -m 700 /opt/awg-server-tools/amneziawg-install.sh /root/amneziawg-install.sh
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
[[ -e "$PARAMS.pre-autosetup.bak" ]] || cp -a "$PARAMS" "$PARAMS.pre-autosetup.bak"
[[ -e "$AWG_CONF.pre-autosetup.bak" ]] || cp -a "$AWG_CONF" "$AWG_CONF.pre-autosetup.bak"
# Preserve the originally generated S4: upstream used it to compute server/client MTU.
# Changing S4 here could cause fragmentation or stale CLIENT_MTU defaults.
S_VALUE=$(sed -nE 's/^[[:space:]]*S4[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$AWG_CONF")
[[ $S_VALUE =~ ^[0-9]+$ ]] && (( S_VALUE >= 0 && S_VALUE <= 128 )) || fail 'Invalid S4; refusing MTU-unsafe padding rewrite.'
for i in 1 2 3 4; do
  grep -qE "^S${i}[[:space:]]*=" "$AWG_CONF" || fail "S${i} missing; inspect config before changing padding."
done
log "Aligning S1-S4 with original S4=$S_VALUE (preserving MTU budget)"
for i in 1 2 3 4; do
  if grep -q "^SERVER_AWG_S${i}=" "$PARAMS"; then
    sed -i -E "s/^SERVER_AWG_S${i}=.*/SERVER_AWG_S${i}=$S_VALUE/" "$PARAMS"
  else
    printf 'SERVER_AWG_S%s=%s\n' "$i" "$S_VALUE" >> "$PARAMS"
  fi
  sed -i -E "s/^S${i}[[:space:]]*=.*/S${i} = $S_VALUE/" "$AWG_CONF"
done
systemctl enable --now awg-quick@awg0
systemctl restart awg-quick@awg0
systemctl is-active --quiet awg-quick@awg0 || fail 'AWG service inactive'

log 'Installing web control panel'
# Restart/resume partial panel installation even if env.conf was written before failure.
# Upstream non-interactive mode preserves an existing env file unless --force is set.
if [[ ! -s /etc/amneziawg-web/env.conf ||
      ! -x /usr/local/bin/amneziawg-web ||
      ! -f /etc/systemd/system/amneziawg-web.service ]]; then
  log 'Installing or repairing incomplete web panel'
  bash /opt/awg-server-tools/amneziawg-web.sh install \
    --non-interactive --install-rust \
    --source-dir /opt/awg-server-tools/amneziawg-web \
    --username "$ADMIN_USER" --password-hash "$ADMIN_HASH" \
    --host 127.0.0.1 --port 8080
fi
[[ -s /etc/amneziawg-web/env.conf &&
   -x /usr/local/bin/amneziawg-web &&
   -f /etc/systemd/system/amneziawg-web.service ]] || fail 'Web panel installation incomplete.'
grep -Fxq 'AWG_WEB_LISTEN=127.0.0.1:8080' /etc/amneziawg-web/env.conf || fail 'Web panel listen address differs from expected localhost bind.'
grep -Fxq 'AUTH_ENABLED=true' /etc/amneziawg-web/env.conf || fail 'Web panel authentication is not enabled.'
grep -Fxq "AUTH_USERNAME=$ADMIN_USER" /etc/amneziawg-web/env.conf || fail 'Web panel username differs from requested username.'
grep -Fxq "AUTH_PASSWORD_HASH=$ADMIN_HASH" /etc/amneziawg-web/env.conf || fail 'Web panel password hash differs from the originally entered password.'
if grep -q '^AUTH_SECURE_COOKIE=' /etc/amneziawg-web/env.conf; then
  sed -i 's/^AUTH_SECURE_COOKIE=.*/AUTH_SECURE_COOKIE=true/' /etc/amneziawg-web/env.conf
else
  echo 'AUTH_SECURE_COOKIE=true' >> /etc/amneziawg-web/env.conf
fi
systemctl restart amneziawg-web
# systemctl restart returning does not guarantee socket readiness.
log 'Waiting for web panel to listen on 127.0.0.1:8080'
PANEL_READY=false
for attempt in $(seq 1 30); do
  if ss -H -lnt | awk '$4 == "127.0.0.1:8080" { found=1 } END { exit !found }'; then
    PANEL_READY=true
    break
  fi
  systemctl is-active --quiet amneziawg-web || break
  sleep 1
done
if [[ $PANEL_READY != true ]]; then
  systemctl status amneziawg-web --no-pager || true
  journalctl -u amneziawg-web -n 35 --no-pager || true
  fail 'Web panel not listening on localhost:8080 after startup; see service logs above.'
fi

log 'Configuring nginx ACME HTTP challenge'
mkdir -p /var/www/html/.well-known/acme-challenge
# umask 077 makes newly created directories 0700. nginx's unprivileged
# worker must traverse both directories to serve ACME HTTP-01 challenges.
chmod 755 /var/www/html/.well-known /var/www/html/.well-known/acme-challenge
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
# Certbot snap normally supplies automatic renewal. Fail closed if its timer is missing.
if ! systemctl list-timers --all --no-legend | grep -Eq '(snap\.certbot\.renew|certbot\.timer)'; then
  fail 'Certbot renewal timer not found: configure renewal before publishing the panel.'
fi
nginx -t
systemctl reload nginx
systemctl is-active --quiet nginx || fail 'nginx inactive'
# Verify local HTTPS (independent of whether upstream network allows access).
curl -fsSI --resolve "${PUBLIC_IP}:443:127.0.0.1" "https://${PUBLIC_IP}/" >/dev/null || fail 'HTTPS local check failed'
# Basic checks, do not mistake these for an external reachability test.
PROTO_STATUS=$(/root/amneziawg-install.sh --protocol-status)
printf '%s\n' "$PROTO_STATUS"
printf '%s\n' "$PROTO_STATUS" | grep -Eq '(^|[^0-9])3\.1([^0-9]|$)' || fail 'AWG 3.1 is not enabled.'
awg show
ss -H -lun | awk -v port="$AWG_PORT" '$4 ~ (":" port "$") { found=1 } END { exit !found }' || fail 'AWG UDP listening socket not found'
ss -H -lnt | awk '$4 ~ /^127\.0\.0\.1:8080$/ { found=1 } END { exit !found }' || fail 'Panel bind check failed'
systemctl disable awg31-autosetup.service
rm -f "$CONFIG"
printf '%s\n' "$UPSTREAM_COMMIT" > "$STATE_DIR/upstream-commit"
chmod 600 "$STATE_DIR/upstream-commit"
log "SUCCESS: web panel https://${PUBLIC_IP}/ ; login ${ADMIN_USER}; AWG UDP port ${AWG_PORT}"
log 'NEXT: confirm provider firewall allows 80/TCP, 443/TCP, AWG UDP, and test client handshake externally.'
