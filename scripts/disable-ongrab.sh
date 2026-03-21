#!/bin/bash
# Disable onGrab email notifications in Sonarr and Radarr.
# Run on the server: ./scripts/disable-ongrab.sh
set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env not found at $ENV_FILE"
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

SONARR_KEY="${SONARR_API_KEY:-}"
RADARR_KEY="${RADARR_API_KEY:-}"

disable_ongrab() {
    local name="$1" base_url="$2" api_key="$3"

    if [ -z "$api_key" ]; then
        echo "SKIP: $name — no API key"
        return
    fi

    local notif_id
    notif_id=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/notification" \
        | jq -r '.[] | select(.name=="Email") | .id')

    if [ -z "$notif_id" ]; then
        echo "SKIP: $name — no Email notification configured"
        return
    fi

    local current
    current=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/notification/$notif_id")

    local on_grab
    on_grab=$(echo "$current" | jq -r '.onGrab')
    if [ "$on_grab" = "false" ]; then
        echo "OK:   $name — onGrab already disabled"
        return
    fi

    local updated
    updated=$(echo "$current" | jq '.onGrab = false')
    curl -sf -X PUT -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
        "$base_url/api/v3/notification/$notif_id" -d "$updated" > /dev/null

    echo "DONE: $name — onGrab disabled"
}

disable_ongrab "Sonarr" "http://localhost:8989" "$SONARR_KEY"
disable_ongrab "Radarr" "http://localhost:7878" "$RADARR_KEY"
