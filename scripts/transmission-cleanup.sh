#!/bin/bash
# transmission-cleanup.sh - Remove orphaned torrents from Transmission
#
# Finds completed torrents whose media has been deleted from Sonarr/Radarr
# and removes them — but only if the seeding obligation is met.
#
# Detection: Cross-references torrent hashes against Sonarr/Radarr download
# history. If the hash maps to a movie/series that no longer exists in the
# library, the torrent is orphaned.
#
# Seeding obligation is met when ANY of:
#   - isFinished=true (Transmission considers seeding done)
#   - Upload ratio >= effective seed ratio limit
#   - Stopped (status=0) and idle > 30 minutes
#
# Also deletes leftover files (srt, sample, nfo) since hardlinks mean the
# download dir copy persists even after Sonarr/Radarr delete the media copy.
#
# Called by: trakt-sync.sh, plex-cleanup.sh, or standalone via cron.

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
    esac
done

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    SONARR_KEY=$(grep -m1 '^SONARR_API_KEY=' "$ENV_FILE" | cut -d= -f2-)
    RADARR_KEY=$(grep -m1 '^RADARR_API_KEY=' "$ENV_FILE" | cut -d= -f2-)
else
    echo "ERROR: .env file not found at $ENV_FILE" >&2
    exit 1
fi

SONARR_URL="http://localhost:8989"
RADARR_URL="http://localhost:7878"
TRANSMISSION_URL="http://localhost:9091/transmission/rpc"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

transmission_rpc() {
    curl -sf "$TRANSMISSION_URL" \
        -H "X-Transmission-Session-Id: $1" \
        -H "Content-Type: application/json" \
        -d "$2" 2>/dev/null
}

float_gte() {
    python3 -c "import sys; sys.exit(0 if float('$1') >= float('$2') else 1)"
}

log "=== Transmission orphan cleanup ==="

# --- Connect to Transmission ---
SID=$(curl -si "$TRANSMISSION_URL" 2>/dev/null \
    | grep -oP '(?<=X-Transmission-Session-Id: )\S+' | head -1) || true
if [ -z "$SID" ]; then
    log "ERROR: Cannot connect to Transmission"
    exit 1
fi

SEED_RATIO_LIMIT=$(transmission_rpc "$SID" \
    '{"method":"session-get","arguments":{"fields":["seedRatioLimit"]}}' \
    | jq -r '.arguments.seedRatioLimit // 2.0')
log "Session seed ratio limit: $SEED_RATIO_LIMIT"

# --- Build orphan detection data ---

# Active download queue hashes (these torrents are still being managed)
QUEUE_HASHES=$(mktemp)
{
    curl -sf -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/queue?pageSize=200" 2>/dev/null \
        | jq -r '.records[].downloadId // empty' 2>/dev/null
    curl -sf -H "X-Api-Key: $RADARR_KEY" "$RADARR_URL/api/v3/queue?pageSize=200" 2>/dev/null \
        | jq -r '.records[].downloadId // empty' 2>/dev/null
} | tr '[:upper:]' '[:lower:]' | sort -u > "$QUEUE_HASHES"

# Current library IDs
RADARR_IDS=$(mktemp)
SONARR_IDS=$(mktemp)
curl -sf -H "X-Api-Key: $RADARR_KEY" "$RADARR_URL/api/v3/movie" 2>/dev/null \
    | jq -r '.[].id' > "$RADARR_IDS"
curl -sf -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/series" 2>/dev/null \
    | jq -r '.[].id' > "$SONARR_IDS"

# History: hash → item ID mapping
# Radarr: hash:movieId, Sonarr: hash:seriesId
HISTORY_MAP=$(mktemp)
{
    curl -sf -H "X-Api-Key: $RADARR_KEY" "$RADARR_URL/api/v3/history?pageSize=500" 2>/dev/null \
        | jq -r '.records[] | select(.downloadId != null) | "R:" + (.downloadId | ascii_downcase) + ":" + (.movieId | tostring)' 2>/dev/null
    curl -sf -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/history?pageSize=500" 2>/dev/null \
        | jq -r '.records[] | select(.downloadId != null) | "S:" + (.downloadId | ascii_downcase) + ":" + (.seriesId | tostring)' 2>/dev/null
} | sort -u > "$HISTORY_MAP"

trap 'rm -f "$QUEUE_HASHES" "$RADARR_IDS" "$SONARR_IDS" "$HISTORY_MAP" "$TMPFILE"' EXIT

# --- Get torrents ---
TMPFILE=$(mktemp)
transmission_rpc "$SID" '{
    "method": "torrent-get",
    "arguments": {
        "fields": ["id","name","hashString","percentDone","status","uploadRatio",
                    "seedRatioLimit","seedRatioMode","isFinished","activityDate"]
    }
}' | jq -c '.arguments.torrents[]' > "$TMPFILE"

REMOVED=0
SKIPPED=0
KEPT=0
NOW=$(date +%s)

while IFS= read -r torrent; do
    NAME=$(echo "$torrent" | jq -r '.name')
    ID=$(echo "$torrent" | jq -r '.id')
    HASH=$(echo "$torrent" | jq -r '.hashString')
    PERCENT=$(echo "$torrent" | jq -r '.percentDone')
    STATUS=$(echo "$torrent" | jq -r '.status')
    RATIO=$(echo "$torrent" | jq -r '.uploadRatio')
    RATIO_MODE=$(echo "$torrent" | jq -r '.seedRatioMode')
    RATIO_LIMIT=$(echo "$torrent" | jq -r '.seedRatioLimit')
    IS_FINISHED=$(echo "$torrent" | jq -r '.isFinished')
    ACTIVITY_DATE=$(echo "$torrent" | jq -r '.activityDate')

    # Skip incomplete downloads
    if ! float_gte "$PERCENT" "1.0"; then
        continue
    fi

    # Skip if still in active download queue
    if grep -qx "$HASH" "$QUEUE_HASHES" 2>/dev/null; then
        KEPT=$((KEPT + 1))
        continue
    fi

    # Check if this torrent's media has been deleted from library
    ORPHANED=false

    # Look up in Radarr history
    MOVIE_ID=$(grep "^R:${HASH}:" "$HISTORY_MAP" 2>/dev/null | head -1 | cut -d: -f3 || true)
    if [ -n "$MOVIE_ID" ]; then
        if ! grep -qx "$MOVIE_ID" "$RADARR_IDS" 2>/dev/null; then
            ORPHANED=true
        fi
    fi

    # Look up in Sonarr history (if not already found in Radarr)
    if ! $ORPHANED; then
        SERIES_ID=$(grep "^S:${HASH}:" "$HISTORY_MAP" 2>/dev/null | head -1 | cut -d: -f3 || true)
        if [ -n "$SERIES_ID" ]; then
            if ! grep -qx "$SERIES_ID" "$SONARR_IDS" 2>/dev/null; then
                ORPHANED=true
            fi
        fi
    fi

    # Fallback: if hash not found in any history, check if main media file
    # has been deleted (hardlink count = 1 means no media folder copy exists)
    if ! $ORPHANED && [ -z "$MOVIE_ID" ] && [ -z "$SERIES_ID" ]; then
        # Hash not in history (rotated out) — check filesystem
        # Get the download dir and map to host path
        DLDIR=$(echo "$torrent" | jq -r '.downloadDir // empty' 2>/dev/null || true)
        if [ -z "$DLDIR" ]; then
            # Need downloadDir — fetch it
            DLDIR=$(transmission_rpc "$SID" \
                "{\"method\":\"torrent-get\",\"arguments\":{\"ids\":[$ID],\"fields\":[\"downloadDir\"]}}" \
                | jq -r '.arguments.torrents[0].downloadDir // empty')
        fi
        if [ -n "$DLDIR" ]; then
            HOST_DIR="${DLDIR/#\/downloads//mnt/mediaserver/torrents}"
            # Get largest file from this torrent
            MAIN_FILE=$(transmission_rpc "$SID" \
                "{\"method\":\"torrent-get\",\"arguments\":{\"ids\":[$ID],\"fields\":[\"files\"]}}" \
                | jq -r '[.arguments.torrents[0].files[] | {name, length}] | sort_by(-.length) | .[0].name // empty')
            if [ -n "$MAIN_FILE" ]; then
                FULL_PATH="$HOST_DIR/$MAIN_FILE"
                if [ ! -e "$FULL_PATH" ]; then
                    # Main file deleted entirely
                    ORPHANED=true
                elif [ "$(stat -c '%h' "$FULL_PATH" 2>/dev/null || echo 2)" = "1" ]; then
                    # File exists but hardlink count = 1 → media folder copy was deleted
                    ORPHANED=true
                fi
            fi
        fi
    fi

    if ! $ORPHANED; then
        KEPT=$((KEPT + 1))
        continue
    fi

    # --- Orphaned torrent: check seeding obligation ---
    SEED_MET=false
    REASON=""

    if [ "$IS_FINISHED" = "true" ]; then
        SEED_MET=true
        REASON="isFinished=true"
    fi

    if ! $SEED_MET; then
        EFFECTIVE_LIMIT="$SEED_RATIO_LIMIT"
        if [ "$RATIO_MODE" = "1" ]; then
            EFFECTIVE_LIMIT="$RATIO_LIMIT"
        elif [ "$RATIO_MODE" = "2" ]; then
            EFFECTIVE_LIMIT="999999"
        fi
        if float_gte "$RATIO" "$EFFECTIVE_LIMIT"; then
            SEED_MET=true
            REASON="ratio=$RATIO >= limit=$EFFECTIVE_LIMIT"
        fi
    fi

    # Note: we intentionally do NOT auto-remove stopped/idle torrents.
    # Private trackers (e.g. nCore) track seeding obligations server-side.
    # A torrent stopped with ratio 0.0 may still have hit-and-run penalties.
    # Only isFinished=true and ratio >= limit are safe removal signals.

    if $SEED_MET; then
        if $DRY_RUN; then
            log "  [DRY RUN] Would remove orphan: $NAME ($REASON)"
        else
            RESULT=$(transmission_rpc "$SID" \
                "{\"method\":\"torrent-remove\",\"arguments\":{\"ids\":[$ID],\"delete-local-data\":true}}")
            if [ "$(echo "$RESULT" | jq -r '.result // "error"')" = "success" ]; then
                log "  Removed orphan + data: $NAME ($REASON)"
            else
                log "  ERROR: Failed to remove '$NAME'"
            fi
        fi
        REMOVED=$((REMOVED + 1))
    else
        log "  Skipped (still seeding): $NAME (ratio=$RATIO, status=$STATUS)"
        SKIPPED=$((SKIPPED + 1))
    fi
done < "$TMPFILE"

log "Done: removed=$REMOVED skipped=$SKIPPED kept=$KEPT"
