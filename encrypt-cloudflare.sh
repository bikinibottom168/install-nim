#!/bin/bash
# -----------------------------------------------------------------------------
#  encrypt-cloudflare.sh
#
#  เข้ารหัส cloudflare.ini -> cloudflare.ini.enc ด้วย OpenSSL AES-256-CBC + PBKDF2
#  รันสคริปต์นี้ "บนเครื่อง maintainer" เท่านั้น ตอนอัปเดต credentials
#  แล้ว commit เฉพาะ cloudflare.ini.enc ขึ้น git
#
#  Usage:
#    ./encrypt-cloudflare.sh
# -----------------------------------------------------------------------------
set -euo pipefail

SRC="cloudflare.ini"
DST="cloudflare.ini.enc"

if [ ! -f "$SRC" ]; then
  echo "❌ ไม่พบ $SRC (ต้องสร้างไฟล์ plain ก่อน encrypt)"
  exit 1
fi

echo "🔐 จะเข้ารหัส $SRC -> $DST"
echo "   ใช้ password ที่แข็งแรง (>=20 ตัว, สุ่ม) และเก็บนอก repo"
echo ""

openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -in "$SRC" -out "$DST"

chmod 644 "$DST"
echo ""
echo "✅ เข้ารหัสเสร็จแล้ว: $DST"
echo ""
echo "ขั้นตอนต่อไป:"
echo "  1. ตรวจว่า $SRC อยู่ใน .gitignore แล้ว"
echo "  2. git add $DST && git commit"
echo "  3. ส่ง password ให้ผู้ใช้ผ่านช่องทางปลอดภัย (ไม่ใช่ใน repo)"
