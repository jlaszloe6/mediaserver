#!/bin/bash
# jellyfin-cleanup.sh - Detect items deleted from Jellyfin and remove from Sonarr/Radarr
#
# When a user deletes a movie/show from Jellyfin, the file is removed from disk.
# Sonarr/Radarr don't know about it and may try to re-download.
#
# This script:
# 1. Triggers a disk rescan in Sonarr/Radarr (updates hasFile status)
# 2. Compares current state with a saved snapshot
# 3. Items that previously had files but now don't → deleted from Jellyfin
# 4. Removes those items from Sonarr/Radarr with import exclusion
#    (prevents re-importing them)
#
# Run via cron every 30 minutes. On first run, only saves state (no deletions).

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
    esac
done

set -euo pipefail

# Load .env
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
SONARR_URL="http://sonarr:8989"
RADARR_URL="http://radarr:7878"

STATE_DIR="/var/tmp/mediaserver-cleanup"
mkdir -p "$STATE_DIR"

ERRORS=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Trigger a disk rescan and wait for completion (up to 2 minutes)
trigger_rescan() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"
    local command_name="$4"  # "RescanMovie" or "RescanSeries"

    log "  Triggering $command_name on $service_name..."

    local result
    result=$(curl -sf -X POST \
        -H "X-Api-Key: $api_key" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$command_name\"}" \
        "$base_url/api/v3/command") || {
        log "  ERROR: Failed to trigger $command_name on $service_name"
        ERRORS=$((ERRORS + 1))
        return 1
    }

    local cmd_id
    cmd_id=$(echo "$result" | jq -r '.id')

    # Poll for completion
    local i
    for i in $(seq 1 24); do
        sleep 5
        local status
        status=$(curl -sf -H "X-Api-Key: $api_key" \
            "$base_url/api/v3/command/$cmd_id" | jq -r '.status') || continue

        if [ "$status" = "completed" ]; then
            log "  $command_name completed"
            return 0
        elif [ "$status" = "failed" ]; then
            log "  ERROR: $command_name failed"
            ERRORS=$((ERRORS + 1))
            return 1
        fi
    done

    log "  WARN: $command_name timed out, proceeding with current state"
    return 0
}

# Process movies: detect deleted files and cleanup
process_movies() {
    local base_url="$1"
    local api_key="$2"
    local prev_state="$3"

    local movies
    movies=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/movie") || {
        log "  ERROR: Failed to fetch movies from Radarr"
        ERRORS=$((ERRORS + 1))
        echo "{}"
        return
    }

    local current_state
    current_state=$(echo "$movies" | jq '[.[] | {key: (.id | tostring), value: .hasFile}] | from_entries')

    local deleted
    deleted=$(echo "$movies" | jq -c --argjson prev "$prev_state" '
        .[] | select(
            .hasFile == false and
            .monitored == true and
            ($prev[(.id | tostring)] // null) == true
        ) | {id, title}
    ')

    if [ -n "$deleted" ]; then
        local count=0
        while IFS= read -r item; do
            [ -z "$item" ] && continue
            local id title del_code
            id=$(echo "$item" | jq -r '.id')
            title=$(echo "$item" | jq -r '.title')

            if $DRY_RUN; then
                log "  [DRY RUN] Would remove movie '$title' (id=$id)"
                count=$((count + 1))
                continue
            fi

            del_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
                -H "X-Api-Key: $api_key" \
                "$base_url/api/v3/movie/$id?deleteFiles=true&addImportExclusion=true")

            if [ "$del_code" = "200" ]; then
                log "  Removed movie '$title' (deleted from library, excluded from re-import)"
                count=$((count + 1))
            else
                log "  ERROR: Failed to remove movie '$title' (HTTP $del_code)"
                ERRORS=$((ERRORS + 1))
            fi
        done <<< "$deleted"
        log "  Cleaned up $count movie(s) deleted from library"
    else
        log "  No movies deleted since last check"
    fi

    echo "$movies" | jq '[.[] | {key: (.id | tostring), value: .hasFile}] | from_entries'
}

# Process series: detect deleted files and cleanup
process_series() {
    local base_url="$1"
    local api_key="$2"
    local prev_state="$3"

    local series
    series=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/series") || {
        log "  ERROR: Failed to fetch series from Sonarr"
        ERRORS=$((ERRORS + 1))
        echo "{}"
        return
    }

    local current_state
    current_state=$(echo "$series" | jq '[.[] | {key: (.id | tostring), value: (.statistics.sizeOnDisk // 0)}] | from_entries')

    local deleted
    deleted=$(echo "$series" | jq -c --argjson prev "$prev_state" '
        .[] | select(
            (.statistics.sizeOnDisk // 0) == 0 and
            .monitored == true and
            ($prev[(.id | tostring)] // 0) > 0
        ) | {id, title}
    ')

    if [ -n "$deleted" ]; then
        local count=0
        while IFS= read -r item; do
            [ -z "$item" ] && continue
            local id title del_code
            id=$(echo "$item" | jq -r '.id')
            title=$(echo "$item" | jq -r '.title')

            if $DRY_RUN; then
                log "  [DRY RUN] Would remove series '$title' (id=$id)"
                count=$((count + 1))
                continue
            fi

            del_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
                -H "X-Api-Key: $api_key" \
                "$base_url/api/v3/series/$id?deleteFiles=true&addImportListExclusion=true")

            if [ "$del_code" = "200" ]; then
                log "  Removed series '$title' (deleted from library, excluded from re-import)"
                count=$((count + 1))
            else
                log "  ERROR: Failed to remove series '$title' (HTTP $del_code)"
                ERRORS=$((ERRORS + 1))
            fi
        done <<< "$deleted"
        log "  Cleaned up $count series deleted from library"
    else
        log "  No series deleted since last check"
    fi

    echo "$current_state"
}

# --- Process ---

STATE_FILE="$STATE_DIR/file-state-owner.json"

log "=== Library deletion cleanup ==="

log "Rescanning disk..."
trigger_rescan "Radarr" "$RADARR_URL" "$RADARR_KEY" "RescanMovie"
trigger_rescan "Sonarr" "$SONARR_URL" "$SONARR_KEY" "RescanSeries"

prev_movies="{}"
prev_series="{}"
if [ -f "$STATE_FILE" ]; then
    prev_movies=$(jq '.movies // {}' "$STATE_FILE")
    prev_series=$(jq '.series // {}' "$STATE_FILE")
    log "Loaded previous state from $STATE_FILE"
else
    log "No previous state found — first run, saving baseline only"
fi

log "Checking Radarr movies..."
new_movies=$(process_movies "$RADARR_URL" "$RADARR_KEY" "$prev_movies")

log "Checking Sonarr series..."
new_series=$(process_series "$SONARR_URL" "$SONARR_KEY" "$prev_series")

jq -n \
    --argjson movies "$new_movies" \
    --argjson series "$new_series" \
    '{movies: $movies, series: $series}' > "$STATE_FILE"

log "State saved to $STATE_FILE"

# --- Clean up orphaned Transmission torrents ---
log "=== Transmission orphan cleanup ==="
CLEANUP_ARGS=""
$DRY_RUN && CLEANUP_ARGS="--dry-run"
"$SCRIPT_DIR/transmission-cleanup.sh" $CLEANUP_ARGS 2>&1 | while IFS= read -r line; do log "$line"; done || {
    log "WARN: transmission-cleanup.sh had errors"
    ERRORS=$((ERRORS + 1))
}

if [ "$ERRORS" -gt 0 ]; then
    log "=== Done with $ERRORS error(s) ==="
    exit 1
else
    log "=== Done ==="
fi
