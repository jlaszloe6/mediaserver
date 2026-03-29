#!/bin/bash
# pipeline-monitor.sh - Monitor media pipeline health and alert on issues
#
# Checks for:
# 1. Prowlarr indexers disabled (nCore, etc.)
# 2. Sonarr/Radarr queue items stuck for 2+ hours
# 3. NFS mount health (media directories accessible)
# 4. Sonarr/Radarr connection to Transmission
# 5. Jellyfin library empty (potential mount issue)
#
# Sends a single consolidated email if any issues are found.
# Uses a state file to avoid repeated alerts for the same issue.
# Run every 30 minutes via cron.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

STATE_FILE="/var/tmp/pipeline-monitor.state"
ALERT_MESSAGES=""
ISSUES=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

alert() {
    local msg="$1"
    ALERT_MESSAGES="${ALERT_MESSAGES}• ${msg}
"
    ISSUES=$((ISSUES + 1))
}

send_email() {
    local subject="$1"
    local body="$2"

    if [ -z "${SMTP_SERVER:-}" ] || [ -z "${SMTP_FROM:-}" ]; then
        log "WARN: No SMTP config — cannot send email alert"
        return 1
    fi

    local to="${ADMIN_EMAIL:-${SMTP_FROM}}"

    curl -sf --url "smtp://$SMTP_SERVER:${SMTP_PORT:-587}" \
        --login-options "AUTH=LOGIN" \
        --mail-from "$SMTP_FROM" \
        --mail-rcpt "$to" \
        --user "${SMTP_USER}:${SMTP_PASSWORD}" \
        -T - <<EOF
From: ${SERVER_NAME:-Media Server} <$SMTP_FROM>
To: $to
Subject: $subject
Content-Type: text/plain; charset=utf-8

$body
EOF

    if [ $? -eq 0 ]; then
        log "Email sent: $subject"
    else
        log "WARN: Failed to send email"
    fi
}

# --- Check 1: Prowlarr disabled indexers ---
check_prowlarr_indexers() {
    log "Checking Prowlarr indexer status..."

    local status
    status=$(curl -sf -H "X-Api-Key: $PROWLARR_API_KEY" \
        "http://prowlarr:9696/api/v1/indexerstatus" 2>/dev/null) || {
        alert "Prowlarr unreachable — cannot check indexer status"
        return
    }

    local disabled_count
    disabled_count=$(echo "$status" | jq 'length')

    if [ "$disabled_count" -gt 0 ]; then
        local indexers
        indexers=$(curl -sf -H "X-Api-Key: $PROWLARR_API_KEY" \
            "http://prowlarr:9696/api/v1/indexer" 2>/dev/null) || return

        local names=""
        for i in $(seq 0 $((disabled_count - 1))); do
            local idx_id
            idx_id=$(echo "$status" | jq -r ".[$i].indexerId")
            local disabled_till
            disabled_till=$(echo "$status" | jq -r ".[$i].disabledTill")
            local name
            name=$(echo "$indexers" | jq -r ".[] | select(.id == $idx_id) | .name")
            names="${names}${name} (disabled till ${disabled_till}), "
        done
        names="${names%, }"
        alert "Prowlarr indexers disabled: ${names}"
    fi

    log "Prowlarr: ${disabled_count} indexer(s) disabled"
}

# --- Check 2: Stuck queue items ---
check_stuck_queue() {
    local service_name="$1"
    local base_url="$2"
    local api_key="$3"

    log "Checking ${service_name} queue..."

    local queue
    queue=$(curl -sf -H "X-Api-Key: $api_key" \
        "${base_url}/api/v3/queue?page=1&pageSize=100" 2>/dev/null) || {
        alert "${service_name} unreachable — cannot check queue"
        return
    }

    local now_epoch
    now_epoch=$(date +%s)
    local stuck_threshold=7200  # 2 hours

    local records
    records=$(echo "$queue" | jq '.records // []')
    local count
    count=$(echo "$records" | jq 'length')

    for i in $(seq 0 $((count - 1))); do
        local title status added
        title=$(echo "$records" | jq -r ".[$i].title")
        status=$(echo "$records" | jq -r ".[$i].trackedDownloadStatus")
        added=$(echo "$records" | jq -r ".[$i].added")

        if [ "$status" = "warning" ] || [ "$status" = "error" ]; then
            local msgs
            msgs=$(echo "$records" | jq -r ".[$i].statusMessages[]?.messages[]? // empty" 2>/dev/null)
            alert "${service_name} queue issue: ${title} (${status}) ${msgs}"
            continue
        fi

        # Check if downloading for too long with no progress
        local added_epoch
        added_epoch=$(date -d "$added" +%s 2>/dev/null) || continue
        local age=$((now_epoch - added_epoch))
        local sizeleft
        sizeleft=$(echo "$records" | jq -r ".[$i].sizeleft")
        local size
        size=$(echo "$records" | jq -r ".[$i].size")

        if [ "$age" -gt "$stuck_threshold" ] && [ "$sizeleft" = "$size" ]; then
            alert "${service_name} stuck download (0% after 2h): ${title}"
        fi
    done
}

# --- Check 3: NFS mount health ---
check_nfs_mount() {
    log "Checking NFS mount..."

    local media_root="${MEDIA_ROOT:-/mnt/mediaserver}"
    # Inside cron container, media is at /mnt/mediaserver
    local check_path="/mnt/mediaserver/media"

    if [ ! -d "$check_path" ]; then
        alert "NFS mount missing: ${check_path} does not exist"
        return
    fi

    # Check if we can list the directory (hangs if NFS is stale)
    local result
    result=$(timeout 5 ls "$check_path" 2>&1) || {
        alert "NFS mount stale or unresponsive: ${check_path}"
        return
    }

    log "NFS mount OK"
}

# --- Check 4: Download client connectivity ---
check_download_client() {
    log "Checking Transmission connectivity..."

    local resp
    resp=$(curl -sf -o /dev/null -w "%{http_code}" \
        "http://transmission:9091/transmission/web/" 2>/dev/null) || resp="000"

    if [ "$resp" = "000" ]; then
        alert "Transmission unreachable from cron container"
    else
        log "Transmission reachable (HTTP ${resp})"
    fi
}

# --- Check 5: Jellyfin library sanity ---
check_jellyfin_library() {
    log "Checking Jellyfin library..."

    local items
    items=$(curl -sf -H "X-Emby-Token: $JELLYFIN_API_KEY" \
        "http://jellyfin:8096/Items/Counts" 2>/dev/null) || {
        alert "Jellyfin unreachable — cannot check library"
        return
    }

    local movie_count series_count
    movie_count=$(echo "$items" | jq '.MovieCount // 0')
    series_count=$(echo "$items" | jq '.SeriesCount // 0')

    if [ "$movie_count" -eq 0 ] && [ "$series_count" -eq 0 ]; then
        alert "Jellyfin library is empty — possible NFS mount issue"
    fi

    log "Jellyfin library: ${movie_count} movies, ${series_count} series"
}

# --- Main ---
log "=== Pipeline health check ==="

check_nfs_mount
check_prowlarr_indexers
check_stuck_queue "Sonarr" "http://sonarr:8989" "$SONARR_API_KEY"
check_stuck_queue "Radarr" "http://radarr:7878" "$RADARR_API_KEY"
check_download_client
check_jellyfin_library

if [ "$ISSUES" -gt 0 ]; then
    log "Found ${ISSUES} issue(s)"

    # Deduplicate: only alert if issues changed since last run
    current_hash=$(echo "$ALERT_MESSAGES" | md5sum | cut -d' ' -f1)
    previous_hash=""
    if [ -f "$STATE_FILE" ]; then
        previous_hash=$(cat "$STATE_FILE" 2>/dev/null || true)
    fi

    if [ "$current_hash" != "$previous_hash" ]; then
        send_email \
            "[${SERVER_NAME:-Media Server}] Pipeline Alert: ${ISSUES} issue(s)" \
            "Pipeline health check found ${ISSUES} issue(s):

${ALERT_MESSAGES}
Checked at: $(date '+%Y-%m-%d %H:%M:%S %Z')

This is an automated alert from the media server pipeline monitor."
        echo "$current_hash" > "$STATE_FILE"
        log "Alert email sent"
    else
        log "Same issues as last run — skipping duplicate alert"
    fi
else
    log "All checks passed"
    # Clear state file when healthy
    rm -f "$STATE_FILE"
fi

log "=== Done ==="
