#!/bin/bash
# audiobook-import.sh - Copy completed audiobook downloads into Audiobookshelf's library
#
# There's no Lidarr/Sonarr-equivalent acquisition app for audiobooks (Readarr is
# discontinued), so audiobooks are grabbed manually into Transmission under the
# "audiobooks" category. This script picks up anything that lands in
# $MEDIA_ROOT/torrents/complete/audiobooks, copies it into
# $MEDIA_ROOT/media/audiobooks (leaving the original in place so nCore's 72h
# H&R seeding requirement is unaffected), and triggers an Audiobookshelf scan.
#
# Run periodically via cron, or manually after adding a torrent.

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

AUDIOBOOKSHELF_URL="http://audiobookshelf:13378"
AUDIOBOOKSHELF_KEY="${AUDIOBOOKSHELF_API_KEY:-}"
SOURCE_DIR="$MEDIA_ROOT/torrents/complete/audiobooks"
DEST_DIR="$MEDIA_ROOT/media/audiobooks"

ERRORS=0
IMPORTED=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [ -z "$AUDIOBOOKSHELF_KEY" ]; then
    log "ERROR: AUDIOBOOKSHELF_API_KEY not set"
    exit 1
fi

log "=== Audiobook import ==="

if [ ! -d "$SOURCE_DIR" ]; then
    log "No source directory at $SOURCE_DIR, nothing to do"
    exit 0
fi

mkdir -p "$DEST_DIR"

shopt -s nullglob
for item in "$SOURCE_DIR"/*/; do
    name="$(basename "$item")"
    dest="$DEST_DIR/$name"

    if [ -e "$dest" ]; then
        continue
    fi

    if $DRY_RUN; then
        log "  [DRY RUN] Would import '$name'"
        IMPORTED=$((IMPORTED + 1))
        continue
    fi

    if cp -r "$item" "$dest"; then
        log "  Imported '$name'"
        IMPORTED=$((IMPORTED + 1))
    else
        log "  ERROR: Failed to copy '$name'"
        ERRORS=$((ERRORS + 1))
    fi
done
shopt -u nullglob

log "  Audiobooks imported: $IMPORTED"

if [ "$IMPORTED" -gt 0 ] && ! $DRY_RUN; then
    log "--- Triggering Audiobookshelf library scan ---"

    libraries=$(curl -sf -H "Authorization: Bearer $AUDIOBOOKSHELF_KEY" "$AUDIOBOOKSHELF_URL/api/libraries") || {
        log "ERROR: Failed to fetch Audiobookshelf libraries"
        ERRORS=$((ERRORS + 1))
        libraries=""
    }

    library_id=$(echo "$libraries" | jq -r '.libraries[] | select(.name == "Audiobooks") | .id' 2>/dev/null)

    if [ -z "$library_id" ]; then
        log "ERROR: Could not find 'Audiobooks' library in Audiobookshelf"
        ERRORS=$((ERRORS + 1))
    else
        scan_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
            -H "Authorization: Bearer $AUDIOBOOKSHELF_KEY" \
            "$AUDIOBOOKSHELF_URL/api/libraries/$library_id/scan")

        if [ "$scan_code" = "200" ]; then
            log "  Scan triggered"
        else
            log "  ERROR: Failed to trigger scan (HTTP $scan_code)"
            ERRORS=$((ERRORS + 1))
        fi
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    log "=== Done with $ERRORS error(s) ==="
    exit 1
else
    log "=== Done ==="
fi
