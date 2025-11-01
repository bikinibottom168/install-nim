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

# Add Nimble repository
sudo bash -c 'echo -e "deb http://nimblestreamer.com/ubuntu jammy/" > /etc/apt/sources.list.d/nimble.list'

wget -q -O - http://nimblestreamer.com/gpg.key | sudo tee /etc/apt/trusted.gpg.d/nimble.asc

# Update package lists
apt-get update

# Install Nimble, git (for cloning), jq (JSON processing) and Certbot with Cloudflare
apt-get install -y nimble git jq certbot python3-certbot-dns-cloudflare

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