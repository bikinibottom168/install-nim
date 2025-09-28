#!/bin/bash

# -----------------------------------------------------------------------------
#  install_nimble_auto.sh
#
#  This script automates the end‑to‑end deployment and configuration of a
#  Nimble Streamer server followed by its integration into an existing
#  WMSPanel setup.  It performs the following high‑level steps in order:
#
#    1. Install Nimble Streamer and its prerequisites.
#    2. Register the new server instance with WMSPanel.
#    3. Configure Nimble with HTTP/HTTPS ports, SSL certificate paths and
#       buffer settings.
#    4. Install Certbot along with the Cloudflare DNS plugin and clone a
#       repository containing custom SSL keys.
#    5. Restart Nimble to apply configuration changes.
#    6. Configure system time zone and enable NTP synchronisation.
#    7. Install jq for JSON processing (required by WMSPanel API calls).
#    8. Use WMSPanel control API to:
#         - Append the new server to all existing stream aliases.
#         - Assign the new server to an existing HTTP origin application
#           (e.g. "xstream").
#         - Create an RTMP re‑publish rule on a source server to send
#           streams to the new server.
#         - Add an RTMP interface on the new server.
#         - Create a new RTMP application on the new server with specific
#           push authentication and streaming parameters.
#
#  Requirements:
#    - Run this script as root (e.g. via sudo or as a privileged user).
#    - Debian/Ubuntu‑based distribution with apt package manager.
#    - A valid network connection to reach the Nimble, WMSPanel, Cloudflare
#      plugin and GitHub repositories.
#
#  References:
#    - Nimble installation instructions recommend adding the repository via
#      curl, updating apt caches, and installing the package【725332312714278†L79-L93】.
#    - Registration can be automated by passing -u and -p options to
#      nimble_regutil【725332312714278†L117-L124】.
#    - The Certbot DNS Cloudflare plugin can be installed via apt along with
#      certbot itself【20274181942776†L70-L77】.
#    - To set a system time zone, use timedatectl with set‑timezone【195713097437720†L170-L175】,
#      and enable NTP synchronisation with timedatectl set‑ntp true【195713097437720†L244-L258】.
#    - The WMSPanel API provides endpoints to list and modify stream aliases,
#      HTTP origin applications, RTMP republish rules, interfaces and
#      applications. These endpoints require client_id and api_key
#      authentication【602427274507959†L7494-L7507】【15889195205952†L31-L71】.
#
#  Usage:
#    chmod +x install_nimble_auto.sh
#    sudo ./install_nimble_auto.sh
#
#  NOTE: This script contains plain‑text credentials and API keys.  For
#  production use, consider moving sensitive values into environment
#  variables or prompting interactively.
# -----------------------------------------------------------------------------

set -euo pipefail

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
CLONE_DEST="/tmp/ssl-server"

# WMSPanel API credentials – replace these placeholders with real values
CLIENT_ID="a5664a75-8fb0-438f-a339-3c06f01d42e4"
API_KEY="6a522ac72662f7684caeeb69667a3e22"

# The unique ID of the newly registered Nimble server.  You can obtain
# this via the WMSPanel UI or API.  Replace this placeholder after
# registration.
NEW_SERVER_ID="[your_new_server_id_here]"

# HTTP origin application name to update on WMSPanel (e.g. xstream)
ORIGIN_APP_NAME="xstream"

# Server ID on which to create the re‑publish rule (source server)
# This should correspond to an existing server in your WMSPanel account.
# For example: "62f6a7eb9d711546d2ca3879".
REPUBLISH_SOURCE_SERVER_ID="62f6a7eb9d711546d2ca3879"

# Destination IP (public IP of the new server) for the re‑publish rule
REPUBLISH_DEST_IP="[new_server_ip_here]"

# Optional: specify particular alias IDs to update, comma‑separated.
# Leave empty to update all aliases returned by the API.
ALIAS_IDS=""

# WMSAuth group to update.  The new server will be assigned to this group
# automatically if NEW_SERVER_ID is detected or provided.  Replace this
# with the actual group ID from your WMSPanel account.
WMSAUTH_GROUP_ID="sb_gid_62f17574796db4303d3ad12b"

# Cloudflare credentials and domain list API.  These variables are used to
# add the IP of the new server as an additional A record for each domain
# returned by the domainstream API.  The record is added without
# removing existing A records to support load balancing.  Replace
# the placeholders below with your actual Cloudflare email and API key.
CLOUDFLARE_EMAIL="zzeedbet@gmail.com"
CLOUDFLARE_API_KEY="a7f11f7aa567a9d7fe465d34f669f35087a89"

# Endpoint to fetch domains which should receive the new A record.  The
# endpoint returns a JSON array of domain names.  Adjust the token as
# needed.
DOMAIN_API_URL="https://api-soccer.thai-play.com/api/v1/domainstream?token=353890"


# =====================
# 1. Install Nimble and prerequisites
# =====================

echo "[1/16] Adding Nimble Streamer repository and installing required packages..."
# Add Nimble repository
curl -fsSL -o /etc/apt/sources.list.d/nimble.sources \
     https://nimblestreamer.com/ubuntu/nimble.sources

# Update package lists
apt-get update

# Install Nimble, git (for cloning), and jq (for JSON processing)
apt-get install -y nimble git jq


# =====================
# 2. Register the Nimble instance with WMSPanel
# =====================

echo "[2/16] Registering Nimble instance with WMSPanel..."
# Automate Nimble registration using provided credentials.  According to
# Softvelum documentation, nimble_regutil accepts -u and -p options for
# unattended registration【725332312714278†L117-L124】.
/usr/bin/nimble_regutil -u "$NIMBLE_EMAIL" -p "$NIMBLE_PASSWORD"


# =====================
# 3. Configure Nimble ports and SSL settings
# =====================

echo "[3/16] Configuring Nimble (port 80, SSL port 443, certificates)..."
NIMBLE_CONF="/etc/nimble/nimble.conf"

# Backup existing configuration
cp "$NIMBLE_CONF" "${NIMBLE_CONF}.bak.$(date +%s)"

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
update_conf "rtmp_buffer_items" "8196"


# =====================
# 4. Install Certbot and Cloudflare DNS plugin
# =====================

echo "[4/16] Installing Certbot and Cloudflare DNS plugin..."
apt-get install -y certbot python3-certbot-dns-cloudflare


# =====================
# 5. Clone custom SSL key repository and copy files
# =====================

echo "[5/16] Cloning SSL key repository and copying certificates..."
rm -rf "$CLONE_DEST"
git clone "$GITHUB_REPO" "$CLONE_DEST"

# Ensure destination directory exists
mkdir -p "$LE_PATH"
# Copy all files from the cloned repository into the Let's Encrypt live directory
cp -r "$CLONE_DEST"/* "$LE_PATH"/


# =====================
# 6. Restart Nimble service
# =====================

echo "[6/16] Restarting Nimble service to apply new settings..."
service nimble restart


# =====================
# 7. Configure system time zone and NTP
# =====================

echo "[7/16] Setting time zone to Asia/Bangkok and enabling NTP synchronisation..."
timedatectl set-timezone "Asia/Bangkok"
timedatectl set-ntp true


# =====================
# 8. WMSPanel API helper functions
# =====================

# Base URL for WMSPanel API
BASE_URL="https://api.wmspanel.com/v1"

# Perform a GET request and return JSON.  Automatically appends client_id and api_key.
api_get() {
  local endpoint="$1"
  curl -s -G \
       --data-urlencode "client_id=$CLIENT_ID" \
       --data-urlencode "api_key=$API_KEY" \
       "$BASE_URL$endpoint"
}

# Perform a PUT request with JSON payload.  Automatically appends client_id and api_key.
api_put() {
  local endpoint="$1"
  local json_payload="$2"
  curl -s -X PUT \
       -H "Content-Type: application/json" \
       --data "$json_payload" \
       "$BASE_URL$endpoint?client_id=$CLIENT_ID&api_key=$API_KEY"
}

# Perform a POST request with JSON payload.  Automatically appends client_id and api_key.
api_post() {
  local endpoint="$1"
  local json_payload="$2"
  curl -s -X POST \
       -H "Content-Type: application/json" \
       --data "$json_payload" \
       "$BASE_URL$endpoint?client_id=$CLIENT_ID&api_key=$API_KEY"
}

# Perform a DELETE request with authentication parameters
api_delete() {
  local endpoint="$1"
  curl -s -X DELETE \
       "$BASE_URL$endpoint?client_id=$CLIENT_ID&api_key=$API_KEY"
}


# =====================
# 8. Determine public IP and discover NEW_SERVER_ID automatically
# =====================

# The WMSPanel API requires a server ID to apply settings.  If NEW_SERVER_ID
# has not been specified (i.e. still contains the placeholder value), this
# section will attempt to determine it automatically based on the public IP
# address of this machine.  The script obtains the current public IP using
# a public web service (api.ipify.org), then queries the WMSPanel API for
# the list of servers and searches for a server entry with a matching IP.
# The API call is documented as part of WMSPanel control API: you can
# retrieve full information about your servers via the "Get servers list"
# API call【602427274507959†L3315-L3321】.  Should the list lookup succeed,
# the detected ID will be assigned to NEW_SERVER_ID, and the same public
# IP will be used for REPUBLISH_DEST_IP if it hasn't been set.

echo "[8/16] Detecting public IP and resolving server ID via WMSPanel..."

# Fetch the public IP address of the current host.  If the curl call fails
# or returns an empty string, fallback to using the first non-loopback
# address returned by `hostname -I`.  This dual approach increases
# reliability in environments with restrictive outbound networks.
PUBLIC_IP="$(curl -fs https://api.ipify.org || true)"
if [ -z "$PUBLIC_IP" ]; then
  # Try local network IPs
  PUBLIC_IP="$(hostname -I | awk '{print $1}')"
fi

# If REPUBLISH_DEST_IP still contains the placeholder, assign the detected
# public IP as the destination address for the re-publish rule.
if [ "$REPUBLISH_DEST_IP" = "[new_server_ip_here]" ] || [ -z "$REPUBLISH_DEST_IP" ]; then
  REPUBLISH_DEST_IP="$PUBLIC_IP"
fi

# Only attempt to auto-detect NEW_SERVER_ID if it still contains the
# placeholder.  If the user has manually set NEW_SERVER_ID, skip this.
if [ "$NEW_SERVER_ID" = "[your_new_server_id_here]" ] || [ -z "$NEW_SERVER_ID" ]; then
  echo "  - NEW_SERVER_ID not provided. Attempting to look up server ID for IP $PUBLIC_IP..."
  # Poll the WMSPanel API for the servers list.  It may take some time
  # after registration before the new server appears in the API.  Try
  # multiple times with delays to accommodate for propagation.
  DETECTED_ID=""
  for attempt in {1..10}; do
    servers_json=$(api_get "/servers")
    # Check if the response contains a servers array
    total_servers=$(echo "$servers_json" | jq -r '.servers | length' 2>/dev/null || echo "0")
    if [ "$total_servers" = "null" ] || [ "$total_servers" = "0" ]; then
      sleep 6
      continue
    fi
    # Search for a server whose IP list includes the current public IP
    DETECTED_ID=$(echo "$servers_json" | jq -r --arg ip "$PUBLIC_IP" '.servers[] | select(.ip? and (.ip | index($ip))) | .id' | head -n 1)
    if [ -n "$DETECTED_ID" ]; then
      break
    fi
    sleep 6
  done
  if [ -n "$DETECTED_ID" ]; then
    NEW_SERVER_ID="$DETECTED_ID"
    echo "  - Detected NEW_SERVER_ID: $NEW_SERVER_ID"
  else
    echo "  - Warning: Unable to automatically determine NEW_SERVER_ID. Please set it manually."
  fi
fi

# Inform the user if REPUBLISH_DEST_IP has been inferred
if [ "$REPUBLISH_DEST_IP" = "$PUBLIC_IP" ]; then
  echo "  - Using detected public IP ($PUBLIC_IP) as REPUBLISH_DEST_IP."
fi



# =====================
# 9. Append new server to all stream aliases
# =====================

echo "[9/16] Fetching and updating stream aliases..."
aliases_json=$(api_get "/aliases")

alias_count=$(echo "$aliases_json" | jq -r '.aliases | length')

if [ "$alias_count" = "null" ]; then
  echo "Warning: No alias information returned from API. Verify CLIENT_ID and API_KEY."
else
  for i in $(seq 0 $((alias_count - 1))); do
    alias_id=$(echo "$aliases_json" | jq -r ".aliases[$i].id")
    alias_name=$(echo "$aliases_json" | jq -r ".aliases[$i].application")
    # If ALIAS_IDS is provided, skip aliases not listed
    if [ -n "$ALIAS_IDS" ]; then
      IFS=',' read -ra allowed_aliases <<< "$ALIAS_IDS"
      skip=true
      for allowed in "${allowed_aliases[@]}"; do
        if [ "$allowed" = "$alias_id" ]; then
          skip=false
          break
        fi
      done
      $skip && continue
    fi
    # Build updated server list
    existing_servers=$(echo "$aliases_json" | jq -c ".aliases[$i].servers | unique")
    updated_servers=$(echo "$existing_servers" | jq --arg new "$NEW_SERVER_ID" 'if index($new) == null then . + [$new] else . end')
    payload=$(jq -n --argjson servers "$updated_servers" '{servers: $servers}')
    echo "  - Updating alias $alias_name ($alias_id) to include new server..."
    api_put "/aliases/$alias_id" "$payload" >/dev/null
  done
  echo "Stream alias update completed."
fi


# =====================
# 10. Assign new server to HTTP origin application
# =====================

echo "[10/16] Updating HTTP origin application $ORIGIN_APP_NAME..."
origin_json=$(api_get "/origin_apps")
origin_count=$(echo "$origin_json" | jq -r '.origin_apps | length')

if [ "$origin_count" = "null" ]; then
  echo "Warning: No origin application information returned from API."
else
  origin_id=""
  existing_servers="[]"
  for i in $(seq 0 $((origin_count - 1))); do
    app_name=$(echo "$origin_json" | jq -r ".origin_apps[$i].name")
    if [ "$app_name" = "$ORIGIN_APP_NAME" ]; then
      origin_id=$(echo "$origin_json" | jq -r ".origin_apps[$i].id")
      existing_servers=$(echo "$origin_json" | jq -c ".origin_apps[$i].servers | unique")
      break
    fi
  done
  if [ -z "$origin_id" ]; then
    echo "  - Origin application '$ORIGIN_APP_NAME' not found. Skipping HTTP origin update."
  else
    updated_servers=$(echo "$existing_servers" | jq --arg new "$NEW_SERVER_ID" 'if index($new) == null then . + [$new] else . end')
    payload=$(jq -n --argjson servers "$updated_servers" '{servers: $servers}')
    echo "  - Assigning new server to origin application (ID: $origin_id)..."
    api_put "/origin_apps/$origin_id" "$payload" >/dev/null
    echo "HTTP origin application updated."
  fi
fi


# =====================
# 11. Create RTMP re‑publish rule on source server
# =====================

echo "[11/16] Creating RTMP re‑publish rule on server $REPUBLISH_SOURCE_SERVER_ID..."

republish_payload=$(jq -n \
  --arg src_app "$ORIGIN_APP_NAME" \
  --arg src_strm "" \
  --arg dest_addr "$REPUBLISH_DEST_IP" \
  --argjson dest_port 1935 \
  --arg dest_app "$ORIGIN_APP_NAME" \
  --arg auth_schema "RTMP" \
  --arg dest_login "$ORIGIN_APP_NAME" \
  --arg dest_password "13075" \
  --arg description "Auto re‑publish to new server" \
  '{
     src_app: $src_app,
     src_strm: $src_strm,
     dest_addr: $dest_addr,
     dest_port: $dest_port,
     dest_app: $dest_app,
     dest_strm: "",
     dest_app_params: "",
     dest_strm_params: "",
     auth_schema: $auth_schema,
     dest_login: $dest_login,
     dest_password: $dest_password,
     description: $description,
     paused: false,
     keep_src_stream_params: false,
     ssl: false
   }'
)

api_post "/server/$REPUBLISH_SOURCE_SERVER_ID/rtmp/republish" "$republish_payload" >/dev/null
echo "RTMP re‑publish rule created."


# =====================
# 12. Add RTMP interface on the new server
# =====================

echo "[12/16] Adding RTMP interface to new server $NEW_SERVER_ID..."
interface_payload=$(jq -n \
  --arg ip "" \
  --argjson port 1935 \
  --arg protocol "RTMP" \
  '{ip: $ip, port: $port, protocol: $protocol}')

api_post "/server/$NEW_SERVER_ID/rtmp/interface" "$interface_payload" >/dev/null
echo "RTMP interface added."


# =====================
# 13. Create RTMP application on the new server
# =====================

echo "[13/16] Creating RTMP application '$ORIGIN_APP_NAME' on new server..."
app_payload=$(jq -n \
  --arg app_name "$ORIGIN_APP_NAME" \
  --arg push_login "$ORIGIN_APP_NAME" \
  --arg push_password "130735" \
  --argjson chunk_duration 6 \
  --argjson chunk_count 10 \
  --arg dash_template "number" \
  '{
     name: $app_name,
     push_login: $push_login,
     push_password: $push_password,
     chunk_duration: $chunk_duration,
     chunk_count: $chunk_count,
     dash_segment_template: $dash_template
   }')

api_post "/server/$NEW_SERVER_ID/rtmp/app" "$app_payload" >/dev/null
echo "RTMP application created."


# =====================
# 14. Add A records in Cloudflare for load balancing
# =====================

echo "[14/16] Adding Cloudflare A records for load balancing..."

# Fetch domain list from external API.  The API is expected to return a JSON
# array of domain names.  Use jq to parse the list of domains.
domain_list=$(curl -s "$DOMAIN_API_URL" | jq -r '.data[]?.domain')

if [ -z "$domain_list" ]; then
  echo "  - No domains returned from domain API: $DOMAIN_API_URL" >&2
else
  # Loop through each domain and add a new A record pointing to the
  # IP of the new server (REPUBLISH_DEST_IP).  Existing records are
  # preserved to enable load balancing.
  for domain in $domain_list; do
    echo "  - Processing domain: $domain"
    # Retrieve the Zone ID for the domain
    zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$domain" \
      -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
      -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
      -H "Content-Type: application/json" | jq -r '.result[0].id')
    if [ -z "$zone_id" ] || [ "$zone_id" = "null" ]; then
      echo "    * Unable to find Zone ID for $domain; skipping." >&2
      continue
    fi
    # Prepare payload for creating a new A record
    cf_payload=$(jq -n \
      --arg type "A" \
      --arg name "$domain" \
      --arg content "$REPUBLISH_DEST_IP" \
      --argjson ttl 1 \
      --argjson proxied false \
      '{type:$type, name:$name, content:$content, ttl:$ttl, proxied:$proxied}')
    # Create the A record.  If a similar record already exists, Cloudflare
    # will still allow multiple A records (round‑robin).  No deletion is
    # performed.
    cf_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
      -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
      -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
      -H "Content-Type: application/json" \
      --data "$cf_payload")
    success=$(echo "$cf_response" | jq -r '.success')
    if [ "$success" != "true" ]; then
      echo "    * Failed to add A record for $domain" >&2
    else
      echo "    * A record added for $domain"
    fi
  done
fi

# =====================
# 15. Assign new server to WMSAuth group
# =====================

echo "[15/16] Assigning new server to WMSAuth group $WMSAUTH_GROUP_ID..."

# Fetch current WMSAuth group configuration
group_json=$(api_get "/wmsauth/groups/$WMSAUTH_GROUP_ID")

if [ -z "$group_json" ] || [ "$group_json" = "null" ]; then
  echo "  - Warning: unable to retrieve WMSAuth group $WMSAUTH_GROUP_ID. Skipping assignment." >&2
else
  # Extract existing server IDs and ensure uniqueness
  existing_ids=$(echo "$group_json" | jq -c '.group.server_ids // [] | unique')
  # Append the new server ID if it is not already included
  updated_ids=$(echo "$existing_ids" | jq --arg new "$NEW_SERVER_ID" 'if index($new) == null then . + [$new] else . end')
  # Construct payload for update
  wm_payload=$(jq -n --argjson server_ids "$updated_ids" '{server_ids: $server_ids}')
  # Send update request to assign the new server to the group
  api_put "/wmsauth/groups/$WMSAUTH_GROUP_ID" "$wm_payload" >/dev/null
  echo "  - WMSAuth group updated to include new server."
fi

echo "[16/16] All installation and configuration tasks completed successfully."
