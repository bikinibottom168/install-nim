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

### -------------------------------
### DISABLE broken/stale apt repos
### (เครื่องเก่า Ubuntu 18.04 บางเครื่องมี MariaDB mirror ที่ถูกปิดไปแล้ว
###  ทำให้ apt update ล้มเหลว 404 -> set -e หยุดสคริปต์)
### -------------------------------
echo "🧹 Checking for broken apt repos..."

# ครอบคลุมทั้ง sources.list, *.list และ *.sources (deb822)
for f in /etc/apt/sources.list \
         /etc/apt/sources.list.d/*.list \
         /etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] || continue
  if grep -Eqs 'mirror\.lstn\.net/mariadb' "$f"; then
    case "$f" in
      /etc/apt/sources.list)
        # ไฟล์รวม: comment เฉพาะบรรทัดที่ชี้ mirror ตาย
        echo "  ⚠️  พบ MariaDB mirror ที่ใช้ไม่ได้ใน $f — comment บรรทัดทิ้ง"
        sed -i -E 's|^([^#].*mirror\.lstn\.net/mariadb.*)$|# \1|' "$f"
        ;;
      *)
        # ไฟล์แยกของ MariaDB: ปิดทั้งไฟล์ (rename เป็น .disabled)
        echo "  ⚠️  พบ MariaDB mirror ที่ใช้ไม่ได้ใน $f — ปิดทั้งไฟล์"
        mv -f "$f" "$f.disabled"
      ;;
    esac
  fi
done

# apt update: ยอมให้ผ่านแม้บาง repo อื่นจะ error (เราต้องการแค่ archive หลัก)
apt update || echo "  ⚠️  apt update มี warning จาก repo บางตัว (ข้ามได้)"
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

  CF_PASS="iceza0251"
  if openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
      -in "$CF_INI_ENC" -out "$CF_INI_PLAIN" \
      -pass pass:"$CF_PASS" 2>/dev/null; then
    unset CF_PASS
    chmod 600 "$CF_INI_PLAIN"
    echo "  ✅ ถอดรหัสสำเร็จ"
  else
    rm -f "$CF_INI_PLAIN"
    unset CF_PASS
    echo "❌ ถอดรหัสล้มเหลว — password ใน script ไม่ตรงกับที่ใช้ encrypt" >&2
    exit 1
  fi
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
