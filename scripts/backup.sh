#!/bin/bash
# backup.sh - Daily backup of all service configs and .env to NAS
#
# Creates a compressed tarball containing:
# - All service config directories
# - SQLite database safe snapshots (via sqlite3 .backup on mounted configs)
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
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
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
    log "SQLite snapshots (via mounted configs):"
    for svc in sonarr radarr prowlarr jellyfin; do
        echo "  - $svc"
    done
    echo "  - statuspage (direct, via cron sqlite3)"
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

# Use sqlite3 directly on mounted config files (no docker exec needed)
SQLITE_SERVICES="sonarr:sonarr.db radarr:radarr.db prowlarr:prowlarr.db"

for entry in $SQLITE_SERVICES; do
    svc="${entry%%:*}"
    db="${entry##*:}"
    backup_name="${svc}.db.backup"
    db_path="/config/all-configs/${svc}/${db}"

    if [ -f "$db_path" ]; then
        if sqlite3 "$db_path" ".backup '$STAGING/$backup_name'" 2>/dev/null; then
            log "  $svc: sqlite3 .backup OK"
            echo "sqlite_backup: $svc OK" >> "$MANIFEST"
        else
            warn "$svc: sqlite3 .backup failed, falling back to file copy"
            cp "$db_path" "$STAGING/$backup_name" 2>/dev/null || warn "$svc: file copy also failed"
            echo "sqlite_backup: $svc FALLBACK (file copy)" >> "$MANIFEST"
        fi
    else
        warn "$svc: database not found at $db_path"
        echo "sqlite_backup: $svc SKIPPED" >> "$MANIFEST"
    fi
done

# Jellyfin — DB is at a different path inside linuxserver image
JELLYFIN_DB="/config/all-configs/jellyfin/data/data/jellyfin.db"
if [ -f "$JELLYFIN_DB" ]; then
    if sqlite3 "$JELLYFIN_DB" ".backup '$STAGING/jellyfin.db.backup'" 2>/dev/null; then
        log "  jellyfin: sqlite3 .backup OK"
        echo "sqlite_backup: jellyfin OK" >> "$MANIFEST"
    else
        warn "jellyfin: sqlite3 .backup failed, falling back to file copy"
        cp "$JELLYFIN_DB" "$STAGING/jellyfin.db.backup"
        echo "sqlite_backup: jellyfin FALLBACK (file copy)" >> "$MANIFEST"
    fi
else
    warn "jellyfin: database not found"
    echo "sqlite_backup: jellyfin SKIPPED" >> "$MANIFEST"
fi

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

# --- Tar config directories ---

log "Archiving config directories..."

tar -cf "$STAGING/configs.tar" \
    -C /config/all-configs \
    --exclude='jellyfin/data/transcodes' \
    --exclude='jellyfin/cache' \
    --exclude='*.db.backup' \
    . 2>/dev/null || warn "tar had warnings (possibly missing dirs)"

log "  configs.tar: $(du -sh "$STAGING/configs.tar" | cut -f1)"

# --- Copy .env ---

cp /config/.env "$STAGING/.env"
log "  .env: copied"
echo "" >> "$MANIFEST"
echo "env_file: included" >> "$MANIFEST"

# --- Copy SSH deploy keys ---

if [ -d "/config/ssh-keys" ]; then
    mkdir -p "$STAGING/ssh-keys"
    cp /config/ssh-keys/id_deploy_* "$STAGING/ssh-keys/" 2>/dev/null && \
        log "  ssh-keys: copied" || warn "ssh-keys: no deploy keys found"
    echo "ssh_keys: included" >> "$MANIFEST"
fi

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
BACKUP_FILE="$BACKUP_DIR/backup-$TIMESTAMP.tar.gz"
tar -czf "$BACKUP_FILE" -C "$STAGING" .

# Encrypt if key is configured (backup contains .env, API keys, SMTP credentials, SSH keys)
if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 -in "$BACKUP_FILE" -out "${BACKUP_FILE}.enc" -pass "pass:$BACKUP_ENCRYPTION_KEY"
    rm -f "$BACKUP_FILE"
    BACKUP_FILE="${BACKUP_FILE}.enc"
    log "  Encrypted with AES-256-CBC"
fi

BACKUP_SIZE="$(du -sh "$BACKUP_FILE" | cut -f1)"
log "  $(basename "$BACKUP_FILE"): $BACKUP_SIZE"

# --- Cleanup staging ---

rm -rf "$STAGING"

# --- Rotation ---

deleted=0
while IFS= read -r old_backup; do
    rm -f "$old_backup"
    deleted=$((deleted + 1))
done < <(find "$BACKUP_DIR" -name "backup-*.tar.gz*" -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null)

remaining=$(ls "$BACKUP_DIR"/backup-*.tar.gz* 2>/dev/null | wc -l)
total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

log "Rotation: deleted $deleted old backup(s), $remaining remaining ($total_size total)"
log "Backup complete ($WARNINGS warning(s))"
