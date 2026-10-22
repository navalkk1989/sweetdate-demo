#!/usr/bin/env bash
# =====================================================================
#  SweetDate — one-command setup on a FREE Oracle Cloud server (Ubuntu)
#  Installs: Node.js, the website, nginx, free HTTPS (Let's Encrypt),
#  call server (TURN), auto-update from GitHub every 2 minutes,
#  daily database backup, auto-restart after crash or reboot.
#
#  Run on the server:
#     curl -fsSL -H "Authorization: token <GITHUB_TOKEN>" https://raw.githubusercontent.com/<you>/sweetdate/main/deploy/oracle-setup.sh -o setup.sh
#     sudo bash setup.sh
#  Safe to run again (it updates instead of re-installing).
# =====================================================================
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Please run with sudo:  sudo bash $0"; exit 1; }

APP_DIR=/opt/sweetdate
DATA_DIR=/var/sweetdate
DOMAIN_DEFAULT=sweetdate.in
G='\033[1;32m'; Y='\033[1;33m'; N='\033[0m'
say(){ echo -e "\n${G}==> $*${N}"; }

# ---------- questions (only first time) ----------
CONF=/etc/sweetdate-setup.conf
[ -f $CONF ] && . $CONF
if [ -z "${GH_REPO:-}" ]; then
  echo -e "${Y}A few questions (only asked once):${N}"
  read -rp "1) Your domain [${DOMAIN_DEFAULT}]: " DOMAIN; DOMAIN=${DOMAIN:-$DOMAIN_DEFAULT}
  read -rp "2) GitHub username (e.g. navalkk1989): " GH_USER
  read -rp "3) GitHub repository name [sweetdate]: " GH_NAME; GH_NAME=${GH_NAME:-sweetdate}
  read -rsp "4) GitHub token (read-only, starts with github_pat_ ... — text stays hidden): " GH_TOKEN; echo
  read -rsp "5) Choose the ADMIN password for sweetdate.in/admin (min 8 chars, hidden): " ADMIN_PASSWORD; echo
  read -rp "6) Your email (for the free HTTPS certificate): " LE_EMAIL
  GH_REPO="https://${GH_USER}:${GH_TOKEN}@github.com/${GH_USER}/${GH_NAME}.git"
  umask 077; cat > $CONF <<EOF
DOMAIN='$DOMAIN'
GH_REPO='$GH_REPO'
LE_EMAIL='$LE_EMAIL'
EOF
fi

say "Updating Ubuntu and installing tools (3–5 minutes)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl git nginx certbot python3-certbot-nginx build-essential python3 ffmpeg coturn iptables-persistent netfilter-persistent sqlite3 ca-certificates

if ! command -v node >/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 22 ]; then
  say "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
command -v pm2 >/dev/null || npm install -g pm2

say "Adding 2 GB swap (keeps the server stable)"
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q /swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

say "Opening the server firewall (web 80/443, calls 3478 + 49160-49200)"
open_port(){
  iptables -C INPUT -p "$1" --dport "$2" -j ACCEPT 2>/dev/null && return 0
  local n; n=$(iptables -L INPUT --line-numbers -n | awk '/REJECT/{print $1; exit}')
  if [ -n "$n" ]; then iptables -I INPUT "$n" -p "$1" --dport "$2" -j ACCEPT; else iptables -A INPUT -p "$1" --dport "$2" -j ACCEPT; fi
}
for p in "tcp 80" "tcp 443" "tcp 3478" "udp 3478" "udp 49160:49200"; do open_port $p || echo "  (could not open $p — check later)"; done
netfilter-persistent save >/dev/null 2>&1 || true

say "Downloading the website code from GitHub"
if [ -d $APP_DIR/.git ]; then
  git -C $APP_DIR remote set-url origin "$GH_REPO"; git -C $APP_DIR fetch -q origin && git -C $APP_DIR reset -q --hard origin/main
else
  git clone -q "$GH_REPO" $APP_DIR || { echo "❌ Could not download from GitHub. Check username, repo name and token, then run again:  sudo rm $CONF && sudo bash $0"; exit 1; }
fi
mkdir -p $DATA_DIR/backups
cd $APP_DIR && npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund

PUBLIC_IP=$(curl -fsS -m 8 https://api.ipify.org || curl -fsS -m 8 https://ifconfig.me || hostname -I | awk '{print $1}')
if [ ! -f $APP_DIR/.env ]; then
  say "Creating settings (.env)"
  TURN_PASS=$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 20)
  umask 077; cat > $APP_DIR/.env <<EOF
PORT=3000
NODE_ENV=production
COOKIE_SECURE=1
DATA_DIR=$DATA_DIR
JWT_SECRET=$(head -c 48 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 64)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD:-Admin@123}
SEED_DEMO=1
TURN_URL=turn:$DOMAIN:3478?transport=udp,turn:$DOMAIN:3478?transport=tcp
TURN_USER=sweetdate
TURN_PASS=$TURN_PASS
EOF
fi
. <(grep -E '^TURN_(USER|PASS)=' $APP_DIR/.env)

say "Setting up the call server (TURN) so calls work on mobile data"
cat > /etc/turnserver.conf <<EOF
listening-port=3478
fingerprint
lt-cred-mech
user=$TURN_USER:$TURN_PASS
realm=$DOMAIN
external-ip=$PUBLIC_IP/$(hostname -I | awk '{print $1}')
min-port=49160
max-port=49200
no-cli
no-tlsv1
no-tlsv1_1
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
EOF
sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || echo 'TURNSERVER_ENABLED=1' > /etc/default/coturn
systemctl enable coturn >/dev/null 2>&1 || true
systemctl restart coturn 2>/dev/null || service coturn restart 2>/dev/null || echo '  (call server will start after reboot)'

say "Starting SweetDate (auto-restarts after crash or reboot)"
cd $APP_DIR
pm2 describe sweetdate >/dev/null 2>&1 && pm2 reload sweetdate --update-env || pm2 start server.js --name sweetdate --max-memory-restart 900M
pm2 save >/dev/null
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true

say "Setting up nginx for $DOMAIN"
cat > /etc/nginx/sites-available/sweetdate <<EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server {
  listen 80;
  server_name $DOMAIN www.$DOMAIN;
  client_max_body_size 40m;
  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 120s;
  }
}
EOF
ln -sf /etc/nginx/sites-available/sweetdate /etc/nginx/sites-enabled/sweetdate
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || nginx -s reload 2>/dev/null || nginx

say "Auto-update: every 2 minutes the server checks GitHub for changes"
cat > /usr/local/bin/sweetdate-update <<'EOF'
#!/usr/bin/env bash
cd /opt/sweetdate || exit 0
git fetch -q origin main || exit 0
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && exit 0
OLD_LOCK=$(md5sum package-lock.json 2>/dev/null)
git reset -q --hard origin/main
[ "$OLD_LOCK" = "$(md5sum package-lock.json 2>/dev/null)" ] || npm ci --omit=dev --no-audit --no-fund
pm2 reload sweetdate --update-env
echo "$(date '+%F %T') updated to $(git log -1 --format='%h %s')" >> /var/log/sweetdate-update.log
EOF
chmod +x /usr/local/bin/sweetdate-update
cat > /usr/local/bin/sweetdate-backup <<'EOF'
#!/usr/bin/env bash
D=/var/sweetdate; F=$(ls $D/*.db 2>/dev/null | head -1); [ -n "$F" ] || exit 0
sqlite3 "$F" ".backup '$D/backups/sweetdate-$(date +%F).db'"
find $D/backups -name '*.db' -mtime +14 -delete
EOF
chmod +x /usr/local/bin/sweetdate-backup
cat > /etc/cron.d/sweetdate <<'EOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/2 * * * * root /usr/local/bin/sweetdate-update >/dev/null 2>&1
30 2 * * * root /usr/local/bin/sweetdate-backup >/dev/null 2>&1
EOF

say "Free HTTPS certificate (needs the domain DNS pointing to $PUBLIC_IP)"
DNS_IP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
if [ "$DNS_IP" = "$PUBLIC_IP" ]; then
  WWW=""; [ "$(getent ahostsv4 "www.$DOMAIN" | awk 'NR==1{print $1}' || true)" = "$PUBLIC_IP" ] && WWW="-d www.$DOMAIN"
  certbot --nginx -n --agree-tos -m "$LE_EMAIL" -d "$DOMAIN" $WWW --redirect && HTTPS_OK=1 || HTTPS_OK=0
else
  HTTPS_OK=0
fi

sleep 2
curl -fsS -o /dev/null http://127.0.0.1:3000/api/meta && APP_OK=1 || APP_OK=0
echo
echo "================================================================"
[ $APP_OK = 1 ] && echo -e "${G}✅ SweetDate is running on this server${N}" || echo -e "${Y}⚠️  The app did not answer yet — run:  pm2 logs sweetdate${N}"
echo "   Server IP:  $PUBLIC_IP"
if [ $HTTPS_OK = 1 ]; then
  echo -e "${G}✅ LIVE:  https://$DOMAIN    Admin: https://$DOMAIN/admin  (username: admin)${N}"
else
  echo -e "${Y}⏳ HTTPS not done yet. At your domain company set:  A record  @  → $PUBLIC_IP   and   A record  www → $PUBLIC_IP"
  echo -e "   Wait 10–30 minutes, then run again:  sudo bash $0${N}"
  echo "   Meanwhile you can open  http://$PUBLIC_IP  to see the site (login works only after HTTPS is done)."
fi
echo "   Auto-update from GitHub every 2 minutes · Daily backup at 2:30 AM in $DATA_DIR/backups"
echo "================================================================"
