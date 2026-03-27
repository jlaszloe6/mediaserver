#!/bin/bash
# reboot-test.sh - Verify stack health after reboot/shutdown/start
#
# Checks that all services came back up correctly:
# - NFS mount is accessible
# - All containers are running
# - Each service responds to health checks (via Docker healthcheck status)
# - SQLite databases are accessible
# - Cron is scheduling jobs
#
# Run on the HOST after a reboot:
#   ./scripts/reboot-test.sh
#   ./scripts/reboot-test.sh --wait 90   (wait 90s for services to start, default 60)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WAIT_SECS=60
PASSED=0
FAILED=0
WARNED=0

for arg in "$@"; do
    case "$arg" in
        --wait)  shift; WAIT_SECS="${1:-60}" ;;
        [0-9]*) WAIT_SECS="$arg" ;;
    esac
done

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
    echo -e "  ${GREEN}PASS${NC}  $*"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC}  $*"
    FAILED=$((FAILED + 1))
}

warn_check() {
    echo -e "  ${YELLOW}WARN${NC}  $*"
    WARNED=$((WARNED + 1))
}

# Load .env
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
else
    echo "WARNING: .env not found at $PROJECT_DIR/.env"
fi

MEDIA_ROOT="${MEDIA_ROOT:-/mnt/mediaserver}"
SERVER_IP="${SERVER_IP:-127.0.0.1}"

echo "=== Reboot Health Check ==="
echo "Waiting ${WAIT_SECS}s for services to start..."
sleep "$WAIT_SECS"
echo ""

# --- 1. NFS mount ---

echo "[NFS Mount]"
if mountpoint -q "$MEDIA_ROOT" 2>/dev/null; then
    pass "NFS mounted at $MEDIA_ROOT"
    if ls "$MEDIA_ROOT/media" >/dev/null 2>&1; then
        pass "NFS is readable"
    else
        fail "NFS mounted but not readable"
    fi
else
    fail "NFS not mounted at $MEDIA_ROOT"
fi
echo ""

# --- 2. Docker ---

echo "[Docker]"
if docker info >/dev/null 2>&1; then
    pass "Docker daemon is running"
else
    fail "Docker daemon is not running"
    echo ""
    echo "Cannot continue without Docker. Exiting."
    exit 1
fi
echo ""

# --- 3. Container status ---

echo "[Containers]"
EXPECTED_CONTAINERS="jellyfin transmission sonarr radarr prowlarr seerr caddy duckdns statuspage cron"

for container in $EXPECTED_CONTAINERS; do
    status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
    if [ "$status" = "running" ]; then
        pass "$container"
    else
        fail "$container ($status)"
    fi
done
echo ""

# --- 4. Service health checks (via Docker healthcheck status) ---

echo "[Service Health]"

check_docker_health() {
    local name="$1"
    local container="$2"
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "no healthcheck")
    if [ "$health" = "healthy" ]; then
        pass "$name ($container)"
    elif [ "$health" = "no healthcheck" ]; then
        # Container has no healthcheck defined — check if running
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
        if [ "$status" = "running" ]; then
            warn_check "$name ($container) — running but no healthcheck defined"
        else
            fail "$name ($container) — $status"
        fi
    else
        fail "$name ($container) — $health"
    fi
}

check_docker_health "Jellyfin"     "jellyfin"
check_docker_health "Sonarr"       "sonarr"
check_docker_health "Radarr"       "radarr"
check_docker_health "Prowlarr"     "prowlarr"
check_docker_health "Transmission" "transmission"
check_docker_health "Seerr"        "seerr"
check_docker_health "Caddy"        "caddy"

check_docker_health "Status Page" "statuspage"
echo ""

# --- 5. DNS ---

echo "[DNS]"
if nslookup "${CADDY_DOMAIN_STATUS:-status.example.com}" >/dev/null 2>&1; then
    pass "DuckDNS domain resolving"
else
    warn_check "DuckDNS domain not resolving"
fi
echo ""

# --- 6. SQLite databases ---

echo "[SQLite Databases]"

check_sqlite() {
    local name="$1"
    local container="$2"
    local db_path="$3"
    if docker exec "$container" sqlite3 "$db_path" "SELECT 1;" >/dev/null 2>&1; then
        pass "$name"
    else
        # Fallback: container may not have sqlite3
        if docker exec "$container" test -f "$db_path" 2>/dev/null; then
            warn_check "$name (file exists, sqlite3 not available to verify)"
        else
            fail "$name (database file missing)"
        fi
    fi
}

check_sqlite "Sonarr"   "sonarr"   "/config/sonarr.db"
check_sqlite "Radarr"   "radarr"   "/config/radarr.db"
check_sqlite "Prowlarr" "prowlarr" "/config/prowlarr.db"

# Jellyfin SQLite — check from host
if [ -f "$PROJECT_DIR/config/jellyfin/data/data/jellyfin.db" ]; then
    if sqlite3 "$PROJECT_DIR/config/jellyfin/data/data/jellyfin.db" "SELECT 1;" >/dev/null 2>&1; then
        pass "Jellyfin"
    else
        fail "Jellyfin (database corrupt)"
    fi
else
    fail "Jellyfin (database missing)"
fi

# Statuspage — check from host
if [ -f "$PROJECT_DIR/config/statuspage/statuspage.db" ]; then
    if sqlite3 "$PROJECT_DIR/config/statuspage/statuspage.db" "SELECT 1;" >/dev/null 2>&1; then
        pass "Status Page"
    else
        fail "Status Page (database corrupt)"
    fi
else
    fail "Status Page (database missing)"
fi
echo ""

# --- 7. Cron ---

echo "[Cron Jobs]"
if docker exec cron crontab -l >/dev/null 2>&1; then
    job_count=$(docker exec cron crontab -l 2>/dev/null | grep -c '^[^#]' || echo 0)
    if [ "$job_count" -gt 0 ]; then
        pass "Cron has $job_count scheduled job(s)"
    else
        fail "Cron has no scheduled jobs"
    fi
else
    fail "Cannot read cron jobs"
fi
echo ""

# --- 8. Caddy TLS ---

echo "[Caddy TLS]"
if [ -n "${CADDY_DOMAIN_JELLYFIN:-}" ]; then
    cert_check=$(echo | openssl s_client -connect "$SERVER_IP:443" -servername "$CADDY_DOMAIN_JELLYFIN" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "")
    if [ -n "$cert_check" ]; then
        expiry=$(echo "$cert_check" | grep notAfter | cut -d= -f2)
        pass "TLS cert valid (expires: $expiry)"
    else
        warn_check "Could not verify TLS cert (Caddy may still be obtaining it)"
    fi
else
    warn_check "CADDY_DOMAIN_JELLYFIN not set, skipping TLS check"
fi
echo ""

# --- 9. Backups ---

echo "[Backups]"
BACKUP_DIR="${BACKUP_DIR:-${MEDIA_ROOT}/backups}"
if [ -d "$BACKUP_DIR" ]; then
    backup_count=$(ls "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | wc -l)
    if [ "$backup_count" -gt 0 ]; then
        latest=$(ls -t "$BACKUP_DIR"/backup-*.tar.gz | head -1)
        latest_name=$(basename "$latest")
        pass "$backup_count backup(s) on NAS (latest: $latest_name)"
    else
        warn_check "Backup directory exists but no backups found"
    fi
else
    warn_check "Backup directory not found ($BACKUP_DIR)"
fi
echo ""

# --- Summary ---

echo "=== Summary ==="
TOTAL=$((PASSED + FAILED + WARNED))
echo -e "  ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}, ${YELLOW}$WARNED warnings${NC} (out of $TOTAL checks)"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo "Some checks failed. Review the output above."
    exit 1
else
    echo "All critical checks passed."
    exit 0
fi
