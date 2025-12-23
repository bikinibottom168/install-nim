#!/bin/bash

set -e

### ===============================
### CONFIG
### ===============================
CF_API_TOKEN="a7f11f7aa567a9d7fe465d34f669f35087a89"
CERTBOT_DIR="/certbot"
CF_INI_PATH="/certbot/cloudflare.ini"



### ===============================
### CHECK ROOT
### ===============================
if [ "$EUID" -ne 0 ]; then
  echo "❌ กรุณารันด้วย root หรือ sudo"
  exit 1
fi

echo "✅ Running as root"

### ===============================
### INSTALL SNAP & CERTBOT
### ===============================
echo "🔧 Installing snapd & certbot..."

apt update
apt install -y snapd
snap install core
snap refresh core
snap install --classic certbot

ln -sf /snap/bin/certbot /usr/bin/certbot

### ===============================
### INSTALL CLOUDFLARE PLUGIN
### ===============================
echo "🌩 Installing certbot-dns-cloudflare..."

snap set certbot trust-plugin-with-root=ok
snap install certbot-dns-cloudflare

### ===============================
### CREATE cloudflare.ini
### ===============================
echo "📁 Creating $CERTBOT_DIR"
mkdir -p $CERTBOT_DIR

echo "🔐 Creating cloudflare.ini"

cat > $CF_INI_PATH <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF

chmod 600 $CF_I_
