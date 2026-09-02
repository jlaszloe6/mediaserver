#!/bin/bash
# subtitle-preextract.sh - Pre-extract embedded subtitles right after import
#
# Jellyfin extracts an embedded (non-external) subtitle track on demand,
# the first time anything requests it - via the same ffmpeg SubtitleEncoder
# pipeline whether triggered by a real player or a plain HTTP GET to the
# subtitle-stream endpoint. That on-demand read of the source file competes
# with the concurrent NFS read the video itself needs for playback, which
# can (see the 2026-09-02 incident notes in CLAUDE.md) push an already-busy
# NAS into minutes-long stalls exactly when someone is trying to watch -
# worse if playback stalling invites a retry, since each retry adds another
# full read of the same file on top of the still-running extraction.
#
# Triggering that same extraction proactively right after import - when
# nothing else is competing for read bandwidth on that specific file -
# means it's already cached on local disk by the time anyone presses play,
# so playback never needs to extract it live at all.
#
# Watches Sonarr/Radarr's history for downloadFolderImported events (same
# mechanism as subtitle-sync-check.sh) and, for each newly imported
# episode/movie, finds the matching item in Jellyfin (once the next library
# scan has picked it up) and requests every embedded subtitle stream once
# to force extraction.
#
# State is tracked per-service by history record id, same as
# subtitle-sync-check.sh - re-runs never reprocess an import event twice,
# and on first run the script seeds state from the current lookback window
# rather than backfilling every embedded subtitle in the library.
#
# Run every 5 minutes via cron - matches jellyfin-scan.sh's cadence, since
# an item can't be found here until Jellyfin's own scan has indexed it.

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
    esac
done

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/curl-secrets.sh"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE="/config/.env"
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found" >&2
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

SONARR_URL="http://sonarr:8989"
RADARR_URL="http://radarr:7878"
JELLYFIN_URL="http://jellyfin:8096"
JELLYFIN_KEY="${JELLYFIN_API_KEY:-}"

if [ -z "$JELLYFIN_KEY" ]; then
    echo "ERROR: JELLYFIN_API_KEY not set in .env" >&2
    exit 1
fi

JF_HEADER="X-Emby-Token: $JELLYFIN_KEY"

# Lookback for the history query itself - just needs to comfortably span a
# missed cron run or two. Dedup against reprocessing is done by history id
# below, so this only bounds how much the API has to return, not what
# actually gets acted on.
LOOKBACK_DATE=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)

ERRORS=0
EXTRACTED=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Any Jellyfin user works for the read-only lookups below (MediaStreams
# aren't user-specific) - Jellyfin's /Items endpoints require a userId in
# the path regardless, so just grab the first one.
JELLYFIN_USERS=$(curl -sf --max-time 15 -H "$JF_HEADER" "$JELLYFIN_URL/Users") || {
    echo "ERROR: Failed to fetch Jellyfin users" >&2
    exit 1
}
JELLYFIN_USER_ID=$(echo "$JELLYFIN_USERS" | jq -r '.[0].Id // empty')
if [ -z "$JELLYFIN_USER_ID" ]; then
    echo "ERROR: Could not find a Jellyfin user id" >&2
    exit 1
fi

# Fetched once and reused for every item this run, same as
# jellyfin-watched-cleanup.sh's radarr_movies/sonarr_series - the full
# Jellyfin catalog doesn't change mid-run, and a batch is usually only a
# handful of items anyway.
JELLYFIN_MOVIES=$(curl -sf --max-time 30 -H "$JF_HEADER" \
    "$JELLYFIN_URL/Users/$JELLYFIN_USER_ID/Items?IncludeItemTypes=Movie&Recursive=true&Fields=ProviderIds") || {
    echo "ERROR: Failed to fetch Jellyfin movies" >&2
    exit 1
}
JELLYFIN_SERIES=$(curl -sf --max-time 30 -H "$JF_HEADER" \
    "$JELLYFIN_URL/Users/$JELLYFIN_USER_ID/Items?IncludeItemTypes=Series&Recursive=true&Fields=ProviderIds") || {
    echo "ERROR: Failed to fetch Jellyfin series" >&2
    exit 1
}

# Request every embedded subtitle stream once for a Jellyfin item, forcing
# ffmpeg extraction now instead of at playback time. External subtitle
# streams are skipped - they're already plain files on disk, nothing to
# extract.
preextract_item() {
    local item_id="$1" label="$2"

    local item
    item=$(curl -sf --max-time 15 -H "$JF_HEADER" \
        "$JELLYFIN_URL/Users/$JELLYFIN_USER_ID/Items/$item_id?Fields=MediaSources") || {
        log "  ERROR: Could not fetch Jellyfin item details for $label"
        ERRORS=$((ERRORS + 1))
        HAD_FAILURE=1
        return 0
    }

    local media_source_id
    media_source_id=$(echo "$item" | jq -r '.MediaSources[0].Id // empty')
    if [ -z "$media_source_id" ]; then
        log "  WARN: No media source yet for $label, will retry"
        HAD_FAILURE=1
        return 0
    fi

    local indices
    indices=$(echo "$item" | jq -r '.MediaSources[0].MediaStreams[] | select(.Type == "Subtitle" and .IsExternal == false) | .Index')

    if [ -z "$indices" ]; then
        log "  $label: no embedded subtitle tracks"
        return 0
    fi

    while IFS= read -r idx; do
        [ -z "$idx" ] && continue

        if $DRY_RUN; then
            log "  [DRY RUN] Would pre-extract subtitle index $idx for $label"
            EXTRACTED=$((EXTRACTED + 1))
            continue
        fi

        # `|| code="000"` - a transport-level curl failure here must not
        # abort the whole script mid-batch under set -e; it should just
        # count this one subtitle as failed and move on to the rest.
        local code
        code=$(curl -s --max-time 180 -o /dev/null -w '%{http_code}' \
            -H "$JF_HEADER" \
            "$JELLYFIN_URL/Videos/$item_id/$media_source_id/Subtitles/$idx/Stream.srt") || code="000"

        if [ "$code" = "200" ]; then
            log "  Pre-extracted subtitle index $idx for $label"
            EXTRACTED=$((EXTRACTED + 1))
        else
            log "  ERROR: Failed to pre-extract subtitle index $idx for $label - HTTP $code"
            ERRORS=$((ERRORS + 1))
            HAD_FAILURE=1
        fi
    done <<< "$indices"
}

# Resolve one Radarr movie import to its Jellyfin item and pre-extract it.
preextract_movie() {
    local radarr_movie_id="$1"

    local movie
    movie=$(curl -sf --max-time 15 -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_URL/api/v3/movie/$radarr_movie_id") || {
        log "  ERROR: Could not fetch Radarr movie $radarr_movie_id"
        ERRORS=$((ERRORS + 1))
        HAD_FAILURE=1
        return 0
    }

    local title tmdb_id
    title=$(echo "$movie" | jq -r '.title')
    tmdb_id=$(echo "$movie" | jq -r '.tmdbId')

    local jf_id
    jf_id=$(echo "$JELLYFIN_MOVIES" | jq -r ".Items[] | select(.ProviderIds.Tmdb == \"$tmdb_id\") | .Id" | head -1)
    if [ -z "$jf_id" ]; then
        log "  '$title': not yet indexed in Jellyfin, will retry"
        HAD_FAILURE=1
        return 0
    fi

    preextract_item "$jf_id" "movie '$title'"
}

# Resolve one Sonarr episode import to its Jellyfin item and pre-extract it.
preextract_episode() {
    local sonarr_episode_id="$1"

    local episode
    episode=$(curl -sf --max-time 15 -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/episode/$sonarr_episode_id") || {
        log "  ERROR: Could not fetch Sonarr episode $sonarr_episode_id"
        ERRORS=$((ERRORS + 1))
        HAD_FAILURE=1
        return 0
    }

    local series_id season_num episode_num
    series_id=$(echo "$episode" | jq -r '.seriesId')
    season_num=$(echo "$episode" | jq -r '.seasonNumber')
    episode_num=$(echo "$episode" | jq -r '.episodeNumber')

    local series
    series=$(curl -sf --max-time 15 -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/series/$series_id") || {
        log "  ERROR: Could not fetch Sonarr series $series_id"
        ERRORS=$((ERRORS + 1))
        HAD_FAILURE=1
        return 0
    }

    local series_title tvdb_id
    series_title=$(echo "$series" | jq -r '.title')
    tvdb_id=$(echo "$series" | jq -r '.tvdbId')

    local jf_series_id
    jf_series_id=$(echo "$JELLYFIN_SERIES" | jq -r ".Items[] | select(.ProviderIds.Tvdb == \"$tvdb_id\") | .Id" | head -1)
    if [ -z "$jf_series_id" ]; then
        log "  '$series_title': series not yet indexed in Jellyfin, will retry"
        HAD_FAILURE=1
        return 0
    fi

    # Declared then assigned separately, not `local label=$(...)`: under
    # set -e, a failure inside a command substitution on the same line as
    # `local` can be masked by `local`'s own (successful) exit status - the
    # same class of bug this codebase has hit before with set -e.
    local label
    label="'$series_title' S$(printf '%02d' "$season_num")E$(printf '%02d' "$episode_num")"

    local jf_episode_id
    jf_episode_id=$(curl -sf --max-time 15 -H "$JF_HEADER" \
        "$JELLYFIN_URL/Shows/$jf_series_id/Episodes?seasonNumber=$season_num" \
        | jq -r ".Items[] | select(.IndexNumber == $episode_num) | .Id" | head -1) || {
        log "  ERROR: Could not fetch episode list for $label"
        ERRORS=$((ERRORS + 1))
        HAD_FAILURE=1
        return 0
    }
    if [ -z "$jf_episode_id" ]; then
        log "  $label: episode not yet indexed in Jellyfin, will retry"
        HAD_FAILURE=1
        return 0
    fi

    preextract_item "$jf_episode_id" "$label"
}

# Poll one service's import history since the last id we've already acted
# on, and pre-extract subtitles for every episode/movie that shows up.
process_service() {
    local service_name="$1" base_url="$2" api_key="$3" id_field="$4" state_file="$5" handler="$6"

    if [ -z "$api_key" ]; then
        log "WARN: No API key configured for $service_name - skipping"
        return 0
    fi

    # This failure is fully handled right here (logged + counted), so it
    # returns 0, not 1 - see subtitle-sync-check.sh's process_service for
    # why (avoids disabling set -e for this whole function body via an
    # `|| true` at the call site).
    local history
    history=$(curl -sf -H "X-Api-Key: $api_key" \
        "$base_url/api/v3/history/since?date=${LOOKBACK_DATE}&eventType=downloadFolderImported") || {
        log "ERROR: Failed to fetch $service_name history"
        ERRORS=$((ERRORS + 1))
        return 0
    }

    if [ ! -f "$state_file" ]; then
        local seed_id
        seed_id=$(echo "$history" | jq '[.[].id] + [0] | max')
        log "$service_name: first run, seeding state at id $seed_id (no backfill)"
        if ! $DRY_RUN; then
            echo "$seed_id" > "$state_file"
        fi
        return 0
    fi

    local last_id
    last_id=$(cat "$state_file")

    local new_events
    new_events=$(echo "$history" | jq -c --argjson last "$last_id" '[.[] | select(.id > $last)]')

    local count
    count=$(echo "$new_events" | jq 'length')

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    log "$service_name: $count new import event(s) to check"

    # One media id can appear multiple times in the window (e.g. a repack
    # re-grab importing the same episode twice) - pre-extract it once per
    # run.
    local media_ids
    media_ids=$(echo "$new_events" | jq -r "[.[].${id_field}] | unique | .[]")

    # Set by preextract_movie/preextract_episode/preextract_item on any
    # failure OR on an item not yet visible in Jellyfin. Either way the
    # whole batch (successes included, which is idempotent) is retried
    # next run rather than silently abandoning whichever item isn't ready.
    HAD_FAILURE=0

    while IFS= read -r mid; do
        [ -z "$mid" ] && continue
        "$handler" "$mid"
    done <<< "$media_ids"

    if [ "$HAD_FAILURE" -eq 1 ]; then
        log "$service_name: failure(s)/not-yet-indexed item(s) - not advancing state, will retry this batch next run"
        return 0
    fi

    local max_id
    max_id=$(echo "$new_events" | jq '[.[].id] | max')
    if ! $DRY_RUN; then
        echo "$max_id" > "$state_file"
    fi
}

log "=== Subtitle pre-extract check ==="

# Called as plain statements, deliberately NOT `process_service ... ||
# true` - see subtitle-sync-check.sh for why that would silently swallow a
# genuinely unexpected failure inside process_service (a jq crash, an
# unwritable state file), not just the already-handled expected ones.
process_service "Sonarr" "$SONARR_URL" "${SONARR_API_KEY:-}" "episodeId" "/var/tmp/subtitle-preextract-sonarr.id" preextract_episode
process_service "Radarr" "$RADARR_URL" "${RADARR_API_KEY:-}" "movieId" "/var/tmp/subtitle-preextract-radarr.id" preextract_movie

DONE_MSG="=== Done: $EXTRACTED subtitle(s) pre-extracted"
EXIT_CODE=0
if [ "$ERRORS" -gt 0 ]; then
    DONE_MSG="${DONE_MSG}, $ERRORS error(s)"
    EXIT_CODE=1
fi
log "${DONE_MSG} ==="

# Only alert on errors, matching subtitle-sync-check.sh/queue-cleanup.sh -
# routine pre-extractions are logged, not emailed. A "not yet indexed"
# retry is not an error and never reaches here.
if [ "$ERRORS" -gt 0 ] && ! $DRY_RUN; then
    if [ -n "${SMTP_SERVER:-}" ] && [ -n "${SMTP_FROM:-}" ]; then
        to="${ADMIN_EMAIL:-${SMTP_FROM}}"
        # `|| log ...` on the curl itself, not a separate check after: under
        # set -e a transient SMTP failure would otherwise abort the script
        # right here, past the point where EXIT_CODE has already been set.
        curl -sf --max-time 30 --url "smtp://${SMTP_SERVER}:${SMTP_PORT:-587}" \
            --login-options "AUTH=LOGIN" \
            --mail-from "$SMTP_FROM" \
            --mail-rcpt "$to" \
            --user "${SMTP_USER}:${SMTP_PASSWORD}" \
            -T - <<EOF || log "WARN: Failed to send error alert email"
From: ${SERVER_NAME:-Media Server} <${SMTP_FROM}>
To: $to
Subject: [${SERVER_NAME:-Media Server}] Subtitle pre-extract errors
Content-Type: text/plain; charset=utf-8

$ERRORS error(s) occurred while pre-extracting subtitles after video imports.
Check /var/log/cron/subtitle-preextract.log on the server for details.

---
Generated by subtitle-preextract.sh at $(date '+%Y-%m-%d %H:%M:%S')
EOF
    else
        log "WARN: No SMTP config - cannot send error alert email"
    fi
fi

exit "$EXIT_CODE"
