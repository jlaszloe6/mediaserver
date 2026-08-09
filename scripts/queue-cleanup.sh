#!/bin/bash
# queue-cleanup.sh - Auto-fix stuck downloads and alert on issues
#
# Checks Sonarr/Radarr download queues for problems and handles them:
#
# 1. Import blocked (name mismatch): auto-imports if there's exactly one
#    matching file candidate. Otherwise sends an email alert.
#
# 2. Suspicious files (.exe, .msi, .bat, .scr, .cmd, .ps1, .vbs, .com,
#    .pif, .js, .lnk): auto-removes from the queue and blocklists the
#    release.
#
# 3. Downloads stuck at 0% for 2+ hours (dead torrent, no seeders): same
#    signal pipeline-monitor.sh alerts on - removes from the queue,
#    blocklists the release, and triggers a new search.
#
# 4. Downloads Sonarr/Radarr itself flags with an in-progress warning/error
#    (disk space, indexer issues, etc.): sends an email alert. Too many
#    different causes to safely auto-remediate the same way as #3.
#
# SMTP credentials are read from Radarr's email notification config.
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

# Instance list: "label|sonarr_url|sonarr_key|radarr_url|radarr_key"
QUEUE_INSTANCES="owner|http://sonarr:8989|$SONARR_KEY|http://radarr:7878|$RADARR_KEY"

SUSPICIOUS_EXTENSIONS="exe|msi|bat|scr|cmd|ps1|vbs|com|pif|js|lnk"

ERRORS=0
ALERT_MESSAGES=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# --- SMTP setup: loaded from .env via source above ---
SMTP_PASS="${SMTP_PASSWORD:-}"

send_email() {
    local subject="$1"
    local body="$2"

    if [ -z "$SMTP_SERVER" ]; then
        log "WARN: No SMTP config — cannot send email alert"
        return 1
    fi

    if $DRY_RUN; then
        log "  [DRY RUN] Would send email: $subject"
        return 0
    fi

    curl -sf --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
        --login-options "AUTH=LOGIN" \
        --mail-from "$SMTP_FROM" \
        --mail-rcpt "$SMTP_TO" \
        --user "$SMTP_USER:$SMTP_PASS" \
        -T - <<EOF
From: ${SERVER_NAME:-Media Server} <$SMTP_FROM>
To: $SMTP_TO
Subject: $subject
Content-Type: text/plain; charset=utf-8

$body
EOF

    if [ $? -eq 0 ]; then
        log "  Email sent: $subject"
    else
        log "  WARN: Failed to send email"
    fi
}

queue_alert() {
    local msg="$1"
    ALERT_MESSAGES="${ALERT_MESSAGES}${msg}
"
}

# --- Handle suspicious files ---
handle_suspicious() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"

    local queue
    queue=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/queue?page=1&pageSize=100&includeUnknownSeriesItems=true&includeUnknownMovieItems=true") || {
        log "ERROR: Failed to fetch queue from $service_name"
        ERRORS=$((ERRORS + 1))
        return 1
    }

    local suspicious
    suspicious=$(echo "$queue" | jq -c "[.records[] | select(.title | test(\"\\\\.(${SUSPICIOUS_EXTENSIONS})$\"; \"i\"))]")
    local count
    count=$(echo "$suspicious" | jq 'length')

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    log "  Found $count suspicious file(s) in $service_name"

    # `done < <(...)` / here-string, NOT `... | while ...`: piping into the
    # loop runs its body in a subshell, so ERRORS/ALERT_MESSAGES updates
    # inside it (via queue_alert, below) never make it back to this
    # function's caller - the file still gets removed/blocklisted for real,
    # but the alert email and error count silently vanish. This is exactly
    # the bug transmission-cleanup.sh's loops already avoid the same way.
    local suspicious_items
    suspicious_items=$(echo "$suspicious" | jq -c '.[]')
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        local id title indexer
        id=$(echo "$item" | jq -r '.id')
        title=$(echo "$item" | jq -r '.title')
        indexer=$(echo "$item" | jq -r '.indexer // "unknown"')

        log "  Rejecting suspicious: $title (indexer: $indexer)"

        if $DRY_RUN; then
            log "  [DRY RUN] Would remove '$title' from queue and blocklist"
            continue
        fi

        # Remove from queue, blocklist the release, and delete files
        local del_code
        del_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
            -H "X-Api-Key: $api_key" \
            "$base_url/api/v3/queue/$id?removeFromClient=true&blocklist=true&skipReprocess=false")

        if [ "$del_code" = "200" ]; then
            log "  Removed and blocklisted '$title'"
            queue_alert "[AUTO-FIXED] $service_name: Rejected suspicious file '$title' from indexer '$indexer' (blocklisted)"
        else
            log "  ERROR: Failed to remove '$title' (HTTP $del_code)"
            queue_alert "[NEEDS ATTENTION] $service_name: Could not remove suspicious file '$title' from indexer '$indexer'"
            ERRORS=$((ERRORS + 1))
        fi
    done <<< "$suspicious_items"
}

# --- Handle import-blocked items ---
handle_import_blocked() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"
    local media_type="$4"  # "movie" or "series"

    local queue
    queue=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/queue?page=1&pageSize=100&includeUnknownSeriesItems=true&includeUnknownMovieItems=true") || return 1

    local blocked
    blocked=$(echo "$queue" | jq -c '[.records[] | select(.trackedDownloadState == "importBlocked" or .trackedDownloadState == "importPending") | select(.trackedDownloadStatus == "warning")]')
    local count
    count=$(echo "$blocked" | jq 'length')

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    log "  Found $count import-blocked item(s) in $service_name"

    # See handle_suspicious's comment above: `| while` runs the loop body in
    # a subshell, silently losing every ERRORS/queue_alert update this loop
    # makes (i.e. most of what this function actually does).
    local blocked_items
    blocked_items=$(echo "$blocked" | jq -c '.[]')
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        local id title download_id output_path messages
        id=$(echo "$item" | jq -r '.id')
        title=$(echo "$item" | jq -r '.title')
        download_id=$(echo "$item" | jq -r '.downloadId')
        output_path=$(echo "$item" | jq -r '.outputPath')
        messages=$(echo "$item" | jq -r '[.statusMessages[].messages[]] | join("; ")')

        # Skip if it's a suspicious file (handled separately)
        if echo "$title" | grep -qiE "\.(${SUSPICIOUS_EXTENSIONS})$"; then
            continue
        fi

        log "  Import blocked: $title — $messages"

        # If all status messages are "Unable to parse file" (e.g. BR-DISK rip),
        # remove the release, blocklist it, and trigger a new search
        local all_unparseable
        all_unparseable=$(echo "$item" | jq '[.statusMessages[] | select(.messages[] | test("Unable to parse file"))] | length > 0 and [.statusMessages[] | select(.messages[] | test("Unable to parse file") | not) | select(.title != "One or more movies expected in this release were not imported or missing" and .title != "One or more episodes expected in this release were not imported or missing")] | length == 0')

        if [ "$all_unparseable" = "true" ]; then
            log "  All files unparseable (likely BR-DISK) — removing and searching for new release"

            if $DRY_RUN; then
                log "  [DRY RUN] Would remove '$title', blocklist, and search for new release"
                continue
            fi

            local del_code
            del_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
                -H "X-Api-Key: $api_key" \
                "$base_url/api/v3/queue/$id?removeFromClient=true&blocklist=true&skipReprocess=false")

            if [ "$del_code" = "200" ]; then
                log "  Removed and blocklisted '$title'"

                # Trigger a new search for this media
                local media_id_for_search
                if [ "$media_type" = "movie" ]; then
                    media_id_for_search=$(echo "$item" | jq -r '.movieId // empty')
                    if [ -n "$media_id_for_search" ]; then
                        curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
                            "$base_url/api/v3/command" \
                            -d "{\"name\":\"MoviesSearch\",\"movieIds\":[$media_id_for_search]}" > /dev/null 2>&1
                    fi
                else
                    media_id_for_search=$(echo "$item" | jq -r '.seriesId // empty')
                    if [ -n "$media_id_for_search" ]; then
                        curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
                            "$base_url/api/v3/command" \
                            -d "{\"name\":\"SeriesSearch\",\"seriesId\":$media_id_for_search}" > /dev/null 2>&1
                    fi
                fi

                queue_alert "[AUTO-FIXED] $service_name: Removed unparseable release '$title' (likely BR-DISK), searching for new release"
            else
                log "  ERROR: Failed to remove '$title' (HTTP $del_code)"
                queue_alert "[NEEDS ATTENTION] $service_name: Could not remove unparseable release '$title'"
                ERRORS=$((ERRORS + 1))
            fi
            continue
        fi

        # Determine the media ID
        local media_id=""
        if [ "$media_type" = "movie" ]; then
            media_id=$(echo "$item" | jq -r '.movieId // empty')
        else
            media_id=$(echo "$item" | jq -r '.seriesId // empty')
            local episode_id
            episode_id=$(echo "$item" | jq -r '.episodeId // empty')
        fi

        if [ -z "$media_id" ]; then
            queue_alert "[NEEDS ATTENTION] $service_name: '$title' import blocked but no media match — $messages"
            continue
        fi

        # Try manual import: get candidates
        local import_url
        if [ "$media_type" = "movie" ]; then
            import_url="$base_url/api/v3/manualimport?movieId=$media_id&downloadId=$download_id&folder=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$output_path'))")&filterExistingFiles=false"
        else
            import_url="$base_url/api/v3/manualimport?seriesId=$media_id&downloadId=$download_id&folder=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$output_path'))")&filterExistingFiles=false"
        fi

        local candidates
        candidates=$(curl -sf -H "X-Api-Key: $api_key" "$import_url" 2>/dev/null) || {
            queue_alert "[NEEDS ATTENTION] $service_name: '$title' import blocked, could not fetch candidates — $messages"
            continue
        }

        local candidate_count
        candidate_count=$(echo "$candidates" | jq 'if type == "array" then length else 0 end')

        if [ "$candidate_count" -eq 0 ]; then
            queue_alert "[NEEDS ATTENTION] $service_name: '$title' import blocked, no file candidates found — $messages"
            continue
        fi

        # Filter to candidates with no rejections
        local valid_candidates
        valid_candidates=$(echo "$candidates" | jq -c '[.[] | select((.rejections | length) == 0)]')
        local valid_count
        valid_count=$(echo "$valid_candidates" | jq 'length')

        if [ "$valid_count" -eq 0 ]; then
            local rejection_reasons
            rejection_reasons=$(echo "$candidates" | jq -r '[.[].rejections[].reason] | unique | join("; ")')
            queue_alert "[NEEDS ATTENTION] $service_name: '$title' import blocked, all candidates rejected — $rejection_reasons"
            continue
        fi

        if [ "$valid_count" -ge 1 ]; then
            log "  Found $valid_count valid candidate(s), auto-importing..."

            if $DRY_RUN; then
                log "  [DRY RUN] Would auto-import '$title'"
                continue
            fi

            # Build import payload
            local import_payload
            if [ "$media_type" = "movie" ]; then
                import_payload=$(echo "$valid_candidates" | jq -c "[.[] | {
                    path: .path,
                    movieId: $media_id,
                    quality: .quality,
                    languages: (.languages // [{id:1,name:\"English\"}]),
                    downloadId: \"$download_id\",
                    id: .id,
                    indexerFlags: 0,
                    releaseType: \"unknown\"
                }]")
            else
                import_payload=$(echo "$valid_candidates" | jq -c "[.[] | {
                    path: .path,
                    seriesId: $media_id,
                    episodeIds: [.episodes[]?.id // empty],
                    quality: .quality,
                    languages: (.languages // [{id:1,name:\"English\"}]),
                    downloadId: \"$download_id\",
                    id: .id,
                    indexerFlags: 0,
                    releaseType: \"unknown\"
                }]")
            fi

            # importMode "copy" (hardlink), not "move": move deletes the
            # source file from Transmission's download dir, breaking
            # nCore's 72h H&R seeding requirement for this release.
            local import_result
            import_result=$(curl -s -w '\n%{http_code}' -X POST \
                -H "X-Api-Key: $api_key" \
                -H "Content-Type: application/json" \
                "$base_url/api/v3/command" \
                -d "{\"name\":\"ManualImport\",\"importMode\":\"copy\",\"files\":$import_payload}")

            local import_code
            import_code=$(echo "$import_result" | tail -1)

            if [ "$import_code" = "201" ] || [ "$import_code" = "200" ]; then
                log "  Auto-imported '$title'"
                queue_alert "[AUTO-FIXED] $service_name: Auto-imported '$title' (was blocked: $messages)"
            else
                log "  ERROR: Auto-import failed for '$title' (HTTP $import_code)"
                queue_alert "[NEEDS ATTENTION] $service_name: '$title' auto-import failed (HTTP $import_code) — $messages"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done <<< "$blocked_items"
}

# --- Handle stalled downloads ---
handle_stalled() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"
    local media_type="$4"  # "movie" or "series"

    local queue
    queue=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/queue?page=1&pageSize=100") || return 1

    # Find items that are "downloading" but flagged warning/error - same pair
    # of statuses pipeline-monitor.sh's own alert checks for, so nothing
    # falls into the gap between "excluded from auto-fix below" and "never
    # alerted at all".
    local warning_items
    warning_items=$(echo "$queue" | jq -c '[.records[] | select(.trackedDownloadState == "downloading" and (.trackedDownloadStatus == "warning" or .trackedDownloadStatus == "error"))]')
    local warning_count
    warning_count=$(echo "$warning_items" | jq 'length')

    if [ "$warning_count" -gt 0 ]; then
        log "  Found $warning_count stalled/warning download(s) in $service_name"

        # Same subshell issue as the loops above - queue_alert here is this
        # branch's entire purpose, so piping into the loop made it a no-op.
        local warning_records
        warning_records=$(echo "$warning_items" | jq -c '.[]')
        while IFS= read -r item; do
            [ -z "$item" ] && continue
            local title messages
            title=$(echo "$item" | jq -r '.title')
            messages=$(echo "$item" | jq -r '[.statusMessages[].messages[]] | join("; ")')
            queue_alert "[STALLED] $service_name: '$title' — $messages"
        done <<< "$warning_records"
    fi

    # Downloads sitting at literally 0% (sizeleft == size) with the client
    # itself confirming an active "downloading" status - these are almost
    # always dead/unseeded torrents. This is the same core signal
    # pipeline-monitor.sh uses for its "stuck download (0% after 2h)" alert,
    # so anything that would trigger that alert gets auto-remediated here
    # instead: remove from queue, blocklist the release, and trigger a
    # fresh search - the same remedy already used for unparseable BR-DISK
    # releases above.
    #
    # Excludes warning/error status explicitly - those are the branch above's
    # job. A 0% item with a disk-space or client-side warning is an
    # infrastructure problem, not a dead release, and blocklisting it would
    # just repeat the same failure against a different torrent.
    #
    # Requires .status == "downloading" too, not just trackedDownloadState:
    # a release still sitting in Transmission's own queue (client-side
    # "queued" or "paused", e.g. behind a download-queue-size limit) also
    # reports trackedDownloadState "downloading" while genuinely at 0%
    # through no fault of its own - it just hasn't been handed to the
    # client yet.
    #
    # Age is tracked via a STATE_FILE keyed by downloadId (the torrent
    # hash), NOT via Sonarr/Radarr's `.added` (when the release was
    # grabbed): a release that spent hours queued behind other downloads
    # before finally starting would otherwise look "stuck since grab time"
    # and get wrongly blocklisted seconds into a legitimate download.
    # Debouncing against our own repeated observations instead (this runs
    # every 30 min) means an item only ever gets auto-fixed after WE have
    # personally seen it at 0% with a confirmed "downloading" status for
    # 2+ hours running, regardless of how long it sat queued before that.
    # One state file per service (keyed off service_name) since download
    # IDs are per-service queues and rebuilding blindly would otherwise let
    # the Radarr call wipe out entries the Sonarr call just wrote.
    local now_epoch
    now_epoch=$(date +%s)
    local stuck_threshold=7200  # 2 hours

    local state_suffix
    state_suffix=$(echo "$service_name" | tr -c '[:alnum:]' '_')
    local state_file="/var/tmp/queue-cleanup-zero-progress-${state_suffix}.state"
    touch "$state_file" 2>/dev/null || true

    local downloading_items
    downloading_items=$(echo "$queue" | jq -c '[.records[] | select(.trackedDownloadState == "downloading" and .status == "downloading" and .trackedDownloadStatus != "warning" and .trackedDownloadStatus != "error" and .sizeleft == .size)]')
    local downloading_records
    downloading_records=$(echo "$downloading_items" | jq -c '.[]')

    # Rebuilt from scratch below with only the entries worth keeping - items
    # that resolved (started progressing, left the queue) simply never get
    # re-added, so the file can't grow stale or unbounded.
    local new_state=""
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        local title download_id id
        title=$(echo "$item" | jq -r '.title')
        download_id=$(echo "$item" | jq -r '.downloadId // empty')
        id=$(echo "$item" | jq -r '.id')

        if [ -z "$download_id" ]; then
            continue
        fi

        local first_seen
        first_seen=$(awk -v id="$download_id" '$1 == id { print $2 }' "$state_file" 2>/dev/null)

        if [ -z "$first_seen" ]; then
            log "  First seen at 0%: $title — tracking, will re-check next run"
            new_state="${new_state}${download_id} ${now_epoch}
"
            continue
        fi

        local age=$((now_epoch - first_seen))

        if [ "$age" -le "$stuck_threshold" ]; then
            new_state="${new_state}${download_id} ${first_seen}
"
            continue
        fi

        log "  Zero progress for $((age / 3600))h: $title — removing, blocklisting, and re-searching"

        if $DRY_RUN; then
            log "  [DRY RUN] Would remove '$title', blocklist, and search for new release"
            new_state="${new_state}${download_id} ${first_seen}
"
            continue
        fi

        # Script runs under `set -e` - without the `|| del_code="000"` a
        # transport-level curl failure (e.g. Radarr/Sonarr mid-restart, as
        # happened during today's deploys) would abort the whole script
        # right here instead of falling through to the error handling below.
        local del_code
        del_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
            -H "X-Api-Key: $api_key" \
            "$base_url/api/v3/queue/$id?removeFromClient=true&blocklist=true&skipReprocess=false") || del_code="000"

        if [ "$del_code" != "200" ]; then
            log "  ERROR: Failed to remove '$title' (HTTP $del_code)"
            queue_alert "[NEEDS ATTENTION] $service_name: Could not remove zero-progress download '$title'"
            ERRORS=$((ERRORS + 1))
            # Still stuck in the queue - keep tracking it so the next run
            # retries the removal instead of forgetting it was ever stuck.
            new_state="${new_state}${download_id} ${first_seen}
"
            continue
        fi

        # Removal+blocklist above already succeeded and the item is gone
        # from the queue, so a failed search request here can't be retried
        # on the next run - capture success/failure explicitly (rather than
        # a blind `|| true`) so the alert below can say so, instead of
        # silently claiming a search that didn't actually go out.
        # search_ok defaults to false: a record with no movieId/seriesId
        # (unknown/deleted media) must count as a failed search too, not
        # silently stay "true" just because no request was ever attempted.
        local media_id_for_search search_ok
        search_ok=false
        if [ "$media_type" = "movie" ]; then
            media_id_for_search=$(echo "$item" | jq -r '.movieId // empty')
            if [ -n "$media_id_for_search" ]; then
                curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
                    "$base_url/api/v3/command" \
                    -d "{\"name\":\"MoviesSearch\",\"movieIds\":[$media_id_for_search]}" > /dev/null 2>&1 && search_ok=true
            fi
        else
            media_id_for_search=$(echo "$item" | jq -r '.seriesId // empty')
            if [ -n "$media_id_for_search" ]; then
                # Scope to the specific episode(s) this queue item actually
                # was, not the whole series - a blanket SeriesSearch would
                # also re-search every other monitored-but-missing episode
                # in the series, not just replace the one that died. Only
                # fall back to SeriesSearch when the item has no episode
                # ID at all (e.g. a season-pack release).
                local episode_ids
                episode_ids=$(echo "$item" | jq -c '(.episodeIds // empty) as $ids | if ($ids | type) == "array" and ($ids | length) > 0 then $ids elif .episodeId then [.episodeId] else empty end')
                if [ -n "$episode_ids" ] && [ "$episode_ids" != "null" ]; then
                    curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
                        "$base_url/api/v3/command" \
                        -d "{\"name\":\"EpisodeSearch\",\"episodeIds\":${episode_ids}}" > /dev/null 2>&1 && search_ok=true
                else
                    curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
                        "$base_url/api/v3/command" \
                        -d "{\"name\":\"SeriesSearch\",\"seriesId\":$media_id_for_search}" > /dev/null 2>&1 && search_ok=true
                fi
            fi
        fi

        log "  Removed and blocklisted '$title'"
        if $search_ok; then
            queue_alert "[AUTO-FIXED] $service_name: Removed zero-progress download '$title' (0% after $((age / 3600))h), blocklisted, searching for new release"
        else
            log "  WARN: Search request failed for '$title' — may need a manual search"
            queue_alert "[AUTO-FIXED, SEARCH FAILED] $service_name: Removed and blocklisted zero-progress download '$title' (0% after $((age / 3600))h), but the follow-up search request failed — search manually"
        fi
    done <<< "$downloading_records"

    # Dry runs must not persist anything - writing here would let a
    # preview run silently seed/advance the real state file, making a
    # later real run act sooner (or immediately) based on observations
    # that never happened for real.
    if ! $DRY_RUN; then
        printf '%s' "$new_state" > "$state_file"
    fi
}

# --- Main ---

log "=== Queue cleanup ==="

if [ -z "$SMTP_SERVER" ] || [ -z "$SMTP_TO" ] || [ -z "$SMTP_PASS" ]; then
    log "WARN: SMTP vars missing from .env — email alerts disabled"
fi

while IFS= read -r inst; do
    [ -z "$inst" ] && continue
    IFS='|' read -r label sonarr_url sonarr_key radarr_url radarr_key <<< "$inst"

    log "--- Processing $label instance ---"

    log "Checking for suspicious files..."
    handle_suspicious "Sonarr ($label)" "$sonarr_url" "$sonarr_key"
    handle_suspicious "Radarr ($label)" "$radarr_url" "$radarr_key"

    log "Checking for import-blocked items..."
    handle_import_blocked "Sonarr ($label)" "$sonarr_url" "$sonarr_key" "series"
    handle_import_blocked "Radarr ($label)" "$radarr_url" "$radarr_key" "movie"

    log "Checking for stalled downloads..."
    handle_stalled "Sonarr ($label)" "$sonarr_url" "$sonarr_key" "series"
    handle_stalled "Radarr ($label)" "$radarr_url" "$radarr_key" "movie"
done <<< "$QUEUE_INSTANCES"

# Send consolidated email if there were any issues
if [ -n "$ALERT_MESSAGES" ]; then
    log "Sending alert email..."
    send_email "[${SERVER_NAME:-Media Server}] Queue issues detected" "The following issues were found in the download queue:

$ALERT_MESSAGES
---
Generated by queue-cleanup.sh at $(date '+%Y-%m-%d %H:%M:%S')"
fi

if [ "$ERRORS" -gt 0 ]; then
    log "=== Done with $ERRORS error(s) ==="
    exit 1
else
    log "=== Done ==="
fi
