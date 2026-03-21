#!/bin/bash
# transmission-cleanup.sh - Remove orphaned torrents from Transmission
#
# Finds completed torrents whose media has been deleted from Sonarr/Radarr
# and removes them — with different rules for private vs public trackers.
#
# Private trackers (nCore, etc.) have hit-and-run policies:
#   → Must seed for at least HNR_HOURS (72h) after download completes
#   → After that, remove if orphaned
#
# Public trackers (1337x, YTS, TPB, etc.) have no seed obligation:
#   → Remove immediately if orphaned (media deleted from library)
#
# Detection: Cross-references torrent hashes against Sonarr/Radarr download
# history. Falls back to filesystem hardlink check for old hashes.
#
# Called by: trakt-sync.sh, plex-cleanup.sh, or standalone.

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
    esac
done

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

SONARR_KEY="$SONARR_API_KEY"
RADARR_KEY="$RADARR_API_KEY"
SONARR_GUEST_KEY="${SONARR_GUEST_API_KEY:-}"
RADARR_GUEST_KEY="${RADARR_GUEST_API_KEY:-}"

# Instance configs: "sonarr_url|sonarr_key|radarr_url|radarr_key"
INSTANCE_CONFIGS="http://localhost:8989|$SONARR_KEY|http://localhost:7878|$RADARR_KEY"
if [ -n "$SONARR_GUEST_KEY" ] && [ -n "$RADARR_GUEST_KEY" ]; then
    INSTANCE_CONFIGS="$INSTANCE_CONFIGS
http://localhost:8990|$SONARR_GUEST_KEY|http://localhost:7879|$RADARR_GUEST_KEY"
fi

TRANSMISSION_URL="http://localhost:9091/transmission/rpc"

# --- Hit-and-run configuration ---
# Tracker domains with H&R policies and their minimum seed hours.
# Add new private trackers here as needed.
# Format: "domain:hours" — if any tracker URL contains the domain, it's matched.
HNR_TRACKERS=(
    "ncore.pro:72"
    "ncore.sh:72"
)

# Default minimum seed hours for unrecognized private trackers (safety net)
HNR_DEFAULT_HOURS=72

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

# Returns the required H&R seed hours for a torrent, or 0 if public
get_hnr_hours() {
    local is_private="$1"
    local tracker_domains="$2"  # space-separated list of tracker domains

    # Public trackers: no seed obligation
    if [ "$is_private" != "true" ]; then
        echo 0
        return
    fi

    # Check against known H&R trackers
    for entry in "${HNR_TRACKERS[@]}"; do
        local domain="${entry%%:*}"
        local hours="${entry#*:}"
        if echo "$tracker_domains" | grep -q "$domain" 2>/dev/null; then
            echo "$hours"
            return
        fi
    done

    # Unknown private tracker: use safe default
    echo "$HNR_DEFAULT_HOURS"
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

# --- Build orphan detection data (from ALL instances) ---
QUEUE_HASHES=$(mktemp)
RADARR_IDS=$(mktemp)
SONARR_IDS=$(mktemp)
HISTORY_MAP=$(mktemp)

while IFS= read -r inst; do
    [ -z "$inst" ] && continue
    IFS='|' read -r s_url s_key r_url r_key <<< "$inst"

    # Queue hashes
    curl -sf -H "X-Api-Key: $s_key" "$s_url/api/v3/queue?pageSize=200" 2>/dev/null \
        | jq -r '.records[].downloadId // empty' 2>/dev/null >> "$QUEUE_HASHES" || true
    curl -sf -H "X-Api-Key: $r_key" "$r_url/api/v3/queue?pageSize=200" 2>/dev/null \
        | jq -r '.records[].downloadId // empty' 2>/dev/null >> "$QUEUE_HASHES" || true

    # Library IDs
    curl -sf -H "X-Api-Key: $r_key" "$r_url/api/v3/movie" 2>/dev/null \
        | jq -r '.[].id' >> "$RADARR_IDS" || true
    curl -sf -H "X-Api-Key: $s_key" "$s_url/api/v3/series" 2>/dev/null \
        | jq -r '.[].id' >> "$SONARR_IDS" || true

    # History mapping
    curl -sf -H "X-Api-Key: $r_key" "$r_url/api/v3/history?pageSize=500" 2>/dev/null \
        | jq -r '.records[] | select(.downloadId != null) | "R:" + (.downloadId | ascii_downcase) + ":" + (.movieId | tostring)' 2>/dev/null >> "$HISTORY_MAP" || true
    curl -sf -H "X-Api-Key: $s_key" "$s_url/api/v3/history?pageSize=500" 2>/dev/null \
        | jq -r '.records[] | select(.downloadId != null) | "S:" + (.downloadId | ascii_downcase) + ":" + (.seriesId | tostring)' 2>/dev/null >> "$HISTORY_MAP" || true
done <<< "$INSTANCE_CONFIGS"

# Deduplicate and normalize
sort -u -o "$QUEUE_HASHES" "$QUEUE_HASHES"
tr '[:upper:]' '[:lower:]' < "$QUEUE_HASHES" > "$QUEUE_HASHES.tmp" && mv "$QUEUE_HASHES.tmp" "$QUEUE_HASHES"
sort -u -o "$RADARR_IDS" "$RADARR_IDS"
sort -u -o "$SONARR_IDS" "$SONARR_IDS"
sort -u -o "$HISTORY_MAP" "$HISTORY_MAP"

# --- Get torrents (with tracker info) ---
TMPFILE=$(mktemp)
trap 'rm -f "$QUEUE_HASHES" "$RADARR_IDS" "$SONARR_IDS" "$HISTORY_MAP" "$TMPFILE"' EXIT

transmission_rpc "$SID" '{
    "method": "torrent-get",
    "arguments": {
        "fields": ["id","name","hashString","downloadDir","percentDone","status","uploadRatio",
                    "seedRatioLimit","seedRatioMode","isFinished","doneDate","activityDate",
                    "trackers","isPrivate"]
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
    DONE_DATE=$(echo "$torrent" | jq -r '.doneDate')
    IS_PRIVATE=$(echo "$torrent" | jq -r '.isPrivate')
    TRACKER_DOMAINS=$(echo "$torrent" | jq -r '[.trackers[].announce] | map(split("/")[2] // empty) | unique | join(" ")')

    # Skip incomplete downloads
    if ! float_gte "$PERCENT" "1.0"; then
        continue
    fi

    # Skip if still in active download queue
    if grep -qx "$HASH" "$QUEUE_HASHES" 2>/dev/null; then
        KEPT=$((KEPT + 1))
        continue
    fi

    # --- Check if orphaned ---
    ORPHANED=false

    MOVIE_ID=$(grep "^R:${HASH}:" "$HISTORY_MAP" 2>/dev/null | head -1 | cut -d: -f3 || true)
    if [ -n "$MOVIE_ID" ]; then
        if ! grep -qx "$MOVIE_ID" "$RADARR_IDS" 2>/dev/null; then
            ORPHANED=true
        fi
    fi

    if ! $ORPHANED; then
        SERIES_ID=$(grep "^S:${HASH}:" "$HISTORY_MAP" 2>/dev/null | head -1 | cut -d: -f3 || true)
        if [ -n "$SERIES_ID" ]; then
            if ! grep -qx "$SERIES_ID" "$SONARR_IDS" 2>/dev/null; then
                ORPHANED=true
            fi
        fi
    fi

    # Fallback: filesystem hardlink check for old torrents not in history
    if ! $ORPHANED && [ -z "$MOVIE_ID" ] && [ -z "$SERIES_ID" ]; then
        DLDIR=$(echo "$torrent" | jq -r '.downloadDir // empty' 2>/dev/null || true)
        if [ -n "$DLDIR" ]; then
            HOST_DIR="${DLDIR/#\/downloads//mnt/mediaserver/torrents}"
            MAIN_FILE=$(transmission_rpc "$SID" \
                "{\"method\":\"torrent-get\",\"arguments\":{\"ids\":[$ID],\"fields\":[\"files\"]}}" \
                | jq -r '[.arguments.torrents[0].files[] | {name, length}] | sort_by(-.length) | .[0].name // empty')
            if [ -n "$MAIN_FILE" ]; then
                FULL_PATH="$HOST_DIR/$MAIN_FILE"
                if [ ! -e "$FULL_PATH" ]; then
                    ORPHANED=true
                elif [ "$(stat -c '%h' "$FULL_PATH" 2>/dev/null || echo 2)" = "1" ]; then
                    ORPHANED=true
                fi
            fi
        fi
    fi

    if ! $ORPHANED; then
        KEPT=$((KEPT + 1))
        continue
    fi

    # --- Orphaned: determine removal eligibility based on tracker type ---
    HNR_HOURS=$(get_hnr_hours "$IS_PRIVATE" "$TRACKER_DOMAINS")
    CAN_REMOVE=false
    REASON=""

    if [ "$HNR_HOURS" = "0" ]; then
        # Public tracker: no seed obligation, remove immediately
        CAN_REMOVE=true
        REASON="public tracker, no seed obligation"
    else
        # Private tracker with H&R policy
        # Check 1: Transmission says seeding is done
        if [ "$IS_FINISHED" = "true" ]; then
            CAN_REMOVE=true
            REASON="isFinished=true (seed goal met)"
        fi

        # Check 2: Ratio met
        if ! $CAN_REMOVE; then
            EFFECTIVE_LIMIT="$SEED_RATIO_LIMIT"
            if [ "$RATIO_MODE" = "1" ]; then
                EFFECTIVE_LIMIT="$RATIO_LIMIT"
            fi
            if float_gte "$RATIO" "$EFFECTIVE_LIMIT"; then
                CAN_REMOVE=true
                REASON="ratio=$RATIO >= limit=$EFFECTIVE_LIMIT"
            fi
        fi

        # Check 3: H&R period elapsed (time since download completed)
        if ! $CAN_REMOVE && [ "${DONE_DATE:-0}" -gt 0 ] 2>/dev/null; then
            SEED_SECONDS=$((NOW - DONE_DATE))
            REQUIRED_SECONDS=$((HNR_HOURS * 3600))
            if [ "$SEED_SECONDS" -ge "$REQUIRED_SECONDS" ]; then
                CAN_REMOVE=true
                REASON="h&r period done (${SEED_SECONDS}s >= ${REQUIRED_SECONDS}s / ${HNR_HOURS}h)"
            else
                REMAINING=$(( (REQUIRED_SECONDS - SEED_SECONDS) / 3600 ))
                log "  Waiting (H&R ${HNR_HOURS}h): $NAME (~${REMAINING}h remaining, ratio=$RATIO)"
                SKIPPED=$((SKIPPED + 1))
                continue
            fi
        fi

        if ! $CAN_REMOVE; then
            log "  Skipped (private, seeding): $NAME (ratio=$RATIO, status=$STATUS, h&r=${HNR_HOURS}h)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    # --- Remove the orphaned torrent ---
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
done < "$TMPFILE"

log "Done: removed=$REMOVED skipped=$SKIPPED kept=$KEPT"
