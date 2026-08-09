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
source "$SCRIPT_DIR/lib/curl-secrets.sh"
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

# See process_movies/process_series: they run in a subshell (command
# substitution) and can't mutate ERRORS directly, so they append their own
# error counts here instead.
ERRORS_FILE=$(mktemp)
trap 'rm -f "$ERRORS_FILE"' EXIT

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
#
# Called via command substitution (new_movies=$(process_movies ...)), which
# runs this entire function in a subshell - any `ERRORS=$((ERRORS + 1))`
# here would be invisible to the caller once the subshell exits. `errors_file`
# is how a failure inside this function reaches the top-level ERRORS count;
# writing to a file crosses the subshell boundary, mutating a variable does
# not.
process_movies() {
    local base_url="$1"
    local api_key="$2"
    local prev_state="$3"
    local errors_file="$4"

    local errors=0

    local movies
    movies=$(curl -sf --max-time 15 -H "X-Api-Key: $api_key" "$base_url/api/v3/movie") || {
        log "  ERROR: Failed to fetch movies from Radarr"
        errors=$((errors + 1))
        echo "$errors" >> "$errors_file"
        # Return the PREVIOUS state unchanged, not {} - the caller saves
        # whatever this function outputs as the new baseline. Saving {}
        # here would wipe out every movie's true baseline on one transient
        # fetch failure, and the next run's true->false transition check
        # (which needs prev[id] == true) could then never fire for
        # whatever was already deleted from Jellyfin before this failure.
        echo "$prev_state"
        return
    }

    local deleted
    deleted=$(echo "$movies" | jq -c --argjson prev "$prev_state" '
        .[] | select(
            .hasFile == false and
            .monitored == true and
            ($prev[(.id | tostring)] // null) == true
        ) | {id, title}
    ')

    # IDs whose deletion attempt failed - their hasFile in the state we save
    # below must NOT be updated to the real (false) value. If it were, the
    # true->false transition detected this run would already look "seen"
    # next run (prev[id] would already be false), so a transient delete
    # failure would silently cancel the retry forever even though the
    # movie is still sitting in Radarr, monitored, and not excluded from
    # re-import.
    local failed_ids="[]"

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

            # `|| del_code="000"`: without it, a transport-level curl
            # failure (Radarr mid-restart, network blip) would abort the
            # whole script right here under set -e, before the existing
            # HTTP-status check below ever ran - "000" correctly falls
            # into that check's else branch instead, so a delete that
            # never actually happened can't be silently treated as done.
            del_code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -X DELETE \
                -H "X-Api-Key: $api_key" \
                "$base_url/api/v3/movie/$id?deleteFiles=true&addImportExclusion=true") || del_code="000"

            if [ "$del_code" = "200" ]; then
                log "  Removed movie '$title' (deleted from library, excluded from re-import)"
                count=$((count + 1))
            else
                log "  ERROR: Failed to remove movie '$title' (HTTP $del_code)"
                errors=$((errors + 1))
                failed_ids=$(echo "$failed_ids" | jq -c --argjson id "$id" '. + [$id]')
            fi
        done <<< "$deleted"
        log "  Cleaned up $count movie(s) deleted from library"
    else
        log "  No movies deleted since last check"
    fi

    echo "$errors" >> "$errors_file"
    echo "$movies" | jq --argjson prev "$prev_state" --argjson failed "$failed_ids" '
        [.[] | {key: (.id | tostring), value: (if (.id | IN($failed[])) then ($prev[(.id | tostring)] // .hasFile) else .hasFile end)}] | from_entries
    '
}

# Process series: detect deleted files and cleanup
# See process_movies' comment above re: errors_file and the subshell boundary.
process_series() {
    local base_url="$1"
    local api_key="$2"
    local prev_state="$3"
    local errors_file="$4"

    local errors=0

    local series
    series=$(curl -sf --max-time 15 -H "X-Api-Key: $api_key" "$base_url/api/v3/series") || {
        log "  ERROR: Failed to fetch series from Sonarr"
        errors=$((errors + 1))
        echo "$errors" >> "$errors_file"
        # See process_movies' matching comment above - return the previous
        # state, not {}, so a transient fetch failure can't wipe the
        # baseline needed to detect an already-deleted series next run.
        echo "$prev_state"
        return
    }

    local deleted
    deleted=$(echo "$series" | jq -c --argjson prev "$prev_state" '
        .[] | select(
            (.statistics.sizeOnDisk // 0) == 0 and
            .monitored == true and
            ($prev[(.id | tostring)] // 0) > 0
        ) | {id, title}
    ')

    # See process_movies' matching comment above re: failed_ids and why
    # a failed deletion must not advance the saved state for that item.
    local failed_ids="[]"

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

            # Same set -e guard as the movie DELETE above.
            del_code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -X DELETE \
                -H "X-Api-Key: $api_key" \
                "$base_url/api/v3/series/$id?deleteFiles=true&addImportListExclusion=true") || del_code="000"

            if [ "$del_code" = "200" ]; then
                log "  Removed series '$title' (deleted from library, excluded from re-import)"
                count=$((count + 1))
            else
                log "  ERROR: Failed to remove series '$title' (HTTP $del_code)"
                errors=$((errors + 1))
                failed_ids=$(echo "$failed_ids" | jq -c --argjson id "$id" '. + [$id]')
            fi
        done <<< "$deleted"
        log "  Cleaned up $count series deleted from library"
    else
        log "  No series deleted since last check"
    fi

    echo "$errors" >> "$errors_file"
    echo "$series" | jq --argjson prev "$prev_state" --argjson failed "$failed_ids" '
        [.[] | {key: (.id | tostring), value: (if (.id | IN($failed[])) then ($prev[(.id | tostring)] // (.statistics.sizeOnDisk // 0)) else (.statistics.sizeOnDisk // 0) end)}] | from_entries
    '
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
new_movies=$(process_movies "$RADARR_URL" "$RADARR_KEY" "$prev_movies" "$ERRORS_FILE")

log "Checking Sonarr series..."
new_series=$(process_series "$SONARR_URL" "$SONARR_KEY" "$prev_series" "$ERRORS_FILE")

# Sum up whatever process_movies/process_series recorded - see their
# shared comment above for why this can't just be a variable increment.
while IFS= read -r n; do
    ERRORS=$((ERRORS + n))
done < "$ERRORS_FILE"

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
