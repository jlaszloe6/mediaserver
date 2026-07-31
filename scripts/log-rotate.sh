#!/bin/bash
# log-rotate.sh - cap /var/log/cron/*.log files so they don't grow forever
#
# Nothing in this stack rotated these logs before - cron.log (busybox
# crond's own master log, logged continuously for the container's entire
# lifetime) grew to 180MB+ over a few months, since crond logs every
# dispatch and even idle wakeup polling at log level 2.
#
# Truncates each file IN PLACE (same inode preserved throughout) once it
# exceeds MAX_BYTES, keeping only the most recent KEEP_BYTES. In-place
# truncation matters specifically for cron.log: busybox crond opens it
# once at container start (-L logfile) and keeps writing to that same
# file descriptor for as long as the container runs. Deleting or
# renaming the file would orphan that descriptor - crond would keep
# writing into an unlinked inode and none of it would ever show up in
# the new file. Truncating the existing inode's content is safe because
# crond writes in append mode, so it just keeps appending from the new
# (shorter) end.
#
# Runs in both the cron and ebook-pipeline containers - both write to
# their own separate /var/log/cron volume, same layout.

set -euo pipefail

LOG_DIR="/var/log/cron"
MAX_BYTES=$((10 * 1024 * 1024))   # rotate once a file exceeds 10MB
KEEP_BYTES=$((1 * 1024 * 1024))   # keep the most recent 1MB after rotating

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

shopt -s nullglob
for f in "$LOG_DIR"/*.log; do
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_BYTES" ]; then
        tmp=$(mktemp)
        tail -c "$KEEP_BYTES" "$f" > "$tmp"
        : > "$f"
        cat "$tmp" >> "$f"
        rm -f "$tmp"
        log "rotated $f (was ${size} bytes, kept last ${KEEP_BYTES} bytes)"
    fi
done
