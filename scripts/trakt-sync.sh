#!/bin/bash
# trakt-sync.sh - Force-refresh Trakt import lists, cleanup, and reverse-sync
#
# Phase 1: Cycles (delete + recreate) all Trakt import lists to bust the 12-hour
#           cache, then triggers ImportListSync so newly watchlisted items appear quickly.
#           List configs are backed up to disk before deletion so tokens are never lost.
#
# Phase 2: Deletes unmonitored items from Sonarr/Radarr (including files).
#           Items become unmonitored when removed from Trakt watchlist
#           (listSyncLevel=keepAndUnmonitor). This step cleans them up.
#
# Phase 3: Reverse-sync — pushes all monitored items from Sonarr/Radarr to each
#           user's Trakt watchlist. This ensures Seerr requests appear in Trakt.
#
# Phase 4: Clean up orphaned Transmission torrents.
#
# Runs for both owner and guest instances (if guest API keys are set).
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

ERRORS=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

BACKUP_DIR="/var/tmp/mediaserver-trakt-backup"
mkdir -p "$BACKUP_DIR"

# --- Build instance list ---
# Format: "label|sonarr_url|sonarr_key|radarr_url|radarr_key"
INSTANCES="owner|http://localhost:8989|$SONARR_KEY|http://localhost:7878|$RADARR_KEY"
if [ -n "$SONARR_GUEST_KEY" ] && [ -n "$RADARR_GUEST_KEY" ]; then
    INSTANCES="$INSTANCES
guest|http://localhost:8990|$SONARR_GUEST_KEY|http://localhost:7879|$RADARR_GUEST_KEY"
fi

cycle_trakt_lists() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"
    local backup_label="$4"

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
        # Try to restore from backup
        local backup_file="$BACKUP_DIR/${backup_label}-lists.json"
        if [ -f "$backup_file" ]; then
            log "No Trakt import lists found — restoring from backup..."
            local backed_up
            backed_up=$(jq -c '.[]' "$backup_file")
            while IFS= read -r item; do
                [ -z "$item" ] && continue
                local bname
                bname=$(echo "$item" | jq -r '.name')
                local restore_code
                restore_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
                    -H "X-Api-Key: $api_key" \
                    -H "Content-Type: application/json" \
                    -d "$item" \
                    "$base_url/api/v3/importlist?forceSave=true")
                if [ "$restore_code" = "201" ]; then
                    log "  Restored '$bname' from backup"
                else
                    log "  ERROR: Failed to restore '$bname' (HTTP $restore_code)"
                    ERRORS=$((ERRORS + 1))
                fi
            done <<< "$backed_up"
        else
            log "No Trakt import lists found in $service_name (no backup available)"
        fi
        return 0
    fi

    # Save backup of all Trakt list configs (with tokens) before any deletion
    local backup_file="$BACKUP_DIR/${backup_label}-lists.json"
    echo "$lists" | jq '[.[] | select(.listType == "trakt") | del(.id)]' > "$backup_file"

    for id in $trakt_ids; do
        local config
        config=$(echo "$lists" | jq ".[] | select(.id == $id)")
        local name
        name=$(echo "$config" | jq -r '.name')

        if $DRY_RUN; then log "  [DRY RUN] Would cycle '$name' (id=$id)"; continue; fi

        log "  Cycling '$name' (id=$id)..."

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

        # Recreate with forceSave, retry up to 3 times
        local create_code=""
        local result=""
        local attempt
        for attempt in 1 2 3; do
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
                break
            fi
            [ "$attempt" -lt 3 ] && sleep 2
        done

        if [ "$create_code" != "201" ]; then
            log "  ERROR: Failed to recreate '$name' after 3 attempts (HTTP $create_code). Will restore from backup on next run."
            ERRORS=$((ERRORS + 1))
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

sync_to_trakt() {
    local instance_label="$1"
    local sonarr_url="$2"
    local sonarr_key="$3"
    local radarr_url="$4"
    local radarr_key="$5"

    log "=== Reverse-sync to Trakt watchlists ($instance_label) ==="

    if [ -z "${SONARR_TRAKT_CLIENT_ID:-}" ]; then
        log "WARN: SONARR_TRAKT_CLIENT_ID not set in .env, skipping reverse-sync"
        return 0
    fi

    # Extract per-user tokens from this instance's Sonarr Trakt import lists
    local lists
    lists=$(curl -sf -H "X-Api-Key: $sonarr_key" "$sonarr_url/api/v3/importlist") || {
        log "ERROR: Failed to fetch import lists from Sonarr ($instance_label) for token extraction"
        ERRORS=$((ERRORS + 1))
        return 1
    }

    # Build array of {user, token} from Trakt lists
    local user_tokens
    user_tokens=$(echo "$lists" | jq -c '
        [.[] | select(.listType == "trakt") |
         { user: (.fields[] | select(.name == "authUser") | .value),
           token: (.fields[] | select(.name == "accessToken") | .value) }]
        | unique_by(.user)
        | .[]')

    if [ -z "$user_tokens" ]; then
        log "  No Trakt users found in import lists"
        return 0
    fi

    # Fetch all monitored movies from this instance's Radarr
    local movies_payload=""
    local movies
    movies=$(curl -sf -H "X-Api-Key: $radarr_key" "$radarr_url/api/v3/movie") || {
        log "ERROR: Failed to fetch movies from Radarr ($instance_label)"
        ERRORS=$((ERRORS + 1))
        movies="[]"
    }

    movies_payload=$(echo "$movies" | jq -c '[.[] | select(.monitored == true) |
        { ids: (
            (if .imdbId and .imdbId != "" then { imdb: .imdbId } else {} end) +
            (if .tmdbId and .tmdbId > 0 then { tmdb: .tmdbId } else {} end)
        ) } | select(.ids != {})]')

    local movie_count
    movie_count=$(echo "$movies_payload" | jq 'length')
    log "  Found $movie_count monitored movies in Radarr ($instance_label)"

    # Fetch all monitored series from this instance's Sonarr
    local shows_payload=""
    local series
    series=$(curl -sf -H "X-Api-Key: $sonarr_key" "$sonarr_url/api/v3/series") || {
        log "ERROR: Failed to fetch series from Sonarr ($instance_label)"
        ERRORS=$((ERRORS + 1))
        series="[]"
    }

    shows_payload=$(echo "$series" | jq -c '[.[] | select(.monitored == true) |
        { ids: (
            (if .imdbId and .imdbId != "" then { imdb: .imdbId } else {} end) +
            (if .tvdbId and .tvdbId > 0 then { tvdb: .tvdbId } else {} end)
        ) } | select(.ids != {})]')

    local show_count
    show_count=$(echo "$shows_payload" | jq 'length')
    log "  Found $show_count monitored series in Sonarr ($instance_label)"

    # Sync to each user's Trakt watchlist
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local user token
        user=$(echo "$entry" | jq -r '.user')
        token=$(echo "$entry" | jq -r '.token')

        log "  Syncing to Trakt watchlist for '$user'..."

        if $DRY_RUN; then
            log "  [DRY RUN] Would sync $movie_count movies + $show_count shows to '$user'"
            continue
        fi

        # Build combined payload
        local payload
        payload=$(jq -nc --argjson movies "$movies_payload" --argjson shows "$shows_payload" \
            '{ movies: $movies, shows: $shows }')

        local sync_code
        sync_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
            "https://api.trakt.tv/sync/watchlist" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "trakt-api-version: 2" \
            -H "trakt-api-key: $SONARR_TRAKT_CLIENT_ID" \
            -d "$payload")

        if [ "$sync_code" = "201" ]; then
            log "  Synced $movie_count movies + $show_count shows to '$user'"
        elif [ "$sync_code" = "401" ] || [ "$sync_code" = "403" ]; then
            log "  WARN: Auth failed for '$user' (HTTP $sync_code) — token may need refresh"
            ERRORS=$((ERRORS + 1))
        else
            log "  ERROR: Trakt sync failed for '$user' (HTTP $sync_code)"
            ERRORS=$((ERRORS + 1))
        fi
    done <<< "$user_tokens"
}

# --- Run all phases for each instance ---

while IFS= read -r instance; do
    [ -z "$instance" ] && continue
    IFS='|' read -r label sonarr_url sonarr_key radarr_url radarr_key <<< "$instance"

    log "=== Trakt import list force-refresh ($label) ==="

    cycle_trakt_lists "Sonarr ($label)" "$sonarr_url" "$sonarr_key" "${label}-sonarr"
    cycle_trakt_lists "Radarr ($label)" "$radarr_url" "$radarr_key" "${label}-radarr"

    trigger_sync "Sonarr ($label)" "$sonarr_url" "$sonarr_key"
    trigger_sync "Radarr ($label)" "$radarr_url" "$radarr_key"

    log "=== Cleanup unmonitored items ($label) ==="

    cleanup_unmonitored "Sonarr ($label)" "$sonarr_url" "$sonarr_key" "series" "addImportListExclusion"
    cleanup_unmonitored "Radarr ($label)" "$radarr_url" "$radarr_key" "movie" "addImportExclusion"

    sync_to_trakt "$label" "$sonarr_url" "$sonarr_key" "$radarr_url" "$radarr_key"
done <<< "$INSTANCES"

# --- Phase 4: Clean up orphaned Transmission torrents ---
# After deleting items from Sonarr/Radarr, their files are gone but torrents linger.
# Remove torrents whose files no longer exist and seeding obligation is met.

log "=== Transmission orphan cleanup ==="
CLEANUP_ARGS=""
$DRY_RUN && CLEANUP_ARGS="--dry-run"
"$SCRIPT_DIR/transmission-cleanup.sh" $CLEANUP_ARGS 2>&1 | while IFS= read -r line; do log "$line"; done || {
    log "WARN: transmission-cleanup.sh had errors"
    ERRORS=$((ERRORS + 1))
}

# --- Guest quota check ---
if [ -n "$SONARR_GUEST_KEY" ] && [ -n "$RADARR_GUEST_KEY" ]; then
    log "=== Guest quota check ==="
    "$SCRIPT_DIR/guest-quota.sh" 2>&1 | while IFS= read -r line; do log "$line"; done || {
        log "WARN: guest-quota.sh had errors"
    }
fi

if [ "$ERRORS" -gt 0 ]; then
    log "=== Done with $ERRORS error(s) ==="
    exit 1
else
    log "=== Done ==="
fi
