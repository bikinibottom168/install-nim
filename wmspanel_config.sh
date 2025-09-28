#!/bin/bash

# -----------------------------------------------------------------------------
#  wmspanel_config.sh
#
#  This script performs WMSPanel and related post-installation configuration for
#  a Nimble Streamer server.  It requires that Nimble has already been
#  installed and registered via a separate installation script.  The script
#  uses the WMSPanel control API to add the new server to stream aliases and
#  origin applications, create RTMP republish rules, add interfaces and
#  applications, update DNS records in Cloudflare for load balancing, and
#  assign the server to a WMSAuth group.  All API calls require a valid
#  client_id and api_key.
#
#  Usage:
#    chmod +x wmspanel_config.sh
#    sudo ./wmspanel_config.sh --server_id <server_id> [--dest_ip <ip-address>]
#
#  The --server_id argument is required; this should be the ID of the
#  newly registered Nimble server in your WMSPanel account.  You can obtain
#  this value from the WMSPanel UI or via the API.  If --dest_ip is not
#  provided, the script will use the first local IP address of the host as the
#  destination address for RTMP republishing and Cloudflare A records.
#
#  NOTE: This script contains plain‑text API keys and other sensitive
#  information.  Consider moving these values into environment variables or
#  prompting interactively if running in a shared environment.
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

# WMSPanel API credentials – replace these placeholders with real values
CLIENT_ID="[your_client_id_here]"
API_KEY="[your_api_key_here]"

# HTTP origin application name to update on WMSPanel (e.g. "xstream")
ORIGIN_APP_NAME="xstream"

# Server ID on which to create the re‑publish rule (source server).  This
# should correspond to an existing server in your WMSPanel account that will
# forward streams to the new origin server.
REPUBLISH_SOURCE_SERVER_ID="62f6a7eb9d711546d2ca3879"

# Optional: specify particular alias IDs to update, comma‑separated.  Leave
# empty to update all aliases returned by the API.
ALIAS_IDS=""

# WMSAuth group to update.  The new server will be assigned to this group
# automatically.  Replace this with the actual group ID from your WMSPanel
# account.
WMSAUTH_GROUP_ID="sb_gid_62f17574796db4303d3ad12b"

# Cloudflare credentials and domain list API.  These variables are used to
# add the IP of the new server as an additional A record for each domain
# returned by the domainstream API.  The record is added without removing
# existing A records to support load balancing.  Replace the placeholders
# below with your actual Cloudflare email and API key.
CLOUDFLARE_EMAIL="zzeedbet@gmail.com"
CLOUDFLARE_API_KEY="a7f11f7aa567a9d7fe465d34f669f35087a89"

# Endpoint to fetch domains which should receive the new A record.  The
# endpoint returns a JSON array of domain names.  Adjust the token as
# needed.
DOMAIN_API_URL="https://api-soccer.thai-play.com/api/v1/domainstream?token=353890"

# Default credentials for republish login/password.  Change these if needed.
REPUBLISH_LOGIN="$ORIGIN_APP_NAME"
REPUBLISH_PASSWORD="13075"

# Push authentication settings for the RTMP application on the new server.
APP_PUSH_LOGIN="$ORIGIN_APP_NAME"
APP_PUSH_PASSWORD="130735"

# =====================
# Parse command-line arguments
# =====================

SERVER_ID=""
DEST_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server_id|-s)
      SERVER_ID="$2"
      shift 2
      ;;
    --dest_ip|-d)
      DEST_IP="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 --server_id <server_id> [--dest_ip <ip>]" >&2
      exit 1
      ;;
  esac
done

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed. Please install jq before running this script." >&2
  exit 1
fi

# Determine local IPs for default DEST_IP if none provided
LOCAL_IPS="$(ip -o -4 addr list 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
if [ -z "$LOCAL_IPS" ]; then
  LOCAL_IPS="$(hostname -I | awk '{for(i=1;i<=NF;i++) print $i}')"
fi

# Choose the first local IP as default destination IP if not supplied
if [ -z "$DEST_IP" ]; then
  DEST_IP="$(echo "$LOCAL_IPS" | head -n 1)"
fi

# Prompt for SERVER_ID if not provided
if [ -z "$SERVER_ID" ]; then
  read -r -p "Enter server ID for the new Nimble server: " SERVER_ID
fi

# =====================
# Helper functions for WMSPanel API
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

# Perform a DELETE request
api_delete() {
  local endpoint="$1"
  curl -s -X DELETE \
       "$BASE_URL$endpoint?client_id=$CLIENT_ID&api_key=$API_KEY"
}

# =====================
# 1. Append new server to all stream aliases
# =====================

echo "[1/8] Fetching and updating stream aliases..."
aliases_json=$(api_get "/aliases")
alias_count=$(echo "$aliases_json" | jq -r '.aliases | length')
if [ "$alias_count" = "null" ]; then
  echo "  - Warning: no alias information returned from API. Verify CLIENT_ID and API_KEY." >&2
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
    updated_servers=$(echo "$existing_servers" | jq --arg new "$SERVER_ID" 'if index($new) == null then . + [$new] else . end')
    payload=$(jq -n --argjson servers "$updated_servers" '{servers: $servers}')
    echo "  - Updating alias $alias_name ($alias_id) to include new server..."
    api_put "/aliases/$alias_id" "$payload" >/dev/null
  done
  echo "Stream alias update completed."
fi

# =====================
# 2. Assign new server to HTTP origin application
# =====================

echo "[2/8] Updating HTTP origin application $ORIGIN_APP_NAME..."
origin_json=$(api_get "/origin_apps")
origin_count=$(echo "$origin_json" | jq -r '.origin_apps | length')
if [ "$origin_count" = "null" ]; then
  echo "  - Warning: no origin application information returned from API." >&2
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
    echo "  - Origin application '$ORIGIN_APP_NAME' not found. Skipping HTTP origin update." >&2
  else
    updated_servers=$(echo "$existing_servers" | jq --arg new "$SERVER_ID" 'if index($new) == null then . + [$new] else . end')
    payload=$(jq -n --argjson servers "$updated_servers" '{servers: $servers}')
    echo "  - Assigning new server to origin application (ID: $origin_id)..."
    api_put "/origin_apps/$origin_id" "$payload" >/dev/null
    echo "  - HTTP origin application updated."
  fi
fi

# =====================
# 3. Create RTMP re‑publish rule on source server
# =====================

echo "[3/8] Creating RTMP re‑publish rule on server $REPUBLISH_SOURCE_SERVER_ID..."
republish_payload=$(jq -n \
  --arg src_app "$ORIGIN_APP_NAME" \
  --arg src_strm "" \
  --arg dest_addr "$DEST_IP" \
  --argjson dest_port 1935 \
  --arg dest_app "$ORIGIN_APP_NAME" \
  --arg auth_schema "RTMP" \
  --arg dest_login "$REPUBLISH_LOGIN" \
  --arg dest_password "$REPUBLISH_PASSWORD" \
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
   }')
api_post "/server/$REPUBLISH_SOURCE_SERVER_ID/rtmp/republish" "$republish_payload" >/dev/null
echo "  - RTMP re‑publish rule created."

# =====================
# 4. Add RTMP interface on the new server
# =====================

echo "[4/8] Adding RTMP interface to new server $SERVER_ID..."
interface_payload=$(jq -n \
  --arg ip "" \
  --argjson port 1935 \
  --arg protocol "RTMP" \
  '{ip: $ip, port: $port, protocol: $protocol}')
api_post "/server/$SERVER_ID/rtmp/interface" "$interface_payload" >/dev/null
echo "  - RTMP interface added."

# =====================
# 5. Create RTMP application on the new server
# =====================

echo "[5/8] Creating RTMP application '$ORIGIN_APP_NAME' on new server..."
app_payload=$(jq -n \
  --arg app_name "$ORIGIN_APP_NAME" \
  --arg push_login "$APP_PUSH_LOGIN" \
  --arg push_password "$APP_PUSH_PASSWORD" \
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
api_post "/server/$SERVER_ID/rtmp/app" "$app_payload" >/dev/null
echo "  - RTMP application created."

# =====================
# 6. Add A records in Cloudflare for load balancing
# =====================

echo "[6/8] Adding Cloudflare A records for load balancing..."
domain_list=$(curl -s "$DOMAIN_API_URL" | jq -r '.data[]?.domain')
if [ -z "$domain_list" ]; then
  echo "  - No domains returned from domain API: $DOMAIN_API_URL" >&2
else
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
      --arg content "$DEST_IP" \
      --argjson ttl 1 \
      --argjson proxied false \
      '{type:$type, name:$name, content:$content, ttl:$ttl, proxied:$proxied}')
    # Create the A record.  If a similar record already exists, Cloudflare
    # will still allow multiple A records (round‑robin).  No deletion is performed.
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
# 7. Assign new server to WMSAuth group
# =====================

echo "[7/8] Assigning new server to WMSAuth group $WMSAUTH_GROUP_ID..."
group_json=$(api_get "/wmsauth/groups/$WMSAUTH_GROUP_ID")
if [ -z "$group_json" ] || [ "$group_json" = "null" ]; then
  echo "  - Warning: unable to retrieve WMSAuth group $WMSAUTH_GROUP_ID. Skipping assignment." >&2
else
  existing_ids=$(echo "$group_json" | jq -c '.group.server_ids // [] | unique')
  updated_ids=$(echo "$existing_ids" | jq --arg new "$SERVER_ID" 'if index($new) == null then . + [$new] else . end')
  wm_payload=$(jq -n --argjson server_ids "$updated_ids" '{server_ids: $server_ids}')
  api_put "/wmsauth/groups/$WMSAUTH_GROUP_ID" "$wm_payload" >/dev/null
  echo "  - WMSAuth group updated to include new server."
fi

echo "[8/8] All WMSPanel configuration tasks completed successfully."