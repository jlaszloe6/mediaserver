#!/bin/bash
# Disable onGrab email notifications in Sonarr and Radarr.
# Run via: docker exec cron /scripts/disable-ongrab.sh
set -euo pipefail

source "$(dirname "$0")/lib/curl-secrets.sh"

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
        return 0
    fi

    # Every curl below is explicitly guarded with `|| { ...; return 1; }`
    # rather than relying on set -e to catch a failure. Calling this
    # function as part of an `||` list at the bottom of this file (so one
    # service's failure can't block the other's attempt) also exempts the
    # function's ENTIRE body from set -e for that invocation - a failing
    # command partway through would otherwise be silently ignored and
    # execution would fall through to later steps using bad/empty data,
    # instead of stopping and reporting the failure. Explicit checks here
    # mean disable_ongrab's own internal failures are never swallowed,
    # independent of how set -e treats the call site.
    local notif_list
    notif_list=$(curl -sf --max-time 15 -H "X-Api-Key: $api_key" "$base_url/api/v3/notification") || {
        echo "ERROR: $name — failed to fetch notifications"
        return 1
    }

    # jq parses are guarded too, not just the curls: since disable_ongrab
    # runs with set -e ignored for its whole body (see comment above), a
    # malformed-JSON response or a jq failure would otherwise leave
    # notif_id empty and silently fall into the "no Email notification"
    # SKIP branch below - indistinguishable from the genuinely-nothing-
    # to-do case, even though onGrab was never actually checked.
    local notif_id
    notif_id=$(echo "$notif_list" | jq -r '.[] | select(.name=="Email") | .id') || {
        echo "ERROR: $name — failed to parse notification list"
        return 1
    }

    if [ -z "$notif_id" ]; then
        echo "SKIP: $name — no Email notification configured"
        return 0
    fi

    local current
    current=$(curl -sf --max-time 15 -H "X-Api-Key: $api_key" "$base_url/api/v3/notification/$notif_id") || {
        echo "ERROR: $name — failed to fetch notification $notif_id"
        return 1
    }

    local on_grab
    on_grab=$(echo "$current" | jq -r '.onGrab') || {
        echo "ERROR: $name — failed to parse notification $notif_id"
        return 1
    }
    if [ "$on_grab" = "false" ]; then
        echo "OK:   $name — onGrab already disabled"
        return 0
    fi

    local updated
    updated=$(echo "$current" | jq '.onGrab = false') || {
        echo "ERROR: $name — failed to build update payload for notification $notif_id"
        return 1
    }
    curl -sf --max-time 15 -X PUT -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
        "$base_url/api/v3/notification/$notif_id" -d "$updated" > /dev/null || {
        echo "ERROR: $name — failed to update notification $notif_id"
        return 1
    }

    echo "DONE: $name — onGrab disabled"
}

# `|| echo ...` on each call (not two bare statements): keeps Sonarr's
# outcome from preventing Radarr's attempt. disable_ongrab now returns 1
# explicitly on any internal failure (see its own comment above), so this
# WARN only fires on a real, deliberately-reported failure - not on a
# silently-ignored one.
disable_ongrab "Sonarr" "http://sonarr:8989" "$SONARR_KEY" || echo "WARN: Sonarr — onGrab disable hit an error, see above"
disable_ongrab "Radarr" "http://radarr:7878" "$RADARR_KEY" || echo "WARN: Radarr — onGrab disable hit an error, see above"
