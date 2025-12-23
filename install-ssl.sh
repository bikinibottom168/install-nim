#!/bin/bash

set -e

### ===============================
### CONFIG
### ===============================
DOMAIN_FILE="./domain.txt"
CF_INI="/certbot/cloudflare.ini"
PROPAGATION=300

### ===============================
### CHECK ROOT
### ===============================
if [ "$EUID" -ne 0 ]; then
  echo "❌ กรุณารันด้วย sudo หรือ root"
  exit 1
fi

### ===============================
### CHECK FILES
### ===============================
if [ ! -f "$DOMAIN_FILE" ]; then
  echo "❌ ไม่พบไฟล์ domain.txt"
  exit 1
fi

if [ ! -f "$CF_INI" ]; then
  echo "❌ ไม่พบไฟล์ $CF_INI"
  exit 1
fi

### ===============================
### READ DOMAINS
### ===============================
RAW_DOMAINS=$(cat "$DOMAIN_FILE" | tr -d ' \n\r')

IFS=',' read -ra DOMAIN_ARRAY <<< "$RAW_DOMAINS"

if [ "${#DOMAIN_ARRAY[@]}" -eq 0 ]; then
  echo "❌ ไม่มีโดเมนใน domain.txt"
  exit 1
fi

### ===============================
### BUILD -d PARAMS
### ===============================
DOMAIN_ARGS=""

for DOMAIN in "${DOMAIN_ARRAY[@]}"; do
  DOMAIN_ARGS="$DOMAIN_ARGS -d *.$DOMAIN"
done

echo "🌐 Domains:"
for DOMAIN in "${DOMAIN_ARRAY[@]}"; do
  echo "  - *.$DOMAIN"
done

### ===============================
### RUN CERTBOT
### ===============================
echo "🔐 Requesting Wildcard SSL..."

certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CF_INI" \
  --dns-cloudflare-propagation-seconds "$PROPAGATION" \
  $DOMAIN_ARGS

### ===============================
### RESULT
### ===============================
echo "✅ SSL Request Completed"
echo "📁 Certificates location:"
echo "   /etc/letsencrypt/live/"
