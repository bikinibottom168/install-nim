#!/bin/bash
set -euo pipefail

### =============================================================
### SLAVE SSL PULL — installer
###
### รันบน "slave server" (ทั้ง 9 ตัว) ครั้งเดียว เพื่อ:
###   1. ติดตั้ง sshpass
###   2. ถาม IP/user/password ของ main + บันทึก
###   3. ทดสอบ ssh
###   4. ลบ service/cron เดิมจาก 3.install-ssl.sh (ถ้ามี)
###   5. ติดตั้ง /usr/local/bin/ssl-pull.sh + cron */5 นาที
###   6. รัน sync ครั้งแรก
### =============================================================

DEFAULT_MAIN_HOST="168.199.21.170"
DEFAULT_MAIN_USER="root"

CONFIG_DIR="/etc/ssl-puller"
PULLER_SCRIPT="/usr/local/bin/ssl-pull.sh"
LOG_FILE="/var/log/ssl-pull.log"

### ===============================
### CHECK ROOT
### ===============================
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "❌ ต้องรันด้วย sudo หรือ root"
  exit 1
fi

### ===============================
### INSTALL DEPENDENCIES
### ===============================
echo "📦 Installing dependencies..."
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y sshpass openssh-client curl openssl

### ===============================
### PROMPT FOR MAIN SERVER CONFIG
### ===============================
echo ""
echo "=========================================="
echo "  ตั้งค่า Main server"
echo "=========================================="
read -rp "Main IP [$DEFAULT_MAIN_HOST]: " MAIN_HOST
MAIN_HOST="${MAIN_HOST:-$DEFAULT_MAIN_HOST}"

read -rp "Main user [$DEFAULT_MAIN_USER]: " MAIN_USER
MAIN_USER="${MAIN_USER:-$DEFAULT_MAIN_USER}"

echo -n "Main password: "
read -rs MAIN_PASS
echo ""

if [ -z "$MAIN_PASS" ]; then
  echo "❌ Password ว่าง"
  exit 1
fi

### ===============================
### TEST SSH CONNECTION
### ===============================
echo ""
echo "🔌 Testing SSH connection to $MAIN_USER@$MAIN_HOST..."
if ! sshpass -p "$MAIN_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o LogLevel=ERROR \
      "$MAIN_USER@$MAIN_HOST" 'echo SSH_OK' 2>/dev/null | grep -q SSH_OK; then
  echo "❌ เชื่อมต่อไม่ได้ — ตรวจสอบ IP / user / password / firewall"
  exit 1
fi
echo "✅ Connection OK"

### ===============================
### SAVE CONFIG + PASSWORD
### ===============================
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

cat > "$CONFIG_DIR/config" <<CFG
MAIN_HOST="$MAIN_HOST"
MAIN_USER="$MAIN_USER"
CFG
chmod 600 "$CONFIG_DIR/config"

printf '%s' "$MAIN_PASS" > "$CONFIG_DIR/main.pass"
chmod 600 "$CONFIG_DIR/main.pass"
unset MAIN_PASS

echo "💾 Saved config to $CONFIG_DIR/"

### ===============================
### CLEANUP EXISTING 3.install-ssl.sh ARTIFACTS
### (slave ต้องไม่ออก cert เอง กัน rate limit)
### ===============================
echo ""
echo "🧹 Cleaning up old certbot/ssl-monitor artifacts..."

# ssl-monitor service
systemctl stop ssl-monitor.service 2>/dev/null || true
systemctl disable ssl-monitor.service 2>/dev/null || true
rm -f /etc/systemd/system/ssl-monitor.service
rm -f /usr/local/bin/ssl-monitor.sh
rm -f /usr/local/bin/ssl-monitor-ctl

# certbot timer + cron
systemctl stop certbot.timer 2>/dev/null || true
systemctl disable certbot.timer 2>/dev/null || true
rm -f /etc/cron.d/certbot

# crontab (กรอง certbot/ssl-monitor/ssl-pull เก่าทิ้ง)
crontab -l 2>/dev/null \
  | grep -v 'certbot' \
  | grep -v 'ssl-monitor' \
  | grep -v 'ssl-pull' \
  | crontab - 2>/dev/null || true

# certbot deploy hook (puller จะ update nimble.conf เอง)
rm -f /etc/letsencrypt/renewal-hooks/deploy/99-nimble-reload.sh

systemctl daemon-reload
echo "✅ Cleanup done (ไม่ลบ /etc/letsencrypt เผื่อใช้ fallback)"

### ===============================
### INSTALL PULLER SCRIPT
### ===============================
echo ""
echo "📥 Installing puller script → $PULLER_SCRIPT"

cat > "$PULLER_SCRIPT" <<'PULLER_EOF'
#!/bin/bash
set -euo pipefail

### =============================================================
### SSL PULL — sync cert จาก main server มายัง slave
### เรียกโดย cron */5 นาที
### =============================================================

CONFIG=/etc/ssl-puller/config
PASS_FILE=/etc/ssl-puller/main.pass
CERTS_DIR=/etc/ssl-puller/certs
NIMBLE_CONF=/etc/nimble/nimble.conf
LOG_TAG=ssl-pull

# Telegram (token เดียวกับ 3.install-ssl.sh)
TG_TOKEN="8757371676:AAHPCzO0_d_7FIXaILiLnxgkqpEXBuMdVlM"
TG_CHAT_ID="6795775557"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  logger -t "$LOG_TAG" "$*" 2>/dev/null || true
}

# กระจายโหลด: ถ้า cron เรียก สุ่ม sleep 0-60s (slaves 9 ตัวจะไม่ยิงพร้อมกัน)
# ถ้ารันมือเอง: export SKIP_JITTER=1 เพื่อข้าม
if [ "${SKIP_JITTER:-0}" != "1" ]; then
  sleep $((RANDOM % 60))
fi

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
  elif systemctl list-unit-files | grep -qE '^nimble-streamer\.service'; then
    systemctl restart nimble-streamer
  else
    systemctl restart nimble 2>/dev/null || systemctl restart nimble-streamer 2>/dev/null || true
  fi
}

update_nimble_ssl_paths() {
  local fullchain="$1"
  local privkey="$2"
  if [ ! -f "$NIMBLE_CONF" ]; then
    log "ERROR: $NIMBLE_CONF not found"
    return 1
  fi
  local tmp
  tmp="$(mktemp)"
  grep -vE '^[[:space:]]*ssl_certificate[[:space:]]*=' "$NIMBLE_CONF" \
    | grep -vE '^[[:space:]]*ssl_certificate_key[[:space:]]*=' \
    > "$tmp"
  cat >> "$tmp" <<EOF

# --- managed by ssl-pull ---
ssl_certificate = $fullchain
ssl_certificate_key = $privkey
# --- end managed block ---
EOF
  cp "$tmp" "$NIMBLE_CONF"
  rm -f "$tmp"
}

# ดึงรายชื่อโดเมน (SAN) จาก cert จริง — บอกได้ชัดว่า cert ครอบโดเมนอะไรบ้าง
cert_domains() {
  local cert="$1"
  [ -f "$cert" ] || return 0
  command -v openssl >/dev/null 2>&1 || return 0
  openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
    | grep -oE 'DNS:[^,]+' \
    | sed 's/DNS://; s/[[:space:]]//g' \
    | sort -u
}

### โหลด config
[ -f "$CONFIG" ]    || { log "ERROR: $CONFIG not found, run installer first"; exit 1; }
[ -f "$PASS_FILE" ] || { log "ERROR: $PASS_FILE not found"; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG"
: "${MAIN_HOST:?MAIN_HOST not set}"
: "${MAIN_USER:?MAIN_USER not set}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -o ServerAliveInterval=10
  -o LogLevel=ERROR
)

ssh_main() {
  sshpass -f "$PASS_FILE" ssh "${SSH_OPTS[@]}" "$MAIN_USER@$MAIN_HOST" "$@"
}

### ดึง primary domain จาก main
PRIMARY="$(ssh_main 'head -n 1 /etc/ssl-monitor/installed-domains.txt 2>/dev/null' 2>/dev/null || true)"
if [ -z "$PRIMARY" ]; then
  log "Main has no installed-domains.txt yet — quiet wait"
  exit 0
fi

### ดึง hash ของ cert บน main
REMOTE_HASH="$(ssh_main "sha256sum /etc/letsencrypt/live/$PRIMARY/fullchain.pem 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
if [ -z "$REMOTE_HASH" ]; then
  log "Main has no cert for $PRIMARY yet — quiet wait"
  exit 0
fi

### เทียบกับ hash บน slave
LOCAL_CERT_DIR="$CERTS_DIR/$PRIMARY"
LOCAL_FULLCHAIN="$LOCAL_CERT_DIR/fullchain.pem"
LOCAL_PRIVKEY="$LOCAL_CERT_DIR/privkey.pem"
LOCAL_HASH=""
if [ -f "$LOCAL_FULLCHAIN" ]; then
  LOCAL_HASH="$(sha256sum "$LOCAL_FULLCHAIN" | awk '{print $1}')"
fi

if [ "$REMOTE_HASH" = "$LOCAL_HASH" ]; then
  # เหมือนเดิม ไม่ต้องทำอะไร (เงียบ)
  exit 0
fi

log "Cert change detected — pulling new cert for $PRIMARY"

mkdir -p "$LOCAL_CERT_DIR"

### ดึงไฟล์ใหม่ (เขียนเป็น .new ก่อน แล้วค่อย mv แบบ atomic)
if ! ssh_main "cat /etc/letsencrypt/live/$PRIMARY/fullchain.pem" > "$LOCAL_FULLCHAIN.new" 2>/dev/null; then
  log "ERROR: failed to pull fullchain.pem"
  rm -f "$LOCAL_FULLCHAIN.new"
  exit 1
fi

if ! ssh_main "cat /etc/letsencrypt/live/$PRIMARY/privkey.pem" > "$LOCAL_PRIVKEY.new" 2>/dev/null; then
  log "ERROR: failed to pull privkey.pem"
  rm -f "$LOCAL_FULLCHAIN.new" "$LOCAL_PRIVKEY.new"
  exit 1
fi

### Verify hash ตรงกับ remote ที่ประกาศไว้
PULLED_HASH="$(sha256sum "$LOCAL_FULLCHAIN.new" | awk '{print $1}')"
if [ "$PULLED_HASH" != "$REMOTE_HASH" ]; then
  log "ERROR: pulled cert hash mismatch (got $PULLED_HASH, expected $REMOTE_HASH)"
  rm -f "$LOCAL_FULLCHAIN.new" "$LOCAL_PRIVKEY.new"
  exit 1
fi

### Atomic move + permissions
mv "$LOCAL_FULLCHAIN.new" "$LOCAL_FULLCHAIN"
mv "$LOCAL_PRIVKEY.new" "$LOCAL_PRIVKEY"
chmod 600 "$LOCAL_FULLCHAIN" "$LOCAL_PRIVKEY"

### ลบ dir ของ primary เก่า (กรณี primary เปลี่ยน)
for d in "$CERTS_DIR"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  if [ "$name" != "$PRIMARY" ]; then
    log "Removing old cert dir: $d"
    rm -rf "$d"
  fi
done

### Update nimble.conf + restart
update_nimble_ssl_paths "$LOCAL_FULLCHAIN" "$LOCAL_PRIVKEY"
restart_nimble

### รายชื่อโดเมนที่ cert ครอบคลุม (จาก SAN)
DOMAINS="$(cert_domains "$LOCAL_FULLCHAIN")"
DOMAIN_COUNT="$(printf '%s\n' "$DOMAINS" | sed '/^$/d' | wc -l | tr -d ' ')"
EXPIRY="$(openssl x509 -in "$LOCAL_FULLCHAIN" -noout -enddate 2>/dev/null | sed 's/notAfter=//')"

log "SSL updated for $PRIMARY (from main $MAIN_HOST) — ${DOMAIN_COUNT} domain(s), expires: ${EXPIRY:-?}"
while IFS= read -r dm; do
  [ -n "$dm" ] && log "  • $dm"
done <<< "$DOMAINS"

HOSTNAME_VAL="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
send_telegram "🟢 <b>SLAVE_SSL_PULL</b> [${HOSTNAME_VAL}]
📅 ${NOW}
✅ Pulled new SSL from main ($MAIN_HOST)
🌐 Primary: $PRIMARY
📜 Domains (${DOMAIN_COUNT}):
$(printf '%s\n' "$DOMAINS" | sed '/^$/d;s/^/  • /')
⏳ Expires: ${EXPIRY:-?}
📁 Cert: $LOCAL_CERT_DIR"
PULLER_EOF

chmod +x "$PULLER_SCRIPT"
echo "✅ Puller installed"

### ===============================
### SETUP CRON (every 5 min)
### ===============================
echo ""
echo "⏰ Setting up cron (every 5 minutes)..."
( crontab -l 2>/dev/null | grep -v 'ssl-pull.sh'; \
  echo "*/5 * * * * $PULLER_SCRIPT >> $LOG_FILE 2>&1" ) | crontab -

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

echo "✅ Cron installed"

### ===============================
### FIRST SYNC (skip jitter)
### ===============================
echo ""
echo "🚀 Running first sync..."
echo ""
if SKIP_JITTER=1 "$PULLER_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
  echo "✅ First sync ok"
else
  echo "⚠️  First sync didn't complete (main อาจยังไม่มี cert พร้อม จะ retry อัตโนมัติทุก 5 นาที)"
fi

### ===============================
### VERIFY: แสดง cert + รายชื่อโดเมนที่ดึงมาจริง
### ===============================
echo ""
echo "=========================================="
echo "  🔍 SSL ที่ดึงมาจาก main"
echo "=========================================="
PULLED_CERT="$(ls -1 /etc/ssl-puller/certs/*/fullchain.pem 2>/dev/null | head -n 1)"
if [ -n "$PULLED_CERT" ] && command -v openssl >/dev/null 2>&1; then
  PRIMARY_NAME="$(basename "$(dirname "$PULLED_CERT")")"
  EXPIRY="$(openssl x509 -in "$PULLED_CERT" -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
  DOMAINS="$(openssl x509 -in "$PULLED_CERT" -noout -ext subjectAltName 2>/dev/null \
    | grep -oE 'DNS:[^,]+' | sed 's/DNS://; s/[[:space:]]//g' | sort -u)"
  DOMAIN_COUNT="$(printf '%s\n' "$DOMAINS" | sed '/^$/d' | wc -l | tr -d ' ')"

  echo "✅ Primary : $PRIMARY_NAME"
  echo "⏳ Expires : ${EXPIRY:-?}"
  echo "📜 Domains ที่เปิด SSL (${DOMAIN_COUNT}):"
  printf '%s\n' "$DOMAINS" | sed '/^$/d;s/^/   • /'

  # ตรวจว่า nimble.conf ชี้มาที่ cert ก้อนนี้แล้วหรือยัง
  if grep -q "$PULLED_CERT" /etc/nimble/nimble.conf 2>/dev/null; then
    echo "🛠  nimble.conf : ✅ ชี้มาที่ cert นี้แล้ว"
  else
    echo "🛠  nimble.conf : ⚠️  ยังไม่ได้ชี้มาที่ cert นี้ (จะอัปเดตรอบถัดไปเมื่อ cert เปลี่ยน)"
  fi
else
  echo "⚠️  ยังไม่มี cert ถูกดึงมา — main อาจยังไม่มี cert พร้อม"
  echo "    ระบบจะลองใหม่อัตโนมัติทุก 5 นาที (ดู: tail -f $LOG_FILE)"
fi

echo ""
echo "=========================================="
echo "  ✅ Setup complete!"
echo "=========================================="
echo "📌 Config:   $CONFIG_DIR/{config,main.pass}"
echo "📌 Puller:   $PULLER_SCRIPT"
echo "📌 Cron:     */5 * * * *"
echo "📌 Log:      $LOG_FILE"
echo ""
echo "🔍 ดูสถานะล่าสุด:  tail -50 $LOG_FILE"
echo "🧪 รัน sync มือ:    SKIP_JITTER=1 sudo $PULLER_SCRIPT"
echo "📂 Cert ปัจจุบัน:    ls -la /etc/ssl-puller/certs/"
echo "📜 ดูโดเมนใน cert:  openssl x509 -in /etc/ssl-puller/certs/*/fullchain.pem -noout -ext subjectAltName"
