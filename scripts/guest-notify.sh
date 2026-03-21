#!/bin/bash
# guest-notify.sh - Email guests when new content is available
#
# Checks guest Sonarr/Radarr history for recent imports and sends
# email notifications to all active guests.
#
# Uses a state file to track what's already been notified.
# Run every 15 minutes via cron.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found" >&2
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

SONARR_GUEST_KEY="${SONARR_GUEST_API_KEY:-}"
RADARR_GUEST_KEY="${RADARR_GUEST_API_KEY:-}"
SMTP_PASS="$SMTP_PASSWORD"

if [ -z "$SONARR_GUEST_KEY" ] || [ -z "$RADARR_GUEST_KEY" ]; then
    exit 0  # guest pipeline not configured
fi

SONARR_GUEST_URL="http://localhost:8990"
RADARR_GUEST_URL="http://localhost:7879"
DB_PATH="${STATUSPAGE_DB_PATH:-/config/statuspage/statuspage.db}"
STATE_FILE="/var/tmp/mediaserver-guest-notify.json"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Get active guest emails from statuspage DB
get_guest_emails() {
    if [ ! -f "$DB_PATH" ]; then
        return
    fi
    sqlite3 "$DB_PATH" "SELECT name, email FROM guests WHERE active = 1;" 2>/dev/null
}

# Load last notification timestamp (ISO 8601)
LAST_CHECK=""
if [ -f "$STATE_FILE" ]; then
    LAST_CHECK=$(jq -r '.last_check // ""' "$STATE_FILE")
fi

if [ -z "$LAST_CHECK" ]; then
    # First run: save current time, don't notify
    jq -n --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{last_check: $ts}' > "$STATE_FILE"
    log "First run — saved baseline timestamp"
    exit 0
fi

NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Fetch recent history from guest Radarr (imported movies since last check)
new_movies=$(curl -sf -H "X-Api-Key: $RADARR_GUEST_KEY" \
    "$RADARR_GUEST_URL/api/v3/history?pageSize=50&sortDirection=descending&sortKey=date" 2>/dev/null \
    | jq -r --arg since "$LAST_CHECK" '
        [.records[] |
         select(.eventType == "downloadFolderImported" and .date > $since) |
         .movie.title + " (" + (.movie.year // "" | tostring) + ")"] | unique | .[]' 2>/dev/null) || true

# Fetch recent history from guest Sonarr (imported episodes since last check)
new_episodes=$(curl -sf -H "X-Api-Key: $SONARR_GUEST_KEY" \
    "$SONARR_GUEST_URL/api/v3/history?pageSize=50&sortDirection=descending&sortKey=date&includeSeries=true&includeEpisode=true" 2>/dev/null \
    | jq -r --arg since "$LAST_CHECK" '
        [.records[] |
         select(.eventType == "downloadFolderImported" and .date > $since) |
         .series.title + " S" + (.episode.seasonNumber // 0 | tostring | if length == 1 then "0" + . else . end) +
         "E" + (.episode.episodeNumber // 0 | tostring | if length == 1 then "0" + . else . end)] | unique | .[]' 2>/dev/null) || true

# Update state
jq -n --arg ts "$NOW" '{last_check: $ts}' > "$STATE_FILE"

# Combine results
ITEMS=""
if [ -n "$new_movies" ]; then
    while IFS= read -r movie; do
        [ -z "$movie" ] && continue
        ITEMS="${ITEMS}<li style=\"padding: 4px 0;\">&#127916; ${movie}</li>"
        log "New movie: $movie"
    done <<< "$new_movies"
fi
if [ -n "$new_episodes" ]; then
    while IFS= read -r episode; do
        [ -z "$episode" ] && continue
        ITEMS="${ITEMS}<li style=\"padding: 4px 0;\">&#128250; ${episode}</li>"
        log "New episode: $episode"
    done <<< "$new_episodes"
fi

if [ -z "$ITEMS" ]; then
    log "No new guest content since $LAST_CHECK"
    exit 0
fi

# Get guest list
GUESTS=$(get_guest_emails)
if [ -z "$GUESTS" ]; then
    log "No active guests to notify"
    exit 0
fi

# Build email
SUBJECT="New content available on Plex!"
HTML_BODY="<html>
<body style=\"font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;\">
<div style=\"background: #1a1a2e; color: #e0e0e0; border-radius: 12px; padding: 2rem;\">
    <h2 style=\"color: #fff; margin: 0 0 1rem 0; text-align: center;\">New content available!</h2>
    <ul style=\"list-style: none; padding: 0; font-size: 1.1rem;\">
    ${ITEMS}
    </ul>
    <p style=\"color: #8892b0; margin-top: 1.5rem; font-size: 0.9rem; text-align: center;\">Open Plex to start watching!</p>
</div>
<hr style=\"border: none; border-top: 1px solid #ddd; margin: 20px 0;\">
<p style=\"color: #888; font-size: 12px;\">Sent from Media Server</p>
</body>
</html>"

# Send to each guest
while IFS='|' read -r name email; do
    [ -z "$email" ] && continue
    log "Notifying $name ($email)"

    curl -sf --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
        --login-options "AUTH=LOGIN" \
        --mail-from "$SMTP_FROM" \
        --mail-rcpt "$email" \
        --user "$SMTP_USER:$SMTP_PASS" \
        -T - <<EOF
From: Media Server <$SMTP_FROM>
To: $email
Subject: $SUBJECT
Content-Type: text/html; charset=utf-8
MIME-Version: 1.0

$HTML_BODY
EOF

    if [ $? -eq 0 ]; then
        log "  Sent to $email"
    else
        log "  WARN: Failed to send to $email"
    fi
done <<< "$GUESTS"

log "Done"
