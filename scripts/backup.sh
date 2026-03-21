#!/bin/bash
# backup.sh - Daily backup of all service configs and .env to NAS
#
# Creates a compressed tarball containing:
# - All service config directories (Plex cache/metadata excluded)
# - SQLite database safe snapshots (via sqlite3 .backup command)
# - The .env file
# - A manifest listing what was backed up
#
# Rotates old backups based on BACKUP_RETENTION_DAYS.
# Run via cron daily at 2:30 AM.

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
    esac
done

set -euo pipefail

# Load .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE" >&2
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

BACKUP_DIR="${BACKUP_DIR:-${MEDIA_ROOT}/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
STAGING="/tmp/backup-$TIMESTAMP"
WARNINGS=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2
    WARNINGS=$((WARNINGS + 1))
}

# --- Pre-flight checks ---

if [ ! -d "/config/all-configs" ]; then
    echo "ERROR: /config/all-configs not mounted (run inside cron container)" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

if [ "$DRY_RUN" = true ]; then
    log "DRY RUN — no files will be created"
    log "Backup target: $BACKUP_DIR/backup-$TIMESTAMP.tar.gz"
    log "Retention: $BACKUP_RETENTION_DAYS days"
    log ""
    log "Config directories to back up:"
    ls -1d /config/all-configs/*/ 2>/dev/null | sed 's|/config/all-configs/||;s|/$||' | while read -r dir; do
        echo "  - $dir"
    done
    log ""
    log "Plex exclusions: Cache, Metadata, Media, Crash Reports, Logs"
    log ""
    log "SQLite snapshots:"
    for svc in sonarr radarr prowlarr tautulli sonarr-guest radarr-guest; do
        echo "  - $svc (via docker exec)"
    done
    echo "  - statuspage (direct, via cron sqlite3)"
    echo "  - uptime-kuma (file copy)"
    log ""
    log "Backups on NAS:"
    if ls "$BACKUP_DIR"/backup-*.tar.gz 1>/dev/null 2>&1; then
        ls -lh "$BACKUP_DIR"/backup-*.tar.gz | awk '{print "  " $NF " (" $5 ")"}'
        stale=$(find "$BACKUP_DIR" -name "backup-*.tar.gz" -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null | wc -l)
        log "Would delete $stale backup(s) older than $BACKUP_RETENTION_DAYS days"
    else
        log "  (none)"
    fi
    exit 0
fi

# --- Create staging directory ---

mkdir -p "$STAGING"
MANIFEST="$STAGING/manifest.txt"
echo "Backup: $TIMESTAMP" > "$MANIFEST"
echo "Host: $(hostname)" >> "$MANIFEST"
echo "" >> "$MANIFEST"

log "Starting backup to $BACKUP_DIR/backup-$TIMESTAMP.tar.gz"

# --- SQLite safe snapshots ---

log "Creating SQLite safe snapshots..."

# Services with sqlite3 available in their container
SQLITE_SERVICES="sonarr:sonarr.db radarr:radarr.db prowlarr:prowlarr.db tautulli:tautulli.db sonarr-guest:sonarr.db radarr-guest:radarr.db"

for entry in $SQLITE_SERVICES; do
    svc="${entry%%:*}"
    db="${entry##*:}"
    backup_name="${svc}.db.backup"

    if docker exec "$svc" sqlite3 "/config/$db" ".backup '/config/${db}.backup'" 2>/dev/null; then
        # Copy the backup file from the config mount
        if cp "/config/all-configs/${svc}/${db}.backup" "$STAGING/$backup_name" 2>/dev/null; then
            log "  $svc: sqlite3 .backup OK"
            echo "sqlite_backup: $svc OK" >> "$MANIFEST"
            # Clean up .backup file from config dir
            rm -f "/config/all-configs/${svc}/${db}.backup" 2>/dev/null || true
        else
            warn "$svc: .backup file not found in config mount, falling back to file copy"
            cp "/config/all-configs/${svc}/${db}" "$STAGING/$backup_name" 2>/dev/null || warn "$svc: file copy also failed"
            echo "sqlite_backup: $svc FALLBACK (file copy)" >> "$MANIFEST"
        fi
    else
        warn "$svc: docker exec sqlite3 failed (container down?), falling back to file copy"
        if cp "/config/all-configs/${svc}/${db}" "$STAGING/$backup_name" 2>/dev/null; then
            echo "sqlite_backup: $svc FALLBACK (file copy)" >> "$MANIFEST"
        else
            warn "$svc: file copy also failed — skipping"
            echo "sqlite_backup: $svc SKIPPED" >> "$MANIFEST"
        fi
    fi
done

# Statuspage — cron container has direct mount + sqlite3
if [ -f "/config/statuspage/statuspage.db" ]; then
    if sqlite3 /config/statuspage/statuspage.db ".backup '$STAGING/statuspage.db.backup'" 2>/dev/null; then
        log "  statuspage: sqlite3 .backup OK"
        echo "sqlite_backup: statuspage OK" >> "$MANIFEST"
    else
        warn "statuspage: sqlite3 .backup failed, falling back to file copy"
        cp /config/statuspage/statuspage.db "$STAGING/statuspage.db.backup"
        echo "sqlite_backup: statuspage FALLBACK (file copy)" >> "$MANIFEST"
    fi
else
    warn "statuspage: database not found"
    echo "sqlite_backup: statuspage SKIPPED" >> "$MANIFEST"
fi

# Uptime Kuma — no sqlite3 CLI in Node.js image, direct file copy
if [ -f "/config/all-configs/uptime-kuma/kuma.db" ]; then
    cp "/config/all-configs/uptime-kuma/kuma.db" "$STAGING/uptime-kuma.db.backup"
    log "  uptime-kuma: file copy OK"
    echo "sqlite_backup: uptime-kuma OK (file copy)" >> "$MANIFEST"
else
    warn "uptime-kuma: database not found"
    echo "sqlite_backup: uptime-kuma SKIPPED" >> "$MANIFEST"
fi

# --- Tar config directories ---

log "Archiving config directories..."

tar -cf "$STAGING/configs.tar" \
    -C /config/all-configs \
    --exclude='plex/Library/Application Support/Plex Media Server/Cache' \
    --exclude='plex/Library/Application Support/Plex Media Server/Metadata' \
    --exclude='plex/Library/Application Support/Plex Media Server/Media' \
    --exclude='plex/Library/Application Support/Plex Media Server/Crash Reports' \
    --exclude='plex/Library/Application Support/Plex Media Server/Logs' \
    --exclude='*.db.backup' \
    . 2>/dev/null || warn "tar had warnings (possibly missing dirs)"

log "  configs.tar: $(du -sh "$STAGING/configs.tar" | cut -f1)"

# --- Copy .env ---

cp /config/.env "$STAGING/.env"
log "  .env: copied"
echo "" >> "$MANIFEST"
echo "env_file: included" >> "$MANIFEST"

# --- List backed up directories ---

echo "" >> "$MANIFEST"
echo "Config directories:" >> "$MANIFEST"
ls -1d /config/all-configs/*/ 2>/dev/null | sed 's|/config/all-configs/||;s|/$||' | while read -r dir; do
    echo "  $dir" >> "$MANIFEST"
done

echo "" >> "$MANIFEST"
echo "Warnings: $WARNINGS" >> "$MANIFEST"

# --- Compress ---

log "Compressing..."
tar -czf "$BACKUP_DIR/backup-$TIMESTAMP.tar.gz" -C "$STAGING" .
BACKUP_SIZE="$(du -sh "$BACKUP_DIR/backup-$TIMESTAMP.tar.gz" | cut -f1)"
log "  backup-$TIMESTAMP.tar.gz: $BACKUP_SIZE"

# --- Cleanup staging ---

rm -rf "$STAGING"

# --- Rotation ---

deleted=0
while IFS= read -r old_backup; do
    rm -f "$old_backup"
    deleted=$((deleted + 1))
done < <(find "$BACKUP_DIR" -name "backup-*.tar.gz" -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null)

remaining=$(ls "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | wc -l)
total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

log "Rotation: deleted $deleted old backup(s), $remaining remaining ($total_size total)"
log "Backup complete ($WARNINGS warning(s))"
