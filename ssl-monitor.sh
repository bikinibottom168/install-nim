#!/bin/bash
set -euo pipefail

### ===============================
### SSL MONITOR - Background Service
### เช็คโดเมนใหม่จาก API ทุก 30 นาที
### ===============================

API_URL="https://api-soccer.thai-play.com/api/domain/root-domains?token=353890"
CF_INI="/certbot/cloudflare.ini"
PROPAGATION=300
NIMBLE_CONF="/etc/nimble/nimble.conf"
RENEW_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/99-nimble-reload.sh"
INSTALLED_DOMAINS_FILE="/etc/ssl-monitor/installed-domains.txt"
LOCK_FILE="/var/run/ssl-monitor.lock"
LOG_TAG="ssl-monitor"
CHECK_INTERVAL=1800  # 30 นาที

# Telegram
TG_TOKEN="8757371676:AAHPCzO0_d_7FIXaILiLnxgkqpEXBuMdVlM"
TG_CHAT_ID="6795775557"

### ===============================
### HELPERS
### ===============================
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  logger -t "$LOG_TAG" "$*" 2>/dev/null || true
}

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
    log "ERROR: ไม่พบไฟล์ $NIMBLE_CONF"
    return 1
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
  response="$(curl -s --max-time 30 "$API_URL")" || return 1

  local ok
  ok="$(echo "$response" | jq -r '.ok // false')"
  if [ "$ok" != "true" ]; then
    return 1
  fi

  echo "$response" | jq -r '.domains[] | select(.excluded == false) | .domain'
}

get_installed_domains() {
  if [ -f "$INSTALLED_DOMAINS_FILE" ]; then
    cat "$INSTALLED_DOMAINS_FILE"
  fi
}

save_installed_domain() {
  local domain="$1"
  mkdir -p "$(dirname "$INSTALLED_DOMAINS_FILE")"
  echo "$domain" >> "$INSTALLED_DOMAINS_FILE"
}

cleanup() {
  log "Shutting down ssl-monitor..."
  rm -f "$LOCK_FILE"
  exit 0
}

### ===============================
### LOCK: ป้องกันรันซ้ำซ้อน
### ===============================
acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local old_pid
    old_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      log "ERROR: ssl-monitor already running (PID: $old_pid)"
      exit 1
    fi
    # PID เก่าไม่ทำงานแล้ว ลบ lock file
    log "Removing stale lock file (old PID: $old_pid)"
    rm -f "$LOCK_FILE"
  fi

  echo $$ > "$LOCK_FILE"
}

### ===============================
### INSTALL SSL FOR ALL DOMAINS (single cert)
### ===============================
install_ssl_for_all_domains() {
  local domains=("$@")
  local hostname
  hostname="$(hostname)"
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  local primary="${domains[0]}"

  log "Installing SSL for ${#domains[@]} domain(s) in single cert"
  for d in "${domains[@]}"; do
    log "  - *.$d"
  done

  # สร้าง -d params
  local domain_args=()
  for d in "${domains[@]}"; do
    domain_args+=("-d" "*.$d")
  done

  # ขอ cert wildcard รวมทุกโดเมน
  if ! certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_INI" \
    --dns-cloudflare-propagation-seconds "$PROPAGATION" \
    "${domain_args[@]}" \
    --non-interactive --agree-tos --register-unsafely-without-email 2>&1; then
    log "ERROR: certbot failed"
    send_telegram "🔴 <b>AUTO_SSL_FAIL</b> [${hostname}]
📅 ${now}
❌ ติดตั้ง SSL ไม่สำเร็จ (${#domains[@]} domains)
⚠️ ไม่ลบ cert เก่า (ยังใช้งานได้)"
    return 1
  fi

  # หา cert directory (ใช้ primary domain เป็นชื่อ)
  local cert_dir="/etc/letsencrypt/live/$primary"
  local fullchain="$cert_dir/fullchain.pem"
  local privkey="$cert_dir/privkey.pem"

  # ถ้า cert directory ไม่มีตรง ลองหาจาก live/
  if [ ! -f "$fullchain" ]; then
    local alt_dir
    alt_dir="$(find /etc/letsencrypt/live/ -maxdepth 1 -name "${primary}*" -type d | sort | tail -1)"
    if [ -n "$alt_dir" ] && [ -f "$alt_dir/fullchain.pem" ]; then
      cert_dir="$alt_dir"
      fullchain="$cert_dir/fullchain.pem"
      privkey="$cert_dir/privkey.pem"
    fi
  fi

  if [ ! -f "$fullchain" ] || [ ! -f "$privkey" ]; then
    log "ERROR: cert files not found"
    send_telegram "🔴 <b>AUTO_SSL_FAIL</b> [${hostname}]
📅 ${now}
❌ ไม่พบไฟล์ cert: $primary
⚠️ ไม่ลบ cert เก่า (ยังใช้งานได้)"
    return 1
  fi

  # ลบ cert เก่าทั้งหมด (ยกเว้นอันใหม่)
  for cert_name in $(certbot certificates 2>/dev/null | grep 'Certificate Name:' | awk '{print $3}'); do
    if [ "$cert_name" = "$primary" ]; then
      continue
    fi
    log "Deleting old certificate: $cert_name"
    certbot delete --cert-name "$cert_name" --non-interactive 2>/dev/null || true
  done

  # อัพเดท nimble config
  update_nimble_ssl_paths "$fullchain" "$privkey"
  restart_nimble
  log "Nimble restarted with new SSL"

  # บันทึกโดเมนที่ติดตั้งแล้ว (เขียนทับทั้งหมด)
  mkdir -p "$(dirname "$INSTALLED_DOMAINS_FILE")"
  printf '%s\n' "${domains[@]}" > "$INSTALLED_DOMAINS_FILE"

  # แจ้ง Telegram
  local domain_list
  domain_list="$(printf '  • *.%s\n' "${domains[@]}")"
  send_telegram "🟢 <b>AUTO_SSL_NEW</b> [${hostname}]
📅 ${now}
✅ ติดตั้ง SSL สำเร็จ (${#domains[@]} domains)
${domain_list}
📁 Cert: $cert_dir"

  log "SSL installed successfully for ${#domains[@]} domain(s)"
  return 0
}

### ===============================
### MAIN LOOP
### ===============================
trap cleanup SIGTERM SIGINT SIGHUP

acquire_lock

HOSTNAME="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
log "SSL Monitor started (PID: $$)"
send_telegram "🟢 <b>AUTO_SSL_START</b> [${HOSTNAME}]
📅 ${NOW}
🔄 เริ่มเฝ้าระวังโดเมนใหม่ทุก 30 นาที"

while true; do
  log "Checking for new domains..."

  # ดึงโดเมนจาก API
  API_DOMAINS="$(fetch_domains_from_api 2>/dev/null)" || {
    log "WARNING: Cannot fetch domains from API, will retry next cycle"
    sleep "$CHECK_INTERVAL"
    continue
  }

  if [ -z "$API_DOMAINS" ]; then
    log "WARNING: No domains returned from API"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  # ดึงรายชื่อที่ติดตั้งแล้ว
  INSTALLED="$(get_installed_domains)"

  # รวมโดเมนทั้งหมดจาก API
  ALL_DOMAINS=()
  while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    ALL_DOMAINS+=("$domain")
  done <<< "$API_DOMAINS"

  if [ "${#ALL_DOMAINS[@]}" -eq 0 ]; then
    log "No domains from API"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  # เช็คว่ามีโดเมนใหม่ไหม (เทียบกับที่ติดตั้งแล้ว)
  HAS_NEW=false
  for domain in "${ALL_DOMAINS[@]}"; do
    if ! echo "$INSTALLED" | grep -qxF "$domain" 2>/dev/null; then
      log "New domain found: $domain"
      HAS_NEW=true
    fi
  done

  if [ "$HAS_NEW" = false ]; then
    log "No new domains found"
  else
    # ติดตั้ง SSL ทุกโดเมนใน cert เดียว
    log "New domain(s) detected, installing SSL for all ${#ALL_DOMAINS[@]} domain(s)..."
    install_ssl_for_all_domains "${ALL_DOMAINS[@]}" || true
  fi

  sleep "$CHECK_INTERVAL"
done
