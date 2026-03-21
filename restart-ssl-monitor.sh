#!/bin/bash
set -euo pipefail

### ===============================
### RESTART SSL MONITOR
### copy ไฟล์ใหม่ -> หยุด process เก่า -> รันใหม่ -> แจ้ง Telegram
### ===============================

# Telegram
TG_TOKEN="8757371676:AAHPCzO0_d_7FIXaILiLnxgkqpEXBuMdVlM"
TG_CHAT_ID="6795775557"

send_telegram() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    -d text="${message}" \
    -d parse_mode="HTML" >/dev/null 2>&1 || true
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "❌ กรุณารันด้วย sudo หรือ root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

### ===============================
### STEP 1) Copy ไฟล์ใหม่
### ===============================
echo "📦 Copying ssl-monitor files..."

if [ ! -f "${SCRIPT_DIR}/ssl-monitor.sh" ]; then
  echo "❌ ไม่พบไฟล์ ${SCRIPT_DIR}/ssl-monitor.sh"
  exit 1
fi

cp -f "${SCRIPT_DIR}/ssl-monitor.sh" /usr/local/bin/ssl-monitor.sh
chmod +x /usr/local/bin/ssl-monitor.sh
echo "✅ Copied ssl-monitor.sh"

if [ -f "${SCRIPT_DIR}/ssl-monitor-ctl.sh" ]; then
  cp -f "${SCRIPT_DIR}/ssl-monitor-ctl.sh" /usr/local/bin/ssl-monitor-ctl
  chmod +x /usr/local/bin/ssl-monitor-ctl
  echo "✅ Copied ssl-monitor-ctl"
fi

### ===============================
### STEP 2) หยุด process เก่า
### ===============================
echo "🛑 Stopping old ssl-monitor..."

systemctl stop ssl-monitor.service 2>/dev/null || true

# ลบ lock file เก่า (ถ้ามี)
rm -f /var/run/ssl-monitor.lock

echo "✅ Old process stopped"

### ===============================
### STEP 3) รันใหม่
### ===============================
echo "🚀 Starting ssl-monitor..."

systemctl daemon-reload
systemctl enable ssl-monitor.service
systemctl start ssl-monitor.service

echo "✅ SSL Monitor started"

### ===============================
### STEP 4) แจ้ง Telegram
### ===============================
send_telegram "🔄 <b>SSL_MONITOR_RESTART</b> [${HOSTNAME}]
📅 ${NOW}
✅ อัพเดทและรีสตาร์ท ssl-monitor สำเร็จ"

echo ""
echo "✅ Done!"
systemctl status ssl-monitor.service --no-pager
