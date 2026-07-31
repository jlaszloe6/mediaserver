#!/bin/bash
# ebook-pipeline.sh - Fully automated ebook download -> Audiobookshelf pipeline
#
# Drop a .torrent file into $MEDIA_ROOT/watch-ebooks and this script:
# (deliberately NOT $MEDIA_ROOT/watch - that's Transmission's own native
# watch-dir, already enabled in the live settings.json for general
# downloads; sharing it would race this script's 5-min poll against
# Transmission's own few-second watch-dir scan, which would win almost
# every time and route ebook torrents to the wrong destination)
#   1. Adds it to Transmission via RPC with download-dir set to a dedicated
#      ebooks-incoming folder (Transmission's native watch-dir only supports
#      one global destination, so this uses the RPC API instead)
#   2. Polls Transmission for torrents in that folder that have finished
#   3. Extracts Title/Author from each ebook file via Calibre's ebook-meta,
#      converts non-epub formats via ebook-convert (epub is this project's
#      standard ebook format - see CLAUDE.md's Ebook Library section)
#   4. Copies the result into $MEDIA_ROOT/media/ebooks/<Author>/<Title>/
#      (copy, not move - leaves the original for tracker H&R seeding)
#   5. Triggers an Audiobookshelf "Ebooks" library scan
#   6. Emails a report, but only when something actually happened this run
#
# Runs in its own container (not the shared cron fleet) because it needs
# Calibre, which requires glibc and isn't a good fit for the Alpine cron image.

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

TRANSMISSION_URL="http://transmission:9091/transmission/rpc"
AUDIOBOOKSHELF_URL="http://audiobookshelf:13378"
AUDIOBOOKSHELF_KEY="${AUDIOBOOKSHELF_API_KEY:-}"

WATCH_DIR="/mnt/mediaserver/watch-ebooks"
INCOMING_DIR="/mnt/mediaserver/torrents/complete/ebooks-incoming"
TRANSMISSION_DOWNLOAD_DIR="/downloads/complete/ebooks-incoming"   # Transmission's own filesystem view
EBOOKS_LIBRARY_DIR="/mnt/mediaserver/media/ebooks"
PROCESSED_LOG="$INCOMING_DIR/.imported.log"
LOCK_FILE="/tmp/ebook-pipeline.lock"

SUPPORTED_EXTS=(epub mobi azw3 azw prc pdf rtf fb2)

ERRORS=0
ADDED=0
IMPORTED=0
FLAGGED=0
EMAIL_LINES=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

send_email() {
    local subject="$1"
    local body="$2"

    if [ -z "${SMTP_SERVER:-}" ] || [ -z "${SMTP_FROM:-}" ]; then
        log "WARN: No SMTP config - cannot send email report"
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
}

# --- Guard against overlapping runs: Calibre conversion is the first genuinely
# slow step any script in this repo has, so a run that spills past the next
# 5-minute tick must not race the next one on the same unlogged torrent hash.
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Another run is already in progress, skipping"
    exit 0
fi

if [ -z "$AUDIOBOOKSHELF_KEY" ]; then
    log "ERROR: AUDIOBOOKSHELF_API_KEY not set"
    exit 1
fi

mkdir -p "$WATCH_DIR" "$INCOMING_DIR" "$EBOOKS_LIBRARY_DIR"
touch "$PROCESSED_LOG"

log "=== Ebook pipeline ==="

# --- Transmission RPC helpers (mirrors scripts/transmission-cleanup.sh) ---
transmission_rpc() {
    curl -sf "$TRANSMISSION_URL" \
        -H "X-Transmission-Session-Id: $1" \
        -H "Content-Type: application/json" \
        -d "$2" 2>/dev/null
}

SID=$(curl -si "$TRANSMISSION_URL" 2>/dev/null \
    | grep -oP '(?<=X-Transmission-Session-Id: )\S+' | head -1) || true

if [ -z "$SID" ]; then
    log "ERROR: Cannot connect to Transmission"
    ERRORS=$((ERRORS + 1))
    EMAIL_LINES+="FAILED: cannot connect to Transmission RPC\n"
fi

# --- Phase 1: watch folder -> torrent-add ---
if [ -n "$SID" ]; then
    shopt -s nullglob
    for torrent_file in "$WATCH_DIR"/*.torrent; do
        name="$(basename "$torrent_file")"
        log "Found dropped torrent: $name"

        if $DRY_RUN; then
            log "  [DRY RUN] Would add '$name' via RPC and remove from watch folder"
            continue
        fi

        b64=$(base64 -w0 "$torrent_file")
        payload=$(jq -n --arg mi "$b64" --arg dir "$TRANSMISSION_DOWNLOAD_DIR" \
            '{method: "torrent-add", arguments: {metainfo: $mi, "download-dir": $dir, paused: false}}')

        response=$(transmission_rpc "$SID" "$payload") || response=""
        result=$(echo "$response" | jq -r '.result // empty' 2>/dev/null || true)

        # NOTE: Transmission's "result" is "success" both for a genuinely new
        # add AND for a duplicate-of-existing-torrent - must branch on which
        # "arguments" key is present, not on "result" alone.
        if [ "$result" = "success" ] && echo "$response" | jq -e '.arguments["torrent-added"]' >/dev/null 2>&1; then
            added_name=$(echo "$response" | jq -r '.arguments["torrent-added"].name')
            log "  Added '$added_name' (dest: $TRANSMISSION_DOWNLOAD_DIR)"
            rm -f "$torrent_file"
            ADDED=$((ADDED + 1))
            EMAIL_LINES+="Added torrent: $added_name\n"
        elif [ "$result" = "success" ] && echo "$response" | jq -e '.arguments["torrent-duplicate"]' >/dev/null 2>&1; then
            dup_name=$(echo "$response" | jq -r '.arguments["torrent-duplicate"].name')
            log "  '$dup_name' already known to Transmission - removing from watch folder"
            rm -f "$torrent_file"
        else
            log "  ERROR: torrent-add failed for '$name'"
            ERRORS=$((ERRORS + 1))
            EMAIL_LINES+="FAILED to add torrent '$name'\n"
            # leave the file in place - retried next run
        fi
    done
    shopt -u nullglob
fi

# --- Phase 2: completion poll -> convert -> organize ---
sanitize() {
    local s
    s=$(echo "$1" | tr -s ' \t' ' ' | tr '/\\:*?"<>|' '_' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Extracted metadata comes from a downloaded file's embedded fields -
    # untrusted input. Stripping path separators above isn't enough on its
    # own: a value of exactly "." or ".." contains no separator but would
    # still resolve one directory level up/in-place when joined into a path.
    case "$s" in
        .|..) s="_" ;;
    esac
    echo "$s"
}

if [ -n "$SID" ]; then
    TORRENTS_FILE=$(mktemp)
    trap 'rm -f "$TORRENTS_FILE"' EXIT

    # NOTE: Transmission's "isFinished" tracks whether seed ratio/idle limits
    # have been met (done seeding), not whether the download itself is
    # complete - a private-tracker torrent held for H&R seeding can sit at
    # percentDone==1 with isFinished==false for days. percentDone==1 is the
    # correct "download complete" signal.
    transmission_rpc "$SID" '{"method":"torrent-get","arguments":{"fields":["id","name","hashString","downloadDir","percentDone"]}}' \
        | jq -c --arg dir "$TRANSMISSION_DOWNLOAD_DIR" \
            '.arguments.torrents[]? | select(.downloadDir == $dir and .percentDone == 1)' \
        > "$TORRENTS_FILE" || true

    while IFS= read -r torrent; do
        [ -z "$torrent" ] && continue
        hash=$(echo "$torrent" | jq -r '.hashString')
        tname=$(echo "$torrent" | jq -r '.name')

        if grep -qxF "$hash" "$PROCESSED_LOG" 2>/dev/null; then
            continue
        fi

        # Torrent name is attacker-influenced (comes from whatever .torrent
        # file was dropped in the watch folder) - reject anything that could
        # escape $INCOMING_DIR when joined into a path, rather than trusting
        # it just because it came back from Transmission's own API.
        case "$tname" in
            */*|*..*)
                log "  WARN: torrent name '$tname' contains a path separator or '..' - skipping"
                continue
                ;;
        esac

        search_root="$INCOMING_DIR/$tname"
        if [ ! -e "$search_root" ]; then
            log "  WARN: expected path missing for '$tname' - will retry next run"
            continue
        fi

        mapfile -d '' ebook_files < <(
            find_args=()
            for ext in "${SUPPORTED_EXTS[@]}"; do
                find_args+=(-o -iname "*.${ext}")
            done
            find "$search_root" -type f \( "${find_args[@]:1}" \) -print0
        )

        if [ "${#ebook_files[@]}" -eq 0 ]; then
            log "  No recognized ebook files in '$tname'"
            EMAIL_LINES+="'$tname' completed but contains no recognized ebook files - needs manual review\n"
            FLAGGED=$((FLAGGED + 1))
            $DRY_RUN || echo "$hash" >> "$PROCESSED_LOG"
            continue
        fi

        for ebook_file in "${ebook_files[@]}"; do
            ext_lower=$(echo "${ebook_file##*.}" | tr 'A-Z' 'a-z')
            work_file="$ebook_file"

            # Calibre needs an explicit .mobi extension to recognize Mobipocket/.prc
            if [ "$ext_lower" = "prc" ]; then
                work_file="/tmp/$(basename "${ebook_file%.*}").mobi"
                cp "$ebook_file" "$work_file"
                ext_lower="mobi"
            fi

            meta=$(timeout 60 ebook-meta "$work_file" 2>/dev/null || true)
            title=$(echo "$meta" | grep -oP '^Title\s*:\s*\K.*' | sed 's/[[:space:]]*$//' || true)
            author=$(echo "$meta" | grep -oP "^Author\(s\)\s*:\s*\K[^\[]*" | sed 's/[[:space:]]*$//' || true)

            manual_review=false
            if [ -z "$title" ] || [ "$title" = "Unknown" ]; then
                title=$(basename "${ebook_file%.*}" | tr '_.' '  ')
                manual_review=true
            fi
            if [ -z "$author" ] || [ "$author" = "Unknown" ]; then
                author="Unknown Author"
                manual_review=true
            fi

            safe_author=$(sanitize "$author")
            safe_title=$(sanitize "$title")
            dest_dir="$EBOOKS_LIBRARY_DIR/$safe_author/$safe_title"
            dest_file="$dest_dir/$safe_title.epub"

            if $DRY_RUN; then
                log "  [DRY RUN] Would import '$title' by $author -> $dest_file"
                continue
            fi

            if [ -e "$dest_file" ]; then
                log "  Already present, skipping: $dest_file"
                continue
            fi

            mkdir -p "$dest_dir"

            convert_ok=true
            if [ "$ext_lower" = "epub" ]; then
                cp "$work_file" "$dest_file" || convert_ok=false
            else
                if ! xvfb-run -a ebook-convert "$work_file" "$dest_file" \
                    --title "$title" --authors "$author" >/tmp/ebook-convert.log 2>&1; then
                    convert_ok=false
                fi
            fi

            if ! $convert_ok; then
                log "  ERROR: conversion failed for '$ebook_file'"
                EMAIL_LINES+="FAILED to convert '$(basename "$ebook_file")' (torrent: $tname)\n"
                ERRORS=$((ERRORS + 1))
                continue
            fi

            IMPORTED=$((IMPORTED + 1))
            if $manual_review; then
                FLAGGED=$((FLAGGED + 1))
                EMAIL_LINES+="Imported (NEEDS REVIEW - metadata guessed): '$title' by $author\n"
            else
                EMAIL_LINES+="Imported: '$title' by $author\n"
            fi
        done

        $DRY_RUN || echo "$hash" >> "$PROCESSED_LOG"
    done < "$TORRENTS_FILE"
fi

# --- Phase 3: trigger Audiobookshelf scan + send email ---
if [ "$IMPORTED" -gt 0 ] && ! $DRY_RUN; then
    log "--- Triggering Audiobookshelf Ebooks library scan ---"

    libraries=$(curl -sf -H "Authorization: Bearer $AUDIOBOOKSHELF_KEY" "$AUDIOBOOKSHELF_URL/api/libraries") || {
        log "ERROR: Failed to fetch Audiobookshelf libraries"
        ERRORS=$((ERRORS + 1))
        libraries=""
    }

    library_id=$(echo "$libraries" | jq -r '.libraries[] | select(.name == "Ebooks") | .id' 2>/dev/null)

    if [ -z "$library_id" ]; then
        log "ERROR: Could not find 'Ebooks' library in Audiobookshelf"
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

log "  Torrents added: $ADDED, Books imported: $IMPORTED, Flagged: $FLAGGED, Errors: $ERRORS"

if [ "$ADDED" -gt 0 ] || [ "$IMPORTED" -gt 0 ] || [ "$FLAGGED" -gt 0 ] || [ "$ERRORS" -gt 0 ]; then
    subject="[${SERVER_NAME:-Media Server}] Ebook pipeline: ${ADDED} added, ${IMPORTED} imported"
    [ "$FLAGGED" -gt 0 ] && subject+=", ${FLAGGED} flagged"
    [ "$ERRORS" -gt 0 ] && subject+=", ${ERRORS} error(s)"

    body="$(printf '%b' "$EMAIL_LINES")

---
Generated by ebook-pipeline.sh at $(date '+%Y-%m-%d %H:%M:%S')"

    if send_email "$subject" "$body"; then
        log "Report email sent"
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    log "=== Done with $ERRORS error(s) ==="
    exit 1
else
    log "=== Done ==="
fi
