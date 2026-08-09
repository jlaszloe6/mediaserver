#!/usr/bin/env bash
set -euo pipefail

source /scripts/lib/curl-secrets.sh
source /config/.env

JELLYFIN_URL="http://jellyfin:8096"
JELLYFIN_KEY="${JELLYFIN_API_KEY:-}"

if [[ -z "$JELLYFIN_KEY" ]]; then
    echo "ERROR: JELLYFIN_API_KEY not set"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Triggering Jellyfin library scan..."
# `if curl ...; then` (not a bare statement): under set -e, a bare failing
# curl would abort the script right here, silently skipping both the
# success log line below and any error reporting - this runs every
# minute, so a Jellyfin restart (e.g. mid-deploy) would otherwise produce
# a string of unexplained early exits in the cron log.
if curl -sf -X POST "${JELLYFIN_URL}/Library/Refresh" \
    -H "X-Emby-Token: ${JELLYFIN_KEY}" \
    --max-time 10; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Library scan triggered."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to trigger Jellyfin library scan" >&2
    exit 1
fi
