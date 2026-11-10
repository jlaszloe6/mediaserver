#!/bin/bash
# jellyfin-watched-cleanup.sh - Remove media watched 30+ days ago
#
# Replaces Prunarr. Queries Jellyfin for played items, checks LastPlayedDate,
# and deletes from Sonarr/Radarr if watched more than 30 days ago.
#
# Series: an *ended* series is removed from Sonarr entirely (files + import
# list exclusion). A series that is still running (Sonarr status
# continuing/upcoming) only has its watched episode files deleted and those
# episodes unmonitored - the series itself stays in Sonarr, monitored, so
# future episodes/seasons still get downloaded. Before deleting any file it
# is marked in $CLEARED_FILE so jellyfin-cleanup.sh doesn't mistake the
# now-empty series for a manual Jellyfin deletion and wipe it.
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
source "$SCRIPT_DIR/lib/curl-secrets.sh"
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

# Shared with jellyfin-cleanup.sh (same cron container, same /var/tmp
# volume): {"<sonarr series id>": <epoch when its files were cleared>}.
STATE_DIR="/var/tmp/mediaserver-cleanup"
CLEARED_FILE="$STATE_DIR/watched-cleared-series.json"
CLEARED_TTL_DAYS=7
mkdir -p "$STATE_DIR"

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

    while IFS= read -r item; do
        [ -z "$item" ] && continue
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

        # `|| del_code="000"`: without it, a transport-level curl failure
        # aborts the whole script under set -e before the HTTP-status
        # check below runs, which could otherwise look like every
        # remaining watched item silently got skipped rather than failed.
        del_code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -X DELETE \
            -H "X-Api-Key: $RADARR_KEY" \
            "$RADARR_URL/api/v3/movie/$radarr_id?deleteFiles=true&addImportExclusion=true") || del_code="000"

        if [ "$del_code" = "200" ]; then
            log "  Removed movie '$title' (watched by $user_name on $last_played)"
            REMOVED_MOVIES=$((REMOVED_MOVIES + 1))
        else
            log "  ERROR: Failed to remove movie '$title' (HTTP $del_code)"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(echo "$played_movies" | jq -c '.Items[]' 2>/dev/null)
done

log "  Movies removed: $REMOVED_MOVIES"

# Record a series as "files intentionally cleared" for jellyfin-cleanup.sh,
# pruning entries older than CLEARED_TTL_DAYS (by then jellyfin-cleanup has
# long since saved sizeOnDisk=0 as its baseline, so the mark isn't needed).
# Written atomically (tmp + mv) - jellyfin-cleanup may read it concurrently.
mark_series_cleared() {
    local id="$1" now cur tmp
    now=$(date +%s)
    cur=$(jq -c '.' "$CLEARED_FILE" 2>/dev/null) || cur="{}"
    [ -n "$cur" ] || cur="{}"
    tmp=$(mktemp "$STATE_DIR/.cleared.XXXXXX") || return 1
    if echo "$cur" | jq -c --arg id "$id" --argjson now "$now" --argjson ttl "$((CLEARED_TTL_DAYS * 86400))" \
        'with_entries(select(($now - .value) < $ttl)) + {($id): $now}' > "$tmp"; then
        mv "$tmp" "$CLEARED_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

# Continuing/upcoming series: delete the watched episode files and
# unmonitor exactly those episodes (so Sonarr doesn't re-grab them), but
# keep the series itself monitored for future episodes. Aired episodes that
# never had a file stay monitored, so Sonarr keeps looking for them.
# Returns non-zero on any failure (caller counts it as an error).
clear_watched_series() {
    local id="$1" title="$2"
    local files file_ids eps ep_ids code

    files=$(curl -sf --max-time 15 -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/episodefile?seriesId=$id") || {
        log "  ERROR: Failed to list episode files for '$title'"
        return 1
    }
    file_ids=$(echo "$files" | jq -c '[.[].id]')
    if [ "$file_ids" = "[]" ]; then
        log "  Series '$title' (still running) has no files left - nothing to clear"
        return 0
    fi

    eps=$(curl -sf --max-time 15 -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/episode?seriesId=$id") || {
        log "  ERROR: Failed to list episodes for '$title'"
        return 1
    }
    ep_ids=$(echo "$eps" | jq -c '[.[] | select(.hasFile == true) | .id]')

    if $DRY_RUN; then
        log "  [DRY RUN] Would clear $(echo "$file_ids" | jq length) watched file(s) of still-running series '$title' and unmonitor $(echo "$ep_ids" | jq length) episode(s), keeping the series"
        return 0
    fi

    # Mark first: if this fails, delete nothing - otherwise jellyfin-cleanup
    # would see the emptied series and remove it from Sonarr for good.
    mark_series_cleared "$id" || {
        log "  ERROR: Could not write $CLEARED_FILE - not clearing '$title'"
        return 1
    }

    code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -X PUT \
        -H "X-Api-Key: $SONARR_KEY" -H "Content-Type: application/json" \
        -d "{\"episodeIds\":$ep_ids,\"monitored\":false}" \
        "$SONARR_URL/api/v3/episode/monitor") || code="000"
    case "$code" in 2*) ;; *)
        log "  ERROR: Failed to unmonitor watched episodes of '$title' (HTTP $code) - files left in place"
        return 1 ;;
    esac

    code=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
        -H "X-Api-Key: $SONARR_KEY" -H "Content-Type: application/json" \
        -d "{\"episodeFileIds\":$file_ids}" \
        "$SONARR_URL/api/v3/episodefile/bulk") || code="000"
    case "$code" in 2*) ;; *)
        log "  ERROR: Failed to delete watched files of '$title' (HTTP $code)"
        return 1 ;;
    esac

    log "  Cleared $(echo "$file_ids" | jq length) watched file(s) of still-running series '$title' - kept in Sonarr for future episodes"
    return 0
}

# --- Series ---
log "--- Checking watched series ---"

# A series fully watched by several users would otherwise be handled once
# per user (the second DELETE 404s and counts as an error).
HANDLED_SERIES=" "

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

    while IFS= read -r item; do
        [ -z "$item" ] && continue
        series_id=$(echo "$item" | jq -r '.Id')
        title=$(echo "$item" | jq -r '.Name')

        # Jellyfin never sets UserData.LastPlayedDate on the series item
        # itself, only on individual episodes, so derive it from the most
        # recently watched episode instead.
        #
        # Guards against aborting the whole script under set -e on one
        # Jellyfin request failure (matches the guard already on the
        # played_movies/played_series fetches above), but unlike those,
        # this one is now logged and counted - a real request failure
        # here means a genuine watched-series candidate never even got
        # evaluated, not just "no episodes played," so it shouldn't look
        # like a clean run in the final ERRORS-driven exit code.
        last_played=$(curl -sf --max-time 15 $HEADERS \
            "$JELLYFIN_URL/Users/$user_id/Items?ParentId=$series_id&Recursive=true&IncludeItemTypes=Episode&IsPlayed=true" 2>/dev/null \
            | jq -r '[.Items[].UserData.LastPlayedDate // empty] | max // empty') || {
            log "  ERROR: Failed to fetch episode watch data for series '$title'"
            ERRORS=$((ERRORS + 1))
            continue
        }
        [ -z "$last_played" ] && continue

        if [[ "$last_played" > "$CUTOFF" ]]; then
            continue
        fi

        tvdb_id=$(echo "$item" | jq -r '.ProviderIds.Tvdb // empty')

        sonarr_id=""
        if [ -n "$tvdb_id" ]; then
            sonarr_id=$(echo "$sonarr_series" | jq -r ".[] | select(.tvdbId == ($tvdb_id | tonumber)) | .id" 2>/dev/null)
        fi

        # Some series lack a TVDB provider id in Jellyfin; fall back to an
        # exact title match against Sonarr
        if [ -z "$sonarr_id" ]; then
            sonarr_id=$(echo "$sonarr_series" | jq -r ".[] | select(.title == \"$title\") | .id" 2>/dev/null)
        fi
        [ -z "$sonarr_id" ] && continue

        case "$HANDLED_SERIES" in *" $sonarr_id "*) continue ;; esac
        HANDLED_SERIES="$HANDLED_SERIES$sonarr_id "

        # Only an ended series is removed outright; anything Sonarr still
        # expects new episodes for keeps its Sonarr entry.
        series_status=$(echo "$sonarr_series" | jq -r ".[] | select(.id == $sonarr_id) | .status")
        if [ "$series_status" != "ended" ]; then
            log "  Series '$title' watched by $user_name on $last_played is still running (status=$series_status)"
            if clear_watched_series "$sonarr_id" "$title"; then
                REMOVED_SERIES=$((REMOVED_SERIES + 1))
            else
                ERRORS=$((ERRORS + 1))
            fi
            continue
        fi

        if $DRY_RUN; then
            log "  [DRY RUN] Would remove series '$title' (tvdb=$tvdb_id, watched by $user_name on $last_played)"
            REMOVED_SERIES=$((REMOVED_SERIES + 1))
            continue
        fi

        # Same set -e guard as the movie DELETE above.
        del_code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -X DELETE \
            -H "X-Api-Key: $SONARR_KEY" \
            "$SONARR_URL/api/v3/series/$sonarr_id?deleteFiles=true&addImportListExclusion=true") || del_code="000"

        if [ "$del_code" = "200" ]; then
            log "  Removed series '$title' (watched by $user_name on $last_played)"
            REMOVED_SERIES=$((REMOVED_SERIES + 1))
        else
            log "  ERROR: Failed to remove series '$title' (HTTP $del_code)"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(echo "$played_series" | jq -c '.Items[]' 2>/dev/null)
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
