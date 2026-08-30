#!/bin/bash
# network-watchdog.sh - detect and self-heal a stuck host network connection
#
# Runs on the HOST (via systemd timer, as root) — not in the cron container,
# since it needs nmcli/systemctl access to the host's NetworkManager.
#
# Root cause this defends against: a WPA handshake glitch (e.g. AP band
# roaming) can land NetworkManager in a "need-auth" state, which waits
# indefinitely for a secrets-agent (GUI) prompt that never comes on a
# headless box — autoconnect never retries again on its own. One transient
# handshake failure has previously meant total, silent, indefinite network
# loss (both LAN and remote.it) until someone physically power-cycled it.

set -euo pipefail

STATE_DIR="/var/lib/network-watchdog"
DOWN_SINCE_FILE="$STATE_DIR/down-since"
NM_RESTARTED_FILE="$STATE_DIR/nm-restarted"
TARGETS=(1.1.1.1 8.8.8.8)
NM_RESTART_AFTER_SECS=300

mkdir -p "$STATE_DIR"

check_connectivity() {
    for target in "${TARGETS[@]}"; do
        if ping -c1 -W3 "$target" &>/dev/null; then
            return 0
        fi
    done
    return 1
}

now=$(date +%s)

if check_connectivity; then
    if [ -f "$DOWN_SINCE_FILE" ]; then
        down_since=$(cat "$DOWN_SINCE_FILE")
        echo "connectivity restored after $((now - down_since))s down"
        rm -f "$DOWN_SINCE_FILE" "$NM_RESTARTED_FILE"
    fi
    exit 0
fi

if [ ! -f "$DOWN_SINCE_FILE" ]; then
    echo "$now" > "$DOWN_SINCE_FILE"
fi
down_since=$(cat "$DOWN_SINCE_FILE")
elapsed=$((now - down_since))

echo "connectivity check failed (down ${elapsed}s), forcing NetworkManager reconnect"
nmcli networking off &>/dev/null || true
sleep 2
nmcli networking on &>/dev/null || true
sleep 5

if check_connectivity; then
    echo "recovered via nmcli networking toggle after ${elapsed}s down"
    rm -f "$DOWN_SINCE_FILE" "$NM_RESTARTED_FILE"
    exit 0
fi

if [ "$elapsed" -ge "$NM_RESTART_AFTER_SECS" ] && [ ! -f "$NM_RESTARTED_FILE" ]; then
    echo "still down after ${elapsed}s, restarting NetworkManager"
    systemctl restart NetworkManager
    touch "$NM_RESTARTED_FILE"
fi
