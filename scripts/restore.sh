#!/bin/bash
# restore.sh - Restore service configs from a NAS backup
#
# Designed to run on the HOST (not inside a container), since during a
# disaster recovery the containers are likely down.
#
# Usage:
#   ./scripts/restore.sh --list              List available backups
#   ./scripts/restore.sh                     Restore latest backup
#   ./scripts/restore.sh backup-XXX.tar.gz   Restore specific backup
#   ./scripts/restore.sh --dry-run           Show what would be restored
#   ./scripts/restore.sh --force             Overwrite existing .env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=false
FORCE=false
TARGET_BACKUP=""

for arg in "$@"; do
    case "$arg" in
        --list) LIST_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        --force) FORCE=true ;;
        --help|-h) HELP=true ;;
        backup-*) TARGET_BACKUP="$arg" ;;
    esac
done

if [ "${HELP:-false}" = true ]; then
    echo "Usage: $0 [OPTIONS] [backup-YYYYMMDD-HHMMSS.tar.gz]"
    echo ""
    echo "Options:"
    echo "  --list      List available backups"
    echo "  --dry-run   Show what would be restored without making changes"
    echo "  --force     Overwrite existing .env file"
    echo "  --help      Show this help"
    echo ""
    echo "If no backup file is specified, restores the latest backup."
    exit 0
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# --- Find backup directory ---

# Try loading .env for BACKUP_DIR/MEDIA_ROOT
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

BACKUP_DIR="${BACKUP_DIR:-${MEDIA_ROOT:-/mnt/mediaserver}/backups}"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Backup directory not found: $BACKUP_DIR" >&2
    echo "Make sure the NAS is mounted at ${MEDIA_ROOT:-/mnt/mediaserver}" >&2
    exit 1
fi

# --- List mode ---

if [ "${LIST_MODE:-false}" = true ]; then
    echo "Available backups in $BACKUP_DIR:"
    echo ""
    if ls "$BACKUP_DIR"/backup-*.tar.gz 1>/dev/null 2>&1; then
        ls -lht "$BACKUP_DIR"/backup-*.tar.gz | awk '{printf "  %-40s %s\n", $NF, $5}'
        echo ""
        total=$(ls "$BACKUP_DIR"/backup-*.tar.gz | wc -l)
        total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        echo "$total backup(s), $total_size total"
    else
        echo "  (none)"
    fi
    exit 0
fi

# --- Select backup ---

if [ -n "$TARGET_BACKUP" ]; then
    BACKUP_FILE="$BACKUP_DIR/$TARGET_BACKUP"
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "ERROR: Backup not found: $BACKUP_FILE" >&2
        echo "Run '$0 --list' to see available backups" >&2
        exit 1
    fi
else
    BACKUP_FILE="$(ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -1)"
    if [ -z "$BACKUP_FILE" ]; then
        echo "ERROR: No backups found in $BACKUP_DIR" >&2
        exit 1
    fi
fi

BACKUP_NAME="$(basename "$BACKUP_FILE")"
BACKUP_SIZE="$(du -sh "$BACKUP_FILE" | cut -f1)"

log "Selected backup: $BACKUP_NAME ($BACKUP_SIZE)"

# --- Dry run ---

if [ "$DRY_RUN" = true ]; then
    log "DRY RUN — no changes will be made"
    echo ""
    log "Would restore from: $BACKUP_FILE"
    log "Project directory: $PROJECT_DIR"
    echo ""
    log "Archive contents:"
    tar -tzf "$BACKUP_FILE" | head -50
    echo ""

    # Check manifest
    STAGING="/tmp/restore-preview-$$"
    mkdir -p "$STAGING"
    tar -xzf "$BACKUP_FILE" -C "$STAGING" manifest.txt 2>/dev/null || true
    if [ -f "$STAGING/manifest.txt" ]; then
        log "Manifest:"
        cat "$STAGING/manifest.txt"
    fi
    rm -rf "$STAGING"

    echo ""
    if [ -f "$PROJECT_DIR/.env" ] && [ "$FORCE" != true ]; then
        log ".env exists — would NOT overwrite (use --force to overwrite)"
    else
        log ".env would be restored"
    fi
    log "Would stop all containers, extract configs, restore SQLite backups, start containers"
    exit 0
fi

# --- Confirmation ---

echo ""
echo "This will:"
echo "  1. Stop all containers (docker compose down)"
echo "  2. Replace ./config/ with backup contents"
echo "  3. Restore SQLite database backups"
if [ ! -f "$PROJECT_DIR/.env" ] || [ "$FORCE" = true ]; then
    echo "  4. Restore .env file"
fi
echo "  5. Start all containers"
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log "Aborted"
    exit 0
fi

# --- Stop containers ---

log "Stopping containers..."
cd "$PROJECT_DIR"
docker compose down 2>/dev/null || log "docker compose down failed (containers may already be stopped)"

# --- Extract backup ---

STAGING="/tmp/restore-$$"
mkdir -p "$STAGING"

log "Extracting backup..."
tar -xzf "$BACKUP_FILE" -C "$STAGING"

# Show manifest if present
if [ -f "$STAGING/manifest.txt" ]; then
    log "Backup manifest:"
    cat "$STAGING/manifest.txt" | sed 's/^/  /'
    echo ""
fi

# --- Restore configs ---

log "Restoring config directories..."
mkdir -p "$PROJECT_DIR/config"
tar -xf "$STAGING/configs.tar" -C "$PROJECT_DIR/config"

# --- Restore .env ---

if [ ! -f "$PROJECT_DIR/.env" ] || [ "$FORCE" = true ]; then
    if [ -f "$STAGING/.env" ]; then
        cp "$STAGING/.env" "$PROJECT_DIR/.env"
        log "Restored .env"
    fi
else
    log "Skipping .env (already exists, use --force to overwrite)"
fi

# --- Restore SQLite backups ---

log "Restoring SQLite databases..."

# Mapping: backup_file -> config_path/db_name
restore_db() {
    local backup_file="$1"
    local target="$2"
    local name="$3"

    if [ -f "$STAGING/$backup_file" ]; then
        target_dir="$(dirname "$PROJECT_DIR/config/$target")"
        mkdir -p "$target_dir"
        cp "$STAGING/$backup_file" "$PROJECT_DIR/config/$target"
        log "  $name: restored"
    fi
}

restore_db "sonarr.db.backup"       "sonarr/sonarr.db"           "sonarr"
restore_db "radarr.db.backup"       "radarr/radarr.db"           "radarr"
restore_db "prowlarr.db.backup"     "prowlarr/prowlarr.db"       "prowlarr"
restore_db "tautulli.db.backup"     "tautulli/tautulli.db"       "tautulli"
restore_db "sonarr-guest.db.backup" "sonarr-guest/sonarr.db"     "sonarr-guest"
restore_db "radarr-guest.db.backup" "radarr-guest/radarr.db"     "radarr-guest"
restore_db "uptime-kuma.db.backup"  "uptime-kuma/kuma.db"        "uptime-kuma"
restore_db "statuspage.db.backup"   "statuspage/statuspage.db"   "statuspage"

# --- Restore SSH deploy keys ---

if [ -d "$STAGING/ssh-keys" ]; then
    mkdir -p "$PROJECT_DIR/.ssh"
    cp "$STAGING/ssh-keys/"* "$PROJECT_DIR/.ssh/"
    chmod 700 "$PROJECT_DIR/.ssh"
    chmod 600 "$PROJECT_DIR/.ssh/id_deploy_"* 2>/dev/null
    log "Restored SSH deploy keys"
fi

# --- Clean up WAL/SHM journals ---

log "Cleaning stale SQLite journals..."
find "$PROJECT_DIR/config" -name "*.db-wal" -delete 2>/dev/null || true
find "$PROJECT_DIR/config" -name "*.db-shm" -delete 2>/dev/null || true

# --- Cleanup staging ---

rm -rf "$STAGING"

# --- Start containers ---

log "Starting containers..."
cd "$PROJECT_DIR"
docker compose up -d

log "Restore complete from $BACKUP_NAME"
log "Check service health: docker compose ps"
