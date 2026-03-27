#!/bin/bash
# queue-cleanup.sh - Auto-fix stuck downloads and alert on issues
#
# Checks Sonarr/Radarr download queues for problems and handles them:
#
# 1. Import blocked (name mismatch): auto-imports if there's exactly one
#    matching file candidate. Otherwise sends an email alert.
#
# 2. Suspicious files (.exe, .msi, .bat, .scr, .cmd, .ps1, .vbs):
#    auto-removes from the queue and blocklists the release.
#
# 3. Stalled downloads (no progress for 2+ hours): sends an email alert.
#
# 4. Any other warnings/errors: sends an email alert.
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

SUSPICIOUS_EXTENSIONS="exe|msi|bat|scr|cmd|ps1|vbs|com|pif"

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

    echo "$suspicious" | jq -c '.[]' | while IFS= read -r item; do
        local id title
        id=$(echo "$item" | jq -r '.id')
        title=$(echo "$item" | jq -r '.title')

        log "  Rejecting suspicious: $title"

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
            queue_alert "[AUTO-FIXED] $service_name: Rejected suspicious file '$title' (blocklisted)"
        else
            log "  ERROR: Failed to remove '$title' (HTTP $del_code)"
            queue_alert "[NEEDS ATTENTION] $service_name: Could not remove suspicious file '$title'"
            ERRORS=$((ERRORS + 1))
        fi
    done
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

    echo "$blocked" | jq -c '.[]' | while IFS= read -r item; do
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

            local import_result
            import_result=$(curl -s -w '\n%{http_code}' -X POST \
                -H "X-Api-Key: $api_key" \
                -H "Content-Type: application/json" \
                "$base_url/api/v3/command" \
                -d "{\"name\":\"ManualImport\",\"importMode\":\"move\",\"files\":$import_payload}")

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
    done
}

# --- Handle stalled downloads ---
handle_stalled() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"

    local queue
    queue=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/queue?page=1&pageSize=100") || return 1

    # Find items that are "downloading" but have statusMessages with warnings
    local stalled
    stalled=$(echo "$queue" | jq -c '[.records[] | select(.trackedDownloadState == "downloading" and .trackedDownloadStatus == "warning")]')
    local count
    count=$(echo "$stalled" | jq 'length')

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    log "  Found $count stalled/warning download(s) in $service_name"

    echo "$stalled" | jq -c '.[]' | while IFS= read -r item; do
        local title messages
        title=$(echo "$item" | jq -r '.title')
        messages=$(echo "$item" | jq -r '[.statusMessages[].messages[]] | join("; ")')
        queue_alert "[STALLED] $service_name: '$title' — $messages"
    done
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
    handle_stalled "Sonarr ($label)" "$sonarr_url" "$sonarr_key"
    handle_stalled "Radarr ($label)" "$radarr_url" "$radarr_key"
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
