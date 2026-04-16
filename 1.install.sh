#!/bin/bash

# -----------------------------------------------------------------------------
#  install_nimble.sh
#
#  This script installs and configures Nimble Streamer on a Debian/Ubuntu
#  system.  It performs only the base installation and setup tasks, without
#  performing any WMSPanel configuration.  You can run this script as root
#  (e.g. via sudo) before running a separate configuration script for
#  WMSPanel and cloud services.
#
#  Steps performed:
#    1. Add the Nimble Streamer repository and install required packages.
#    2. Register the Nimble instance with WMSPanel using provided credentials.
#    3. Update Nimble configuration for HTTP/HTTPS ports, SSL certificates and
#       RTMP buffer settings.
#    4. Install Certbot and the Cloudflare DNS plugin.
#    5. Clone a GitHub repository containing custom SSL keys and copy them
#       into the Let's Encrypt live directory for the specified domain.
#    6. Restart the Nimble service to apply configuration changes.
#    7. Set the system time zone to Asia/Bangkok and enable NTP synchronisation.
#
#  Usage:
#    chmod +x install_nimble.sh
#    sudo ./install_nimble.sh
#
#  NOTE: This script contains plain‑text credentials for the Nimble registration
#  and other settings.  For production use, consider storing sensitive
#  credentials in environment variables or prompting interactively.
# -----------------------------------------------------------------------------

set -euo pipefail

# Trap errors and display a helpful message.  If any command exits with a
# non-zero status, the following trap will print the line number, the
# command that failed, and its exit status.  This aids in debugging by
# providing context about where the script stopped.
trap 'echo "Error on or near line ${LINENO}: command \"${BASH_COMMAND}\" exited with status $?" >&2' ERR

# =====================
# 0. Decrypt cloudflare.ini.enc -> cloudflare.ini
# =====================
# ไฟล์ cloudflare.ini (plain) ไม่ได้ถูก commit (อยู่ใน .gitignore)
# repo เก็บเฉพาะ cloudflare.ini.enc ที่เข้ารหัสด้วย AES-256-CBC + PBKDF2
# สคริปต์นี้จะถาม password แล้วถอดรหัสเป็น cloudflare.ini ก่อนเริ่มติดตั้ง

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_INI_PLAIN="${SCRIPT_DIR}/cloudflare.ini"
CF_INI_ENC="${SCRIPT_DIR}/cloudflare.ini.enc"

echo "[0/7] Decrypting Cloudflare credentials..."

if [ -f "$CF_INI_PLAIN" ]; then
  echo "  ℹ️  พบ cloudflare.ini อยู่แล้ว ข้ามขั้นตอนถอดรหัส"
elif [ -f "$CF_INI_ENC" ]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "  📦 ติดตั้ง openssl..."
    apt-get update -y >/dev/null 2>&1 && apt-get install -y openssl >/dev/null 2>&1 \
      || yum install -y openssl >/dev/null 2>&1 \
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

# =====================
# Configurable variables
# =====================

# Nimble WMSPanel registration credentials
NIMBLE_EMAIL="iamdeveloper.th@gmail.com"
NIMBLE_PASSWORD="Iceza0251ZA"

# Domain for SSL certificate and key paths.  The script expects the
# Let's Encrypt live directory for this domain to exist or will create it
# before copying keys from a cloned repository.
DOMAIN="ssl-main"
LE_PATH="/etc/letsencrypt/live/${DOMAIN}"

# GitHub repository containing custom SSL keys
GITHUB_REPO="https://github.com/bikinibottom168/ssl-server"
CLONE_DEST="/tmp/remove-watermark"

# =====================
# 1. Install Nimble and prerequisites
# =====================

echo "[1/7] Adding Nimble Streamer repository and installing required packages..."

# Detect OS and version
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
  elif [ -f /etc/centos-release ]; then
    OS_ID="centos"
    OS_VERSION=$(grep -oE '[0-9]+' /etc/centos-release | head -1)
  else
    echo "ERROR: Cannot detect OS version" >&2
    exit 1
  fi
}

detect_os
echo "  Detected OS: ${OS_ID} ${OS_VERSION}"

# Add Nimble repository based on OS version
case "${OS_ID}" in
  ubuntu)
    case "${OS_VERSION}" in
      24.04)
        echo "  Setting up Nimble repo for Ubuntu 24.04 (Noble)..."
        sudo curl -o /etc/apt/sources.list.d/nimble.sources https://nimblestreamer.com/ubuntu/nimble.sources
        ;;
      22.04)
        echo "  Setting up Nimble repo for Ubuntu 22.04 (Jammy)..."
        sudo bash -c 'echo -e "deb http://nimblestreamer.com/ubuntu jammy/" > /etc/apt/sources.list.d/nimble.list'
        wget -q -O - http://nimblestreamer.com/gpg.key | sudo tee /etc/apt/trusted.gpg.d/nimble.asc
        ;;
      20.04)
        echo "  Setting up Nimble repo for Ubuntu 20.04 (Focal)..."
        sudo bash -c 'echo -e "deb http://nimblestreamer.com/ubuntu focal/" >> /etc/apt/sources.list'
        wget -q -O - http://nimblestreamer.com/gpg.key | sudo apt-key add -
        ;;
      *)
        echo "ERROR: Unsupported Ubuntu version: ${OS_VERSION} (supported: 20.04, 22.04, 24.04)" >&2
        exit 1
        ;;
    esac
    # Update package lists and install
    apt-get update
    apt-get install -y nimble git jq certbot python3-certbot-dns-cloudflare
    ;;
  centos)
    case "${OS_VERSION}" in
      7)
        echo "  Setting up Nimble repo for CentOS 7..."
        sudo bash -c 'echo -e "[nimble]\nname= Nimble Streamer repository\nbaseurl=http://nimblestreamer.com/centos/7/\$basearch\nenabled=1\ngpgcheck=1\ngpgkey=http://nimblestreamer.com/gpg.key\n" > /etc/yum.repos.d/nimble.repo'
        ;;
      *)
        echo "ERROR: Unsupported CentOS version: ${OS_VERSION} (supported: 7)" >&2
        exit 1
        ;;
    esac
    # Install via yum
    yum install -y nimble git jq certbot python3-certbot-dns-cloudflare
    ;;
  *)
    echo "ERROR: Unsupported OS: ${OS_ID} (supported: ubuntu, centos)" >&2
    exit 1
    ;;
esac

# =====================
# 2. Register the Nimble instance with WMSPanel
# =====================

echo "[2/7] Registering Nimble instance with WMSPanel..."
if [ -n "$NIMBLE_EMAIL" ] && [ -n "$NIMBLE_PASSWORD" ]; then
  /usr/bin/nimble_regutil -u "$NIMBLE_EMAIL" -p "$NIMBLE_PASSWORD"
else
  echo "  - Registration credentials are not set. Skipping registration." >&2
fi

# =====================
# 3. Configure Nimble ports and SSL settings
# =====================

echo "[3/7] Configuring Nimble (port 80, SSL port 443, certificates)..."
NIMBLE_CONF="/etc/nimble/nimble.conf"

# Backup existing configuration
if [ -f "$NIMBLE_CONF" ]; then
  cp "$NIMBLE_CONF" "${NIMBLE_CONF}.bak.$(date +%s)"
fi

# Helper function to update or append configuration entries in nimble.conf
update_conf() {
  local key="$1"
  local value="$2"
  if grep -qE "^\s*${key}\s*=" "$NIMBLE_CONF"; then
    sed -i "s|^\s*${key}\s*=.*|${key} = ${value}|" "$NIMBLE_CONF"
  else
    echo "${key} = ${value}" >> "$NIMBLE_CONF"
  fi
}

# Apply configuration changes: HTTP and HTTPS ports, SSL certificate paths,
# and buffer settings
update_conf "port" "80"
update_conf "ssl_port" "443"
update_conf "ssl_certificate" "${LE_PATH}/fullchain.pem"
update_conf "ssl_certificate_key" "${LE_PATH}/privkey.pem"

# เพิ่ม config ตามที่คุณต้องการ
update_conf "listen_interfaces" "*"
update_conf "enable_ipv6" "true"
update_conf "access_control_allow_origin" "*"
update_conf "access_control_allow_credentials" "true"
update_conf "access_control_expose_headers" "Content-Length"
update_conf "access_control_allow_headers" "Range"
update_conf "vod_chunk_duration" "6"
update_conf "worker_threads" "4"
update_conf "rtmp_worker_threads" "2"
update_conf "max_cache_size" "8192"
update_conf "max_disk_cache_size" "102400"

# =====================
# 4. Install Certbot and Cloudflare DNS plugin
# =====================

echo "[4/7] Certbot and DNS plugin are installed with apt in step 1."

# =====================
# 5. Clone custom SSL key repository and copy files
# =====================

echo "[5/7] Cloning SSL key repository and copying certificates..."
rm -rf "$CLONE_DEST"
git clone "$GITHUB_REPO" "$CLONE_DEST"

# Ensure destination directory exists
mkdir -p "$LE_PATH"
# Copy all files from the cloned repository into the Let's Encrypt live directory
cp -r "$CLONE_DEST"/* "$LE_PATH"/

# =====================
# 6. Restart Nimble service
# =====================

echo "[6/7] Restarting Nimble service to apply new settings..."
service nimble restart

# =====================
# 7. Configure system time zone and NTP
# =====================

echo "[7/7] Setting time zone to Asia/Bangkok and enabling NTP synchronisation..."
timedatectl set-timezone "Asia/Bangkok"
timedatectl set-ntp true

service nimble restart

echo "All installation tasks completed successfully."