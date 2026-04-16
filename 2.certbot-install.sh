#!/bin/bash

set -e

### ===============================
### CONFIG
### ===============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_INI_PLAIN="${SCRIPT_DIR}/cloudflare.ini"
CF_INI_ENC="${SCRIPT_DIR}/cloudflare.ini.enc"

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
### DECRYPT cloudflare.ini.enc -> cloudflare.ini
### ===============================
# repo เก็บเฉพาะ cloudflare.ini.enc (AES-256-CBC + PBKDF2)
# ไฟล์ plain cloudflare.ini อยู่ใน .gitignore ไม่ถูก commit
echo "🔐 Decrypting Cloudflare credentials..."

if [ -f "$CF_INI_PLAIN" ]; then
  echo "  ℹ️  พบ cloudflare.ini อยู่แล้ว ข้ามขั้นตอนถอดรหัส"
elif [ -f "$CF_INI_ENC" ]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "  📦 ติดตั้ง openssl..."
    apt-get install -y openssl >/dev/null 2>&1 \
      || { echo "❌ ติดตั้ง openssl ไม่สำเร็จ" >&2; exit 1; }
  fi

  for attempt in 1 2 3; do
    echo -n "  🔑 ใส่ password สำหรับถอดรหัส cloudflare.ini.enc: "
    read -rs CF_PASS
    echo ""

    if openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
        -in "$CF_INI_ENC" -out "$CF_INI_PLAIN" \
        -pass pass:"$CF_PASS" 2>/dev/null; then
      unset CF_PASS
      chmod 600 "$CF_INI_PLAIN"
      echo "  ✅ ถอดรหัสสำเร็จ"
      break
    else
      rm -f "$CF_INI_PLAIN"
      unset CF_PASS
      if [ "$attempt" -lt 3 ]; then
        echo "  ❌ password ไม่ถูกต้อง ลองอีกครั้ง ($attempt/3)"
      else
        echo "❌ ถอดรหัสล้มเหลวครบ 3 ครั้ง ยกเลิกการติดตั้ง" >&2
        exit 1
      fi
    fi
  done
else
  echo "❌ ไม่พบทั้ง cloudflare.ini และ cloudflare.ini.enc ใน $SCRIPT_DIR" >&2
  exit 1
fi

### ===============================
### COPY cloudflare.ini -> /certbot/cloudflare.ini
### ===============================
echo "📁 Creating $CERTBOT_DIR"
mkdir -p "$CERTBOT_DIR"

cp -f "$CF_INI_PLAIN" "$CF_INI_PATH"
chown root:root "$CF_INI_PATH"
chmod 600 "$CF_INI_PATH"

### ===============================
### VERIFY
### ===============================
echo "🔍 cloudflare.ini:"
cat "$CF_INI_PATH"

echo "🔍 Certbot version:"
certbot --version

echo "🔍 Installed plugins:"
certbot plugins | grep cloudflare || true

echo "✅ Setup complete"
