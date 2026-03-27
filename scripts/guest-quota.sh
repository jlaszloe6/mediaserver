#!/bin/bash
# guest-quota.sh - Enforce shared storage quota for guest media
#
# Checks combined size of guest-tv and guest-movies directories.
# If over quota, pauses guest torrents in Transmission.
# If under quota, resumes any paused guest torrents.
#
# Run every 15 minutes via cron, and called at end of trakt-sync.

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

MEDIA_ROOT="${MEDIA_ROOT:-/mnt/mediaserver}"
GUEST_QUOTA_GB="${GUEST_QUOTA_GB:-100}"
TRANSMISSION_URL="http://transmission:9091/transmission/rpc"
GUEST_CATEGORIES="guest-sonarr|guest-radarr"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

transmission_rpc() {
    curl -sf "$TRANSMISSION_URL" \
        -H "X-Transmission-Session-Id: $1" \
        -H "Content-Type: application/json" \
        -d "$2" 2>/dev/null
}

log "=== Guest quota check ==="

# Calculate usage
GUEST_TV_DIR="$MEDIA_ROOT/media/guest-tv"
GUEST_MOVIES_DIR="$MEDIA_ROOT/media/guest-movies"

usage=0
if [ -d "$GUEST_TV_DIR" ]; then
    usage=$((usage + $(du -sb "$GUEST_TV_DIR" 2>/dev/null | awk '{print $1}')))
fi
if [ -d "$GUEST_MOVIES_DIR" ]; then
    usage=$((usage + $(du -sb "$GUEST_MOVIES_DIR" 2>/dev/null | awk '{print $1}')))
fi

quota=$((GUEST_QUOTA_GB * 1073741824))
usage_gb=$(python3 -c "print(f'{$usage / 1073741824:.1f}')")

log "Guest usage: ${usage_gb} GB / ${GUEST_QUOTA_GB} GB"

# Connect to Transmission
SID=$(curl -si "$TRANSMISSION_URL" 2>/dev/null \
    | grep -oP '(?<=X-Transmission-Session-Id: )\S+' | head -1) || true
if [ -z "$SID" ]; then
    log "ERROR: Cannot connect to Transmission"
    exit 1
fi

# Get guest torrents (by download directory containing guest categories)
guest_torrents=$(transmission_rpc "$SID" '{
    "method": "torrent-get",
    "arguments": {
        "fields": ["id", "name", "status", "downloadDir"]
    }
}' | jq -c "[.arguments.torrents[] | select(.downloadDir | test(\"($GUEST_CATEGORIES)\"))]")

guest_count=$(echo "$guest_torrents" | jq 'length')

if [ "$guest_count" -eq 0 ]; then
    log "No guest torrents found"
    exit 0
fi

if [ "$usage" -gt "$quota" ]; then
    log "OVER QUOTA — pausing guest torrents"
    # Find active (downloading) guest torrents and pause them
    active_ids=$(echo "$guest_torrents" | jq -c '[.[] | select(.status == 4) | .id]')
    active_count=$(echo "$active_ids" | jq 'length')
    if [ "$active_count" -gt 0 ]; then
        transmission_rpc "$SID" "{\"method\":\"torrent-stop\",\"arguments\":{\"ids\":$active_ids}}" > /dev/null
        log "Paused $active_count guest torrent(s)"
    else
        log "No active guest torrents to pause"
    fi
else
    # Resume any stopped guest torrents
    stopped_ids=$(echo "$guest_torrents" | jq -c '[.[] | select(.status == 0) | .id]')
    stopped_count=$(echo "$stopped_ids" | jq 'length')
    if [ "$stopped_count" -gt 0 ]; then
        transmission_rpc "$SID" "{\"method\":\"torrent-start\",\"arguments\":{\"ids\":$stopped_ids}}" > /dev/null
        log "Resumed $stopped_count paused guest torrent(s)"
    else
        log "All guest torrents running, quota OK"
    fi
fi
