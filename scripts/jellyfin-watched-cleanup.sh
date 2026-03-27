#!/bin/bash
# jellyfin-watched-cleanup.sh - Remove media watched 30+ days ago
#
# Replaces Prunarr. Queries Jellyfin for played items, checks LastPlayedDate,
# and deletes from Sonarr/Radarr if watched more than 30 days ago.
#
# Run daily at 3 AM via cron.

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

JELLYFIN_URL="http://jellyfin:8096"
JELLYFIN_KEY="${JELLYFIN_API_KEY:-}"
SONARR_URL="http://sonarr:8989"
SONARR_KEY="$SONARR_API_KEY"
RADARR_URL="http://radarr:7878"
RADARR_KEY="$RADARR_API_KEY"
DAYS_WATCHED=30

ERRORS=0
REMOVED_MOVIES=0
REMOVED_SERIES=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [ -z "$JELLYFIN_KEY" ]; then
    log "ERROR: JELLYFIN_API_KEY not set"
    exit 1
fi

HEADERS="-H X-Emby-Token:$JELLYFIN_KEY"
CUTOFF=$(date -u -d "-${DAYS_WATCHED} days" '+%Y-%m-%dT%H:%M:%SZ')

log "=== Jellyfin watched cleanup (>${DAYS_WATCHED} days) ==="
log "Cutoff date: $CUTOFF"

# Get all Jellyfin users
users=$(curl -sf $HEADERS "$JELLYFIN_URL/Users") || {
    log "ERROR: Failed to fetch Jellyfin users"
    exit 1
}

user_ids=$(echo "$users" | jq -r '.[].Id')

# --- Movies ---
log "--- Checking watched movies ---"

# Get all Radarr movies for matching
radarr_movies=$(curl -sf -H "X-Api-Key: $RADARR_KEY" "$RADARR_URL/api/v3/movie") || {
    log "ERROR: Failed to fetch Radarr movies"
    ERRORS=$((ERRORS + 1))
    radarr_movies="[]"
}

for user_id in $user_ids; do
    user_name=$(echo "$users" | jq -r ".[] | select(.Id == \"$user_id\") | .Name")

    # Get played movies for this user
    played_movies=$(curl -sf $HEADERS \
        "$JELLYFIN_URL/Users/$user_id/Items?IsPlayed=true&Recursive=true&IncludeItemTypes=Movie&Fields=ProviderIds" 2>/dev/null) || continue

    echo "$played_movies" | jq -c '.Items[]' 2>/dev/null | while IFS= read -r item; do
        last_played=$(echo "$item" | jq -r '.UserData.LastPlayedDate // empty')
        [ -z "$last_played" ] && continue

        # Check if watched before cutoff
        if [[ "$last_played" > "$CUTOFF" ]]; then
            continue
        fi

        title=$(echo "$item" | jq -r '.Name')
        tmdb_id=$(echo "$item" | jq -r '.ProviderIds.Tmdb // empty')

        [ -z "$tmdb_id" ] && continue

        # Find in Radarr by TMDB ID
        radarr_id=$(echo "$radarr_movies" | jq -r ".[] | select(.tmdbId == ($tmdb_id | tonumber)) | .id" 2>/dev/null)
        [ -z "$radarr_id" ] && continue

        if $DRY_RUN; then
            log "  [DRY RUN] Would remove movie '$title' (tmdb=$tmdb_id, watched by $user_name on $last_played)"
            REMOVED_MOVIES=$((REMOVED_MOVIES + 1))
            continue
        fi

        del_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
            -H "X-Api-Key: $RADARR_KEY" \
            "$RADARR_URL/api/v3/movie/$radarr_id?deleteFiles=true&addImportExclusion=true")

        if [ "$del_code" = "200" ]; then
            log "  Removed movie '$title' (watched by $user_name on $last_played)"
            REMOVED_MOVIES=$((REMOVED_MOVIES + 1))
        else
            log "  ERROR: Failed to remove movie '$title' (HTTP $del_code)"
            ERRORS=$((ERRORS + 1))
        fi
    done
done

log "  Movies removed: $REMOVED_MOVIES"

# --- Series ---
log "--- Checking watched series ---"

# Get all Sonarr series for matching
sonarr_series=$(curl -sf -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/series") || {
    log "ERROR: Failed to fetch Sonarr series"
    ERRORS=$((ERRORS + 1))
    sonarr_series="[]"
}

for user_id in $user_ids; do
    user_name=$(echo "$users" | jq -r ".[] | select(.Id == \"$user_id\") | .Name")

    # Get played series for this user
    played_series=$(curl -sf $HEADERS \
        "$JELLYFIN_URL/Users/$user_id/Items?IsPlayed=true&Recursive=true&IncludeItemTypes=Series&Fields=ProviderIds" 2>/dev/null) || continue

    echo "$played_series" | jq -c '.Items[]' 2>/dev/null | while IFS= read -r item; do
        last_played=$(echo "$item" | jq -r '.UserData.LastPlayedDate // empty')
        [ -z "$last_played" ] && continue

        if [[ "$last_played" > "$CUTOFF" ]]; then
            continue
        fi

        title=$(echo "$item" | jq -r '.Name')
        tvdb_id=$(echo "$item" | jq -r '.ProviderIds.Tvdb // empty')

        [ -z "$tvdb_id" ] && continue

        # Find in Sonarr by TVDB ID
        sonarr_id=$(echo "$sonarr_series" | jq -r ".[] | select(.tvdbId == ($tvdb_id | tonumber)) | .id" 2>/dev/null)
        [ -z "$sonarr_id" ] && continue

        if $DRY_RUN; then
            log "  [DRY RUN] Would remove series '$title' (tvdb=$tvdb_id, watched by $user_name on $last_played)"
            REMOVED_SERIES=$((REMOVED_SERIES + 1))
            continue
        fi

        del_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
            -H "X-Api-Key: $SONARR_KEY" \
            "$SONARR_URL/api/v3/series/$sonarr_id?deleteFiles=true&addImportListExclusion=true")

        if [ "$del_code" = "200" ]; then
            log "  Removed series '$title' (watched by $user_name on $last_played)"
            REMOVED_SERIES=$((REMOVED_SERIES + 1))
        else
            log "  ERROR: Failed to remove series '$title' (HTTP $del_code)"
            ERRORS=$((ERRORS + 1))
        fi
    done
done

log "  Series removed: $REMOVED_SERIES"

# --- Transmission orphan cleanup ---
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
