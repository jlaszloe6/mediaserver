#!/usr/bin/env bash
set -euo pipefail

source /config/.env

JELLYFIN_URL="http://jellyfin:8096"
JELLYFIN_KEY="${JELLYFIN_API_KEY:-}"

if [[ -z "$JELLYFIN_KEY" ]]; then
    echo "ERROR: JELLYFIN_API_KEY not set"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Triggering Jellyfin library scan..."
curl -sf -X POST "${JELLYFIN_URL}/Library/Refresh" \
    -H "X-Emby-Token: ${JELLYFIN_KEY}" \
    --max-time 10

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Library scan triggered."
