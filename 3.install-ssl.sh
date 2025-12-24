#!/bin/bash
set -euo pipefail

### ===============================
### CONFIG
### ===============================
DOMAIN_FILE="./domain.txt"

# cloudflare.ini ต้นฉบับอยู่ path เดียวกับไฟล์ .sh นี้
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_INI_SRC="${SCRIPT_DIR}/cloudflare.ini"

# ปลายทางที่ต้องการ
CF_INI="/certbot/cloudflare.ini"

PROPAGATION=300

NIMBLE_CONF="/etc/nimble/nimble.conf"
RENEW_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/99-nimble-reload.sh"

### ===============================
### HELPERS
### ===============================
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
### CHECK FILES
### ===============================
if [ ! -f "$DOMAIN_FILE" ]; then
  echo "❌ ไม่พบไฟล์ domain.txt: $DOMAIN_FILE"
  exit 1
fi

if [ ! -f "$CF_INI" ]; then
  echo "❌ ไม่พบไฟล์ $CF_INI"
  exit 1
fi

### ===============================
### READ DOMAINS
### ===============================
RAW_DOMAINS="$(tr -d ' \n\r' < "$DOMAIN_FILE")"
IFS=',' read -ra DOMAIN_ARRAY <<< "$RAW_DOMAINS"

CLEAN_DOMAINS=()
for d in "${DOMAIN_ARRAY[@]}"; do
  [ -n "$d" ] && CLEAN_DOMAINS+=("$d")
done

if [ "${#CLEAN_DOMAINS[@]}" -eq 0 ]; then
  echo "❌ ไม่มีโดเมนใน domain.txt"
  exit 1
fi

PRIMARY_DOMAIN="${CLEAN_DOMAINS[0]}"

echo "🌐 Domains (wildcard):"
for d in "${CLEAN_DOMAINS[@]}"; do
  echo "  - *.$d"
done

### ===============================
### BUILD -d PARAMS (ARRAY)  ✅ prevent glob expansion
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
### TEST RENEW (DRY RUN)
### ===============================
echo "🧪 Testing renew (dry-run)..."
certbot renew --dry-run

echo "✅ All done!"
echo "📌 CF ini: $CF_INI (copied from: $CF_INI_SRC)"
echo "📌 Cert live dir (primary): /etc/letsencrypt/live/$PRIMARY_DOMAIN"
echo "📌 Nimble config: $NIMBLE_CONF"
