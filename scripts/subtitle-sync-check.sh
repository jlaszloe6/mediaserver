#!/bin/bash
# subtitle-sync-check.sh - Re-sync external subtitles after Sonarr/Radarr replaces a video file
#
# Bazarr's own automatic subsync (config: subsync.use_subsync) only fires
# right after a fresh subtitle *download* - it never re-fires just because
# the underlying video file later gets imported/upgraded (a season-pack
# repack, a quality upgrade, a manual re-grab). When that happens, any
# subtitle already sitting on disk stays byte-for-byte unchanged and
# silently drifts out of sync with the new file, because nothing tells
# Bazarr the video changed underneath it.
#
# Watches Sonarr/Radarr's history for `downloadFolderImported` events and,
# for each episode/movie that already has an external (non-forced,
# non-embedded) subtitle, re-triggers Bazarr's own "sync" action on it -
# the same audio-based ffsubsync alignment Bazarr uses for new downloads.
#
# State is tracked per-service by history record id, so re-runs never
# reprocess the same import event twice. On its first run the script seeds
# state from whatever is currently in the lookback window rather than
# backfilling it - like queue-cleanup.sh's zero-progress tracking, this
# only acts on imports it has personally observed happen from here on.
#
# Run every 30 minutes via cron.

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
BAZARR_URL="http://bazarr:6767"
BAZARR_KEY="${BAZARR_API_KEY:-}"

if [ -z "$BAZARR_KEY" ]; then
    echo "ERROR: BAZARR_API_KEY not set in .env" >&2
    exit 1
fi

# Lookback for the history query itself - just needs to comfortably span a
# missed cron run or two. Dedup against reprocessing is done by history id
# below, so this only bounds how much the API has to return, not what
# actually gets acted on.
LOOKBACK_DATE=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)

ERRORS=0
SYNCED=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Trigger a Bazarr sync for one external subtitle.
sync_subtitle() {
    local media_type="$1" media_id="$2" lang="$3" path="$4" label="$5"

    if $DRY_RUN; then
        log "  [DRY RUN] Would trigger Bazarr sync: $label ($lang) - $path"
        return 0
    fi

    # `|| code="000"` - under set -e a transport-level curl failure here
    # would abort the whole script mid-batch instead of just counting this
    # one subtitle as failed and moving on to the rest.
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$BAZARR_URL/api/subtitles" \
        -H "X-API-KEY: $BAZARR_KEY" \
        --data-urlencode "action=sync" \
        --data-urlencode "language=$lang" \
        --data-urlencode "path=$path" \
        --data-urlencode "type=$media_type" \
        --data-urlencode "id=$media_id" \
        --data-urlencode "forced=False" \
        --data-urlencode "hi=False") || code="000"

    if [ "$code" = "204" ]; then
        log "  Queued resync: $label ($lang)"
        SYNCED=$((SYNCED + 1))
    else
        log "  ERROR: Bazarr sync request failed for $label ($lang) - HTTP $code"
        ERRORS=$((ERRORS + 1))
    fi
}

# Resync every external, non-forced subtitle Bazarr currently has on file
# for one episode or movie. Embedded subtitle tracks and forced subtitles
# are skipped - Bazarr's own sync_subtitles() refuses forced subs too, and
# there's no external file path to sync for an embedded track.
resync_media_subtitles() {
    local media_type="$1" media_id="$2" label="$3"
    local endpoint
    if [ "$media_type" = "episode" ]; then
        endpoint="$BAZARR_URL/api/episodes?episodeid[]=$media_id"
    else
        endpoint="$BAZARR_URL/api/movies?radarrid[]=$media_id"
    fi

    local resp
    resp=$(curl -sf -H "X-API-KEY: $BAZARR_KEY" "$endpoint") || {
        log "  WARN: Could not fetch Bazarr metadata for $label (not indexed by Bazarr yet?)"
        return 0
    }

    local subs
    subs=$(echo "$resp" | jq -c '(.data[0].subtitles // [])[] | select(.embedded_track_id == null and .forced == false)')

    [ -z "$subs" ] && return 0

    while IFS= read -r sub; do
        [ -z "$sub" ] && continue
        local lang path
        lang=$(echo "$sub" | jq -r '.code2')
        path=$(echo "$sub" | jq -r '.path')
        sync_subtitle "$media_type" "$media_id" "$lang" "$path" "$label"
    done <<< "$subs"
}

# Poll one service's import history since the last id we've already acted
# on, and resync subtitles for every episode/movie that shows up.
process_service() {
    local service_name="$1" base_url="$2" api_key="$3" media_type="$4" id_field="$5" state_file="$6"

    if [ -z "$api_key" ]; then
        log "WARN: No API key configured for $service_name - skipping"
        return 0
    fi

    local history
    history=$(curl -sf -H "X-Api-Key: $api_key" \
        "$base_url/api/v3/history/since?date=${LOOKBACK_DATE}&eventType=downloadFolderImported") || {
        log "ERROR: Failed to fetch $service_name history"
        ERRORS=$((ERRORS + 1))
        return 1
    }

    if [ ! -f "$state_file" ]; then
        # First run: don't backfill everything in the lookback window - just
        # note the newest id currently there as the starting point.
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
    # re-grab importing the same episode twice) - resync it once per run.
    local media_ids
    media_ids=$(echo "$new_events" | jq -r "[.[].${id_field}] | unique | .[]")

    while IFS= read -r mid; do
        [ -z "$mid" ] && continue
        resync_media_subtitles "$media_type" "$mid" "$service_name #$mid"
    done <<< "$media_ids"

    local max_id
    max_id=$(echo "$new_events" | jq '[.[].id] | max')
    if ! $DRY_RUN; then
        echo "$max_id" > "$state_file"
    fi
}

log "=== Subtitle sync check ==="

process_service "Sonarr" "$SONARR_URL" "${SONARR_API_KEY:-}" "episode" "episodeId" "/var/tmp/subtitle-sync-check-sonarr.id"
process_service "Radarr" "$RADARR_URL" "${RADARR_API_KEY:-}" "movie" "movieId" "/var/tmp/subtitle-sync-check-radarr.id"

DONE_MSG="=== Done: $SYNCED subtitle(s) queued for resync"
EXIT_CODE=0
if [ "$ERRORS" -gt 0 ]; then
    DONE_MSG="${DONE_MSG}, $ERRORS error(s)"
    EXIT_CODE=1
fi
log "${DONE_MSG} ==="

# Only alert on errors, matching queue-cleanup.sh/pipeline-monitor.sh -
# routine resyncs are logged, not emailed.
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
Subject: [${SERVER_NAME:-Media Server}] Subtitle sync check errors
Content-Type: text/plain; charset=utf-8

$ERRORS error(s) occurred while checking/resyncing subtitles after video imports.
Check /var/log/cron/subtitle-sync-check.log on the server for details.

---
Generated by subtitle-sync-check.sh at $(date '+%Y-%m-%d %H:%M:%S')
EOF
    else
        log "WARN: No SMTP config - cannot send error alert email"
    fi
fi

exit "$EXIT_CODE"
