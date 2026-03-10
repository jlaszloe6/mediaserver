#!/bin/bash
# trakt-sync.sh - Force-refresh Trakt import lists and cleanup unmonitored items
#
# 1. Cycles (delete + recreate) all Trakt import lists to bust the 12-hour cache,
#    then triggers ImportListSync so newly watchlisted items appear quickly.
#
# 2. Deletes unmonitored items from Sonarr/Radarr (including files).
#    Items become unmonitored when removed from Trakt watchlist
#    (listSyncLevel=keepAndUnmonitor). This step cleans them up.
#
# Run hourly via cron. The cleanup catches items unmonitored in the previous run.

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
    esac
done

set -euo pipefail

# Load .env from the same directory as docker-compose.yml
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    # Export only the variables we need
    SONARR_KEY=$(grep -m1 '^SONARR_API_KEY=' "$ENV_FILE" | cut -d= -f2-)
    RADARR_KEY=$(grep -m1 '^RADARR_API_KEY=' "$ENV_FILE" | cut -d= -f2-)
else
    echo "ERROR: .env file not found at $ENV_FILE" >&2
    exit 1
fi

SONARR_URL="http://localhost:8989"
RADARR_URL="http://localhost:7878"

ERRORS=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cycle_trakt_lists() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"

    log "Processing $service_name..."

    # Get all import lists
    local lists
    lists=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/importlist") || {
        log "ERROR: Failed to fetch import lists from $service_name"
        ERRORS=$((ERRORS + 1))
        return 1
    }

    # Get IDs of trakt-type lists
    local trakt_ids
    trakt_ids=$(echo "$lists" | jq -r '.[] | select(.listType == "trakt") | .id')

    if [ -z "$trakt_ids" ]; then
        log "No Trakt import lists found in $service_name"
        return 0
    fi

    for id in $trakt_ids; do
        # Get the full config for this list
        local config
        config=$(echo "$lists" | jq ".[] | select(.id == $id)")
        local name
        name=$(echo "$config" | jq -r '.name')

        if $DRY_RUN; then log "  [DRY RUN] Would cycle '$name' (id=$id)"; continue; fi

        log "  Cycling '$name' (id=$id)..."

        # Strip the id field — API assigns a new one on create
        local create_payload
        create_payload=$(echo "$config" | jq 'del(.id)')

        # Delete the list
        local del_code
        del_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
            -H "X-Api-Key: $api_key" \
            "$base_url/api/v3/importlist/$id")

        if [ "$del_code" != "200" ]; then
            log "  ERROR: DELETE returned HTTP $del_code for '$name', skipping"
            ERRORS=$((ERRORS + 1))
            continue
        fi

        # Recreate it (forceSave bypasses validation that fails when watchlist is empty)
        local create_code
        local result
        result=$(curl -s -w '\n%{http_code}' -X POST \
            -H "X-Api-Key: $api_key" \
            -H "Content-Type: application/json" \
            -d "$create_payload" \
            "$base_url/api/v3/importlist?forceSave=true")

        create_code=$(echo "$result" | tail -1)
        result=$(echo "$result" | sed '$d')

        if [ "$create_code" = "201" ]; then
            local new_id
            new_id=$(echo "$result" | jq -r '.id')
            log "  Recreated '$name' (new id=$new_id)"
        else
            log "  WARN: POST returned HTTP $create_code for '$name', retrying without forceSave..."
            result=$(curl -s -w '\n%{http_code}' -X POST \
                -H "X-Api-Key: $api_key" \
                -H "Content-Type: application/json" \
                -d "$create_payload" \
                "$base_url/api/v3/importlist")

            create_code=$(echo "$result" | tail -1)
            result=$(echo "$result" | sed '$d')

            if [ "$create_code" = "201" ]; then
                local new_id
                new_id=$(echo "$result" | jq -r '.id')
                log "  Recreated '$name' (new id=$new_id)"
            else
                log "  ERROR: Failed to recreate '$name' (HTTP $create_code). Attempting restore..."
                # Re-add with original id to try to restore
                local restore_result
                restore_result=$(curl -s -w '\n%{http_code}' -X POST \
                    -H "X-Api-Key: $api_key" \
                    -H "Content-Type: application/json" \
                    -d "$(echo "$config" | jq 'del(.id)')" \
                    "$base_url/api/v3/importlist?forceSave=true")

                local restore_code
                restore_code=$(echo "$restore_result" | tail -1)
                if [ "$restore_code" = "201" ]; then
                    log "  Restored '$name' (cache NOT refreshed — token may be invalid)"
                else
                    log "  ERROR: Could not restore '$name'! Manual recreation needed."
                fi
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done
}

trigger_sync() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"

    curl -sf -X POST \
        -H "X-Api-Key: $api_key" \
        -H "Content-Type: application/json" \
        -d '{"name":"ImportListSync"}' \
        "$base_url/api/v3/command" > /dev/null || {
        log "ERROR: Failed to trigger ImportListSync on $service_name"
        ERRORS=$((ERRORS + 1))
        return 1
    }

    log "Triggered ImportListSync on $service_name"
}

log "=== Trakt import list force-refresh ==="

cycle_trakt_lists "Sonarr" "$SONARR_URL" "$SONARR_KEY"
cycle_trakt_lists "Radarr" "$RADARR_URL" "$RADARR_KEY"

trigger_sync "Sonarr" "$SONARR_URL" "$SONARR_KEY"
trigger_sync "Radarr" "$RADARR_URL" "$RADARR_KEY"

# --- Phase 2: Cleanup unmonitored items ---
# Items removed from Trakt become unmonitored (keepAndUnmonitor).
# Delete them from Sonarr/Radarr along with their files.
# Note: items unmonitored in THIS run's sync will be caught on the NEXT run.

cleanup_unmonitored() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"
    local api_endpoint="$4"   # "series" or "movie"
    local exclusion_param="$5" # "addImportListExclusion" (Sonarr) or "addImportExclusion" (Radarr)

    log "Cleaning up unmonitored items in $service_name..."

    local items
    items=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/$api_endpoint") || {
        log "ERROR: Failed to fetch $api_endpoint from $service_name"
        ERRORS=$((ERRORS + 1))
        return 1
    }

    local unmonitored
    unmonitored=$(echo "$items" | jq -c '.[] | select(.monitored == false) | {id, title}')

    if [ -z "$unmonitored" ]; then
        log "  No unmonitored items to clean up"
        return 0
    fi

    local count=0
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        local id title del_code
        id=$(echo "$item" | jq -r '.id')
        title=$(echo "$item" | jq -r '.title')

        if $DRY_RUN; then log "  [DRY RUN] Would delete '$title' (id=$id)"; count=$((count + 1)); continue; fi

        del_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
            -H "X-Api-Key: $api_key" \
            "$base_url/api/v3/$api_endpoint/$id?deleteFiles=true&$exclusion_param=false")

        if [ "$del_code" = "200" ]; then
            log "  Deleted '$title' (id=$id) with files"
            count=$((count + 1))
        else
            log "  ERROR: Failed to delete '$title' (HTTP $del_code)"
            ERRORS=$((ERRORS + 1))
        fi
    done <<< "$unmonitored"

    log "  Cleaned up $count unmonitored item(s) from $service_name"
}

log "=== Cleanup unmonitored items ==="

cleanup_unmonitored "Sonarr" "$SONARR_URL" "$SONARR_KEY" "series" "addImportListExclusion"
cleanup_unmonitored "Radarr" "$RADARR_URL" "$RADARR_KEY" "movie" "addImportExclusion"

if [ "$ERRORS" -gt 0 ]; then
    log "=== Done with $ERRORS error(s) ==="
    exit 1
else
    log "=== Done ==="
fi
