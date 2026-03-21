#!/bin/bash
set -euo pipefail

### ===============================
### UPDATE SSL MONITOR
### อัพเดทไฟล์ ssl-monitor + restart service
### ไม่ติดตั้ง cert ใหม่
### ===============================

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "❌ กรุณารันด้วย sudo หรือ root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔄 Updating SSL Monitor..."

# Copy ssl-monitor.sh
if [ ! -f "${SCRIPT_DIR}/ssl-monitor.sh" ]; then
  echo "❌ ไม่พบไฟล์ ${SCRIPT_DIR}/ssl-monitor.sh"
  exit 1
fi
cp -f "${SCRIPT_DIR}/ssl-monitor.sh" /usr/local/bin/ssl-monitor.sh
chmod +x /usr/local/bin/ssl-monitor.sh
echo "✅ Copied ssl-monitor.sh"

# Copy ssl-monitor-ctl.sh
if [ -f "${SCRIPT_DIR}/ssl-monitor-ctl.sh" ]; then
  cp -f "${SCRIPT_DIR}/ssl-monitor-ctl.sh" /usr/local/bin/ssl-monitor-ctl
  chmod +x /usr/local/bin/ssl-monitor-ctl
  echo "✅ Copied ssl-monitor-ctl"
fi

# Restart service
systemctl restart ssl-monitor.service
echo "✅ SSL Monitor restarted"

# แสดงสถานะ
systemctl status ssl-monitor.service --no-pager
