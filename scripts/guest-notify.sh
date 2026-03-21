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
<body style=\"margin:0;padding:0;background:#0f0f1a;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;\">
<table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:#0f0f1a;padding:24px 0;\">
<tr><td align=\"center\">
<table width=\"600\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:600px;width:100%;background:#16213e;border-radius:12px;overflow:hidden;\">
<tr><td style=\"background:#1a1a2e;padding:20px 24px;border-bottom:2px solid #e94560;\">
<img src=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAABmJLR0QA/wD/AP+gvaeTAAAE8ElEQVRogc2az29bRRDHP7PvOU7ixE6rtmnsJEUIUWilphVw6gWhVEHil9QGgUQvHOEfKLdKIC6FAxIXJARcqKhE2goqQCUcEBIHVIRK0oIqfgiRH7htmtqJncT2ezscUhvbjWO7OLa/J+/M7njGO/uded4nVEAsdvAg2OetZVREh0B2AU6l+Q2GD3pDVWaASWP8T+fmrv680UQpF8RiIw+q6ingua32sj7oeWOcE7Ozl38rlpYEMDBw4EkRzgCRpvpWO5aB4/PzU5/nBYUAYrGDT6nazyhKE8WgbgcqLmoMYJrjpiqoxdgc4mcQtFjrW6vPxOPTXxUCWE8bewkknJ9lnU6s29kch6vAeKsYP1MsSjqOfWRm5sofBkBV3ypxPtDdNs4DWLcL63YXiyLWmlMAEo2OHAL9qTC5jX75cpTthIr4h4yIjhckSNs6D+s7oVI4h6JqjhlrGc1L1Am2xrM6oCZQNJIjRoQ9+aEtUbYn1OkoHg4bYEd+JKZJNPk/oKVU3m8o4f27CnP7QUp8dNr/J6+ChgWwr7M1BNCwAE4PRjmxYwfdUp/JsZ4Qz4Z76DL3lr4NC8BFON4X5tzwIIe7u6svyK8TYdANcDQcZptTf7fe8DMQC7i8F93N27v7a3Lo4nKa37M5IsZwNNzLbtet6/u27BCP9YS4MDzEeKR3U27zUCZTKa5lskRdl6fDvYTr4JYtZaGIYzi5cycfxAa4L1C5SCrw49oq132P+90A4+EIHVLbmWgKjT7W1cXE8CCvbt9GoMJ+JH3L6cQS857H3o4AR0Khmmw3rQ4ERXhl+zY+GYqyP7gx5aat5aNEkpRaDoe6GAhUP0NNL2R7g0E+HqpMuWnr800qDSo83t1T1V5LKnE1yv01kyVhffZ0BAhX6c9a2kpUotyk75NSS5cIoXYOYDNI+aN8BdRXNRqMuZzHGzcX+H5lpUQecRxCIqypkrZ2UxstCcBDOZNY5t1bi6zo3Q4+HOygzzhMZzIstVsA1zIZTt5Y4Goms6E+ZBxGe0Igyrcrqar2mhZARpUPbyd4fzFBrkJ2h4zh5b4IPWL4Lr3CPzm/qt2mBHBpdZXXbyzwVy5XcU7EMbwQCRN1Xa5lc0ym0zXZ3tIAkr7lncVbnE0ub8ooAjza2UW/4/Knl2NiKUlWa+GgLQzgYirNmzcXuO1vngYuwhM9IR7oCDDveXyxnGLJ3/zglq5vMCpRYyWM9YbYEwiQtJYvl1NVAy5HwwKoRo0V16ky6+WYTKVZtbWlTTEkGj1QWOUF++o2kMe+ziC/rG1MjY2Gm0kUPjeslWiW8+Vo216oVhig6NTUnrstQym9+gb0Rn4kNXJvKyGUsFTc3LnKXFf6lStlu6DMxxkD8vV/ygzU1IW3Cor42WLBRWOMnM2PBMV4a833q0YYb634MUeNsefM3Nzly6DnC5P8DKY0yraA+Nmym0qZmJ29MmUAjHFOAMm8yngrGG+V9kgnxXirOF5Ja5Lwffsa3LncWFqKL0Yiu6ZU5UXu1AZRH/Gz61smBpDyy4Ut9FkR7Ho25FYw6hVrfVWOxePTl+CuVw1GxkT0DHDvPcXWYhl4aX5+6kJeUPLXVyp1/Y++vp0TIIPAQ2zwMkiLoKqctVbH4/HpH4oVFR2MxfaPWOuOi+goMAz009TXbbgO/A06aYxOzM5emdpo4r8PYtx5TTbwtQAAAABJRU5ErkJggg==\" width=\"32\" height=\"32\" alt=\"\" style=\"vertical-align:middle;margin-right:10px;border-radius:6px;\"><span style=\"color:#fff;font-size:18px;font-weight:700;vertical-align:middle;\">Media Server</span>
</td></tr>
<tr><td style=\"padding:24px;color:#e0e0e0;font-size:15px;line-height:1.6;\">
<p style=\"font-size:17px;color:#fff;text-align:center;margin-bottom:16px;\">New content available!</p>
<ul style=\"list-style:none;padding:0;font-size:1.1rem;\">
${ITEMS}
</ul>
<p style=\"color:#5a6a8a;margin-top:1.5rem;font-size:0.9rem;text-align:center;\">Open Plex to start watching!</p>
</td></tr>
<tr><td style=\"padding:16px 24px;border-top:1px solid #1a3a5c;color:#5a6a8a;font-size:12px;text-align:center;\">
Sent from Media Server Status Page
</td></tr>
</table>
</td></tr>
</table>
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
From: Freya Media Server <$SMTP_FROM>
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
