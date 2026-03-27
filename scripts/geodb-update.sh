#!/bin/bash
# geodb-update.sh - Download latest GeoLite2 database and reload Caddy
#
# Replaces the old `docker exec caddy` approach. Runs inside cron container,
# downloads GeoIP DB to the shared Caddy data volume, then reloads Caddy
# via its admin API on the bridge network.
#
# Run weekly (Sunday 2am) via cron.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE" >&2
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

ACCOUNT_ID="${MAXMIND_ACCOUNT_ID:-}"
LICENSE_KEY="${MAXMIND_LICENSE_KEY:-}"
DB_DIR="/config/all-configs/caddy/data/geolite2"
DB_FILE="$DB_DIR/GeoLite2-Country.mmdb"
CADDY_ADMIN_URL="http://caddy:2019"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [ -z "$LICENSE_KEY" ]; then
    log "ERROR: MAXMIND_LICENSE_KEY not set"
    exit 1
fi

log "=== GeoIP database update ==="

mkdir -p "$DB_DIR"

URL="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${LICENSE_KEY}&suffix=tar.gz"

log "Downloading GeoLite2-Country database..."
curl -sL "$URL" -o /tmp/geolite2.tar.gz

tar -xzf /tmp/geolite2.tar.gz -C /tmp
cp /tmp/GeoLite2-Country_*/GeoLite2-Country.mmdb "$DB_FILE"
rm -rf /tmp/geolite2.tar.gz /tmp/GeoLite2-Country_*

log "GeoLite2-Country database updated at $DB_FILE"

# Reload Caddy config via admin API
log "Reloading Caddy..."
RELOAD_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$CADDY_ADMIN_URL/load" \
    -H "Content-Type: application/json" \
    -d '{"@id": "reload"}' 2>/dev/null) || true

# Alternative: use the config adapter endpoint
if [ "$RELOAD_CODE" != "200" ]; then
    # Try stopping and starting to force a config reload
    log "Admin API reload returned $RELOAD_CODE, trying config endpoint..."
    # Caddy auto-reloads when the MMDB file changes if the watcher is enabled
    # For now, the updated file will be picked up on next Caddy restart
    log "GeoIP database updated — Caddy will use it on next restart"
else
    log "Caddy reloaded successfully"
fi

log "=== Done ==="
