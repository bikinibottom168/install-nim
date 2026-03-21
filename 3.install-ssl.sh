#!/bin/bash
set -euo pipefail

### ===============================
### CONFIG
### ===============================
API_URL="https://api-soccer.thai-play.com/api/domain/root-domains?token=353890"
DOMAIN_FILE="./domain.txt"
USE_DOMAIN_TXT=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_INI_SRC="${SCRIPT_DIR}/cloudflare.ini"

CF_INI="/certbot/cloudflare.ini"

PROPAGATION=300

NIMBLE_CONF="/etc/nimble/nimble.conf"
RENEW_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/99-nimble-reload.sh"

# ไฟล์เก็บรายชื่อโดเมนที่ติดตั้ง SSL แล้ว
INSTALLED_DOMAINS_FILE="/etc/ssl-monitor/installed-domains.txt"

# Telegram
TG_TOKEN="8757371676:AAHPCzO0_d_7FIXaILiLnxgkqpEXBuMdVlM"
TG_CHAT_ID="6795775557"

### ===============================
### PARSE OPTIONS
### ===============================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain-txt)
      USE_DOMAIN_TXT=true
      shift
      ;;
    *)
      echo "❌ Unknown option: $1"
      echo "Usage: sudo bash 3.install-ssl.sh [--domain-txt]"
      echo ""
      echo "Options:"
      echo "  --domain-txt    ใช้ domain.txt แทน API"
      echo "  (default)       ดึงโดเมนจาก API"
      exit 1
      ;;
  esac
done

### ===============================
### HELPERS
### ===============================
send_telegram() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    -d text="${message}" \
    -d parse_mode="HTML" >/dev/null 2>&1 || true
}

restart_nimble() {
  if systemctl list-unit-files | grep -qE '^nimble\.service'; then
    systemctl restart nimble
    return 0
  fi
  if systemctl list-unit-files | grep -qE '^nimble-streamer\.service'; then
    systemctl restart nimble-streamer
    return 0
  fi
  systemctl restart nimble 2>/dev/null || systemctl restart nimble-streamer 2>/dev/null || true
}

update_nimble_ssl_paths() {
  local fullchain="$1"
  local privkey="$2"

  if [ ! -f "$NIMBLE_CONF" ]; then
    echo "❌ ไม่พบไฟล์ $NIMBLE_CONF"
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"

  grep -vE '^[[:space:]]*ssl_certificate[[:space:]]*=' "$NIMBLE_CONF" \
    | grep -vE '^[[:space:]]*ssl_certificate_key[[:space:]]*=' \
    > "$tmp"

  cat >> "$tmp" <<EOF

# --- managed by certbot-nimble script ---
ssl_certificate = $fullchain
ssl_certificate_key = $privkey
# --- end managed block ---
EOF

  cp "$tmp" "$NIMBLE_CONF"
  rm -f "$tmp"
}

fetch_domains_from_api() {
  local response
  response="$(curl -s --max-time 30 "$API_URL")" || { echo "❌ ไม่สามารถเชื่อมต่อ API ได้"; return 1; }

  local ok
  ok="$(echo "$response" | jq -r '.ok // false')"
  if [ "$ok" != "true" ]; then
    echo "❌ API response not ok"
    return 1
  fi

  echo "$response" | jq -r '.domains[] | select(.excluded == false) | .domain'
}

### ===============================
### CHECK ROOT
### ===============================
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "❌ กรุณารันด้วย sudo หรือ root"
  exit 1
fi

### ===============================
### STEP 1) COPY cloudflare.ini -> /certbot/cloudflare.ini
### ===============================
echo "📄 Copy Cloudflare credentials ini -> $CF_INI"

if [ ! -f "$CF_INI_SRC" ]; then
  echo "❌ ไม่พบไฟล์ต้นฉบับ: $CF_INI_SRC"
  echo "   (ต้องมี cloudflare.ini อยู่โฟลเดอร์เดียวกับไฟล์ .sh นี้)"
  exit 1
fi

mkdir -p "$(dirname "$CF_INI")"
cp -f "$CF_INI_SRC" "$CF_INI"
chmod 600 "$CF_INI"

### ===============================
### CLEANUP: ลบ renew timer/cron และ cert เดิมทั้งหมด
### ===============================
echo "🧹 Removing all certbot renew timers and cron jobs..."

# หยุด ssl-monitor ถ้ากำลังทำงานอยู่
systemctl stop ssl-monitor.service 2>/dev/null || true
systemctl disable ssl-monitor.service 2>/dev/null || true

# หยุดและปิด certbot renew timer (systemd)
systemctl stop certbot.timer 2>/dev/null || true
systemctl disable certbot.timer 2>/dev/null || true

# ลบ cron job ของ certbot ทั้งหมด
crontab -l 2>/dev/null | grep -v 'certbot' | crontab - 2>/dev/null || true
rm -f /etc/cron.d/certbot

# ลบ deploy hook เดิม (ถ้ามี)
rm -f "$RENEW_DEPLOY_HOOK"

# ล้างรายชื่อโดเมนที่เคยติดตั้ง
rm -f "$INSTALLED_DOMAINS_FILE"

echo "✅ Cleanup done"

### ===============================
### CHECK FILES
### ===============================
if [ ! -f "$CF_INI" ]; then
  echo "❌ ไม่พบไฟล์ $CF_INI"
  exit 1
fi

### ===============================
### FETCH DOMAINS
### ===============================
CLEAN_DOMAINS=()

if [ "$USE_DOMAIN_TXT" = true ]; then
  echo "🌐 Reading domains from $DOMAIN_FILE..."
  if [ ! -f "$DOMAIN_FILE" ]; then
    echo "❌ ไม่พบไฟล์ domain.txt: $DOMAIN_FILE"
    exit 1
  fi
  RAW_DOMAINS="$(tr -d ' \n\r' < "$DOMAIN_FILE")"
  IFS=',' read -ra DOMAIN_ARRAY <<< "$RAW_DOMAINS"
  for d in "${DOMAIN_ARRAY[@]}"; do
    [ -n "$d" ] && CLEAN_DOMAINS+=("$d")
  done
else
  echo "🌐 Fetching domains from API..."
  DOMAIN_LIST="$(fetch_domains_from_api)" || exit 1
  while IFS= read -r d; do
    [ -n "$d" ] && CLEAN_DOMAINS+=("$d")
  done <<< "$DOMAIN_LIST"
fi

if [ "${#CLEAN_DOMAINS[@]}" -eq 0 ]; then
  echo "❌ ไม่มีโดเมน"
  exit 1
fi

PRIMARY_DOMAIN="${CLEAN_DOMAINS[0]}"

echo "🌐 Domains (wildcard):"
for d in "${CLEAN_DOMAINS[@]}"; do
  echo "  - *.$d"
done

### ===============================
### BUILD -d PARAMS (ARRAY)
### ===============================
DOMAIN_ARGS=()
for d in "${CLEAN_DOMAINS[@]}"; do
  DOMAIN_ARGS+=("-d" "*.$d")
done

### ===============================
### RUN CERTBOT
### ===============================
echo "🔐 Requesting Wildcard SSL..."
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CF_INI" \
  --dns-cloudflare-propagation-seconds "$PROPAGATION" \
  "${DOMAIN_ARGS[@]}"

### ===============================
### UPDATE NIMBLE CONF + RESTART
### ===============================
CERT_DIR="/etc/letsencrypt/live/$PRIMARY_DOMAIN"
FULLCHAIN="$CERT_DIR/fullchain.pem"
PRIVKEY="$CERT_DIR/privkey.pem"

if [ ! -f "$FULLCHAIN" ] || [ ! -f "$PRIVKEY" ]; then
  echo "❌ ไม่พบไฟล์ cert ที่คาดไว้:"
  echo "   $FULLCHAIN"
  echo "   $PRIVKEY"
  echo "   (เช็คว่า cert ออกใน live/ ชื่ออะไร)"
  exit 1
fi

echo "🛠 Updating Nimble SSL paths in $NIMBLE_CONF"
update_nimble_ssl_paths "$FULLCHAIN" "$PRIVKEY"

echo "🔄 Restarting Nimble service..."
restart_nimble
echo "✅ Nimble restarted"

### ===============================
### CLEANUP: ลบ cert เก่าทั้งหมด (ยกเว้นอันใหม่)
### ===============================
echo "🧹 Removing old certbot certificates (keeping: $PRIMARY_DOMAIN)..."

for cert_name in $(certbot certificates 2>/dev/null | grep 'Certificate Name:' | awk '{print $3}'); do
  if [ "$cert_name" = "$PRIMARY_DOMAIN" ]; then
    echo "  ✅ Keeping certificate: $cert_name"
    continue
  fi
  echo "  🗑 Deleting certificate: $cert_name"
  certbot delete --cert-name "$cert_name" --non-interactive 2>/dev/null || true
done

echo "✅ Old certificates cleanup done"

### ===============================
### SAVE INSTALLED DOMAINS
### ===============================
mkdir -p "$(dirname "$INSTALLED_DOMAINS_FILE")"
printf '%s\n' "${CLEAN_DOMAINS[@]}" > "$INSTALLED_DOMAINS_FILE"
echo "📝 Saved installed domains to $INSTALLED_DOMAINS_FILE"

### ===============================
### AUTO RENEW: DEPLOY HOOK
### ===============================
echo "♻️ Setting up auto-renew deploy hook for Nimble..."

mkdir -p "$(dirname "$RENEW_DEPLOY_HOOK")"

cat > "$RENEW_DEPLOY_HOOK" <<'EOF'
#!/bin/bash
set -euo pipefail

NIMBLE_CONF="/etc/nimble/nimble.conf"

FULLCHAIN="${RENEWED_LINEAGE}/fullchain.pem"
PRIVKEY="${RENEWED_LINEAGE}/privkey.pem"

if [ ! -f "$FULLCHAIN" ] || [ ! -f "$PRIVKEY" ]; then
  exit 0
fi

tmp="$(mktemp)"
grep -vE '^[[:space:]]*ssl_certificate[[:space:]]*=' "$NIMBLE_CONF" \
  | grep -vE '^[[:space:]]*ssl_certificate_key[[:space:]]*=' \
  > "$tmp"

cat >> "$tmp" <<EOF2

# --- managed by certbot deploy hook ---
ssl_certificate = $FULLCHAIN
ssl_certificate_key = $PRIVKEY
# --- end managed block ---
EOF2

cp "$tmp" "$NIMBLE_CONF"
rm -f "$tmp"

if systemctl list-unit-files | grep -qE '^nimble\.service'; then
  systemctl restart nimble
elif systemctl list-unit-files | grep -qE '^nimble-streamer\.service'; then
  systemctl restart nimble-streamer
else
  systemctl restart nimble 2>/dev/null || systemctl restart nimble-streamer 2>/dev/null || true
fi
EOF

chmod +x "$RENEW_DEPLOY_HOOK"

echo "✅ Deploy hook created: $RENEW_DEPLOY_HOOK"

### ===============================
### INSTALL & START SSL MONITOR (background)
### ===============================
echo "🚀 Installing SSL Monitor background service..."

# Copy ssl-monitor.sh to /usr/local/bin
cp -f "${SCRIPT_DIR}/ssl-monitor.sh" /usr/local/bin/ssl-monitor.sh
chmod +x /usr/local/bin/ssl-monitor.sh

# Copy ssl-monitor-ctl.sh to /usr/local/bin
cp -f "${SCRIPT_DIR}/ssl-monitor-ctl.sh" /usr/local/bin/ssl-monitor-ctl
chmod +x /usr/local/bin/ssl-monitor-ctl

# Create systemd service
cat > /etc/systemd/system/ssl-monitor.service <<SVCEOF
[Unit]
Description=SSL Monitor - Auto install SSL for new domains
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssl-monitor.sh
Restart=on-failure
RestartSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable ssl-monitor.service
systemctl start ssl-monitor.service

echo "✅ SSL Monitor service started"

### ===============================
### SEND TELEGRAM: START
### ===============================
HOSTNAME="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
send_telegram "🟢 <b>AUTO_SSL_START</b> [${HOSTNAME}]
📅 ${NOW}
🌐 Domains: ${#CLEAN_DOMAINS[@]}
$(printf '  • %s\n' "${CLEAN_DOMAINS[@]}")"

echo ""
echo "✅ All done!"
echo "📌 CF ini: $CF_INI (copied from: $CF_INI_SRC)"
echo "📌 Cert live dir (primary): /etc/letsencrypt/live/$PRIMARY_DOMAIN"
echo "📌 Nimble config: $NIMBLE_CONF"
echo "📌 SSL Monitor: systemctl status ssl-monitor"
echo "📌 SSL Monitor control: ssl-monitor-ctl {status|logs|stop|restart}"
