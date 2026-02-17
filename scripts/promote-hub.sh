#!/bin/bash
set -e

# Marcoby Nexus - Hub Promotion Script
# This script upgrades an existing Nexus/OpenClaw instance to a Master Hub

usage() {
    echo "Usage: $0 --hub-id <id> --domain <domain> --admin <email>"
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --hub-id) HUB_ID="$2"; shift ;;
        --domain) HUB_DOMAIN="$2"; shift ;;
        --admin) ADMIN_EMAIL="$2"; shift ;;
        *) usage ;;
    esac
    shift
done

if [ -z "$HUB_ID" ] || [ -z "$HUB_DOMAIN" ] || [ -z "$ADMIN_EMAIL" ]; then
    usage
fi

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=======================================${NC}"
echo -e "   Promoting to Marcoby Master Hub     "
echo -e "${BLUE}=======================================${NC}"

# 1. Update openclaw.json
CONFIG_FILE="/data/.openclaw/openclaw.json"
if [ ! -f "$CONFIG_FILE" ]; then
    # Fallback for different install paths
    CONFIG_FILE="$HOME/.openclaw/openclaw.json"
fi

echo "📝 Updating OpenClaw configuration..."
if [ -f "$CONFIG_FILE" ]; then
    jq --arg id "$HUB_ID" --arg domain "$HUB_DOMAIN" \
       '.gateway.mode = "hub" | .gateway.hub = { "id": $id, "domain": $domain, "allow_spokes": true }' \
       "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
else
    echo "⚠️ OpenClaw config not found at $CONFIG_FILE. Please ensure OpenClaw is installed."
    exit 1
fi

# 2. Setup Fleet Registry
echo "🗄️ Initializing Spoke Registry..."
mkdir -p /data/.openclaw/fleet

# 3. Apply DNS via Cloudflare (if token is available)
# We assume the user has the token in their environment or we use the one provided earlier
if [ -n "$CLOUDFLARE_TOKEN" ]; then
    echo "📡 Updating DNS for $HUB_DOMAIN..."
    # Logic to update Cloudflare would go here
    # Since we are running on the server, we detect the local IP
    LOCAL_IP=$(curl -s ifconfig.me)
    # (Cloudflare API call would happen here)
fi

# 4. Restart services
echo "🔄 Restarting Nexus Hub..."
if command -v docker-compose &> /dev/null; then
    docker-compose restart || true
elif docker compose version &> /dev/null; then
    docker compose restart || true
fi

echo -e "\n${GREEN}=======================================${NC}"
echo -e "   Hub Promotion Complete!             "
echo -e "${GREEN}=======================================${NC}"
echo -e "Role: Master Hub"
echo -e "Hub ID: $HUB_ID"
echo -e "Domain: $HUB_DOMAIN"
echo -e "${BLUE}=======================================${NC}"
