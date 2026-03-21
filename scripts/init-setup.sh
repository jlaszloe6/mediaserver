#!/bin/bash
# init-setup.sh - Automated initial configuration of the media server stack
#
# Configures Prowlarr, Sonarr, Radarr, Transmission, and Tautulli via their
# APIs after first boot. Reads/writes credentials in .env.
#
# Prerequisites:
#   - docker compose up -d (all containers running)
#   - Plex signed in and libraries created via browser
#   - PLEX_TOKEN set in .env
#
# Usage: ./scripts/init-setup.sh [--trakt] [--guest] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
CONFIG_DIR="$PROJECT_DIR/config"

ERRORS=0
DRY_RUN=false
DO_TRAKT=false
DO_GUEST=false

# Load all .env variables into the environment
if [ ! -f "$ENV_FILE" ]; then
    echo -e '\033[0;31m[ERR ]\033[0m .env file not found. Copy .env.example and fill in values.'
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

# --- Helpers ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERR ]${NC} $*"; ERRORS=$((ERRORS + 1)); }

env_set() {
    local key="$1" value="$2"
    if grep -q "^$key=" "$ENV_FILE" 2>/dev/null; then
        # Use awk to avoid sed delimiter issues with special characters
        awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{$2=v}1' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

read_xml_key() {
    local file="$1" key="$2"
    grep -oP "(?<=<$key>)[^<]+" "$file" 2>/dev/null
}

wait_for_service() {
    local name="$1" url="$2" api_key="${3:-}"
    local max_attempts=30 attempt=0
    local headers=()
    [ -n "$api_key" ] && headers=(-H "X-Api-Key: $api_key")

    log_info "Waiting for $name..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -sf -o /dev/null --max-time 3 "${headers[@]}" "$url" 2>/dev/null; then
            log_ok "$name is ready"
            return 0
        fi
        # Transmission returns 409 with session ID — that's fine
        if [ "$name" = "Transmission" ]; then
            local code
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null)
            if [ "$code" = "409" ]; then
                log_ok "$name is ready"
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    log_err "$name did not become ready after $((max_attempts * 2))s"
    return 1
}

api_call() {
    local method="$1" url="$2" api_key="$3" data="${4:-}"
    local args=(-s -w '\n%{http_code}' -X "$method" -H "X-Api-Key: $api_key" -H "Content-Type: application/json")
    [ -n "$data" ] && args+=(-d "$data")
    curl "${args[@]}" "$url"
}

parse_response() {
    local result="$1"
    RESP_CODE=$(echo "$result" | tail -1)
    RESP_BODY=$(echo "$result" | sed '$d')
}

# --- Parse arguments ---

for arg in "$@"; do
    case "$arg" in
        --trakt)   DO_TRAKT=true ;;
        --guest)   DO_GUEST=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Usage: init-setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --trakt     Run interactive Trakt OAuth device-code flow"
            echo "  --guest     Configure guest Sonarr/Radarr instances"
            echo "  --dry-run   Show what would be configured without making changes"
            echo "  -h, --help  Show this help message"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# --- Sanity checks ---

echo ""
echo "=== Media Server Init Setup ==="
echo ""

# --- Section 1: Read API keys from config.xml files ---

log_info "Reading API keys from service configs..."

get_api_key() {
    local service="$1"
    local config_path="$CONFIG_DIR/$service/config.xml"
    local env_var="${2:-}"
    local key
    if [ ! -f "$config_path" ]; then
        log_err "$service config.xml not found at $config_path — is the container running?"
        return 1
    fi
    key=$(read_xml_key "$config_path" "ApiKey")
    if [ -z "$key" ]; then
        log_err "Could not read ApiKey from $config_path"
        return 1
    fi
    echo "$key"
    # Write to .env if env_var specified
    if [ -n "$env_var" ]; then
        env_set "$env_var" "$key"
    fi
}

PROWLARR_KEY=$(get_api_key "prowlarr" "PROWLARR_API_KEY") || true
SONARR_KEY=$(get_api_key "sonarr" "SONARR_API_KEY") || true
RADARR_KEY=$(get_api_key "radarr" "RADARR_API_KEY") || true

# Tautulli uses a different config format
TAUTULLI_KEY="${TAUTULLI_API_KEY:-}"
if [ -z "$TAUTULLI_KEY" ] && [ -f "$CONFIG_DIR/tautulli/config.ini" ]; then
    TAUTULLI_KEY=$(grep -m1 '^api_key' "$CONFIG_DIR/tautulli/config.ini" | cut -d= -f2- | tr -d ' ')
    [ -n "$TAUTULLI_KEY" ] && env_set "TAUTULLI_API_KEY" "$TAUTULLI_KEY"
fi

PLEX_TOKEN="${PLEX_TOKEN:-}"

if [ -z "$PROWLARR_KEY" ] || [ -z "$SONARR_KEY" ] || [ -z "$RADARR_KEY" ]; then
    log_err "Missing API keys. Ensure all services have started at least once."
    exit 1
fi

log_ok "API keys loaded (Prowlarr, Sonarr, Radarr)"

# When --guest is passed without --trakt, skip owner sections 2-8
if ! $DO_GUEST; then

# --- Section 2: Wait for services ---

echo ""
wait_for_service "Prowlarr"     "http://localhost:9696/api/v1/health"     "$PROWLARR_KEY"
wait_for_service "Sonarr"       "http://localhost:8989/api/v3/health"     "$SONARR_KEY"
wait_for_service "Radarr"       "http://localhost:7878/api/v3/health"     "$RADARR_KEY"
wait_for_service "Transmission" "http://localhost:9091/transmission/rpc"

# --- Section 3: Configure Prowlarr ---

echo ""
log_info "=== Configuring Prowlarr ==="

# 3a: Create flaresolverr tag
existing_tags=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:9696/api/v1/tag")
FLARESOLVERR_TAG_ID=$(echo "$existing_tags" | jq -r '.[] | select(.label == "flaresolverr") | .id')

if [ -z "$FLARESOLVERR_TAG_ID" ]; then
    if $DRY_RUN; then
        log_info "[DRY RUN] Would create tag 'flaresolverr'"
        FLARESOLVERR_TAG_ID=1
    else
        parse_response "$(api_call POST "http://localhost:9696/api/v1/tag" "$PROWLARR_KEY" '{"label":"flaresolverr"}')"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            FLARESOLVERR_TAG_ID=$(echo "$RESP_BODY" | jq -r '.id')
            log_ok "Created tag 'flaresolverr' (id=$FLARESOLVERR_TAG_ID)"
        else
            log_err "Failed to create tag (HTTP $RESP_CODE)"
            FLARESOLVERR_TAG_ID=""
        fi
    fi
else
    log_ok "Tag 'flaresolverr' already exists (id=$FLARESOLVERR_TAG_ID)"
fi

# 3b: Add FlareSolverr indexer proxy
existing_proxies=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:9696/api/v1/indexerproxy")
has_flaresolverr_proxy=$(echo "$existing_proxies" | jq -r '.[] | select(.name == "FlareSolverr") | .id')

if [ -z "$has_flaresolverr_proxy" ]; then
    proxy_payload=$(cat <<PEOF
{
  "name": "FlareSolverr",
  "implementation": "FlareSolverr",
  "configContract": "FlareSolverrSettings",
  "fields": [
    {"name": "host", "value": "http://flaresolverr:8191/"},
    {"name": "requestTimeout", "value": 60}
  ],
  "tags": [${FLARESOLVERR_TAG_ID:-}]
}
PEOF
)
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add FlareSolverr indexer proxy"
    else
        parse_response "$(api_call POST "http://localhost:9696/api/v1/indexerproxy" "$PROWLARR_KEY" "$proxy_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added FlareSolverr indexer proxy"
        else
            log_err "Failed to add FlareSolverr proxy (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "FlareSolverr proxy already configured"
fi

# 3c: Add indexers
existing_indexers=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:9696/api/v1/indexer")

add_indexer() {
    local def_name="$1" base_url="$2" tags="$3" extra_fields="${4:-}"

    # Check if already exists
    local exists
    exists=$(echo "$existing_indexers" | jq -r ".[] | select(.definitionName == \"$def_name\") | .id")
    if [ -n "$exists" ]; then
        log_ok "Indexer '$def_name' already configured"
        return 0
    fi

    local fields
    fields=$(cat <<FEOF
[
    {"name": "definitionFile", "value": "$def_name"},
    {"name": "baseUrl", "value": "$base_url"},
    {"name": "torrentBaseSettings.preferMagnetUrl", "value": true}
    $extra_fields
]
FEOF
)

    local payload
    payload=$(cat <<IEOF
{
  "name": "$def_name",
  "definitionName": "$def_name",
  "enable": true,
  "redirect": false,
  "priority": 25,
  "appProfileId": 1,
  "implementation": "Cardigann",
  "configContract": "CardigannSettings",
  "tags": $tags,
  "fields": $fields
}
IEOF
)

    if $DRY_RUN; then
        log_info "[DRY RUN] Would add indexer '$def_name'"
        return 0
    fi

    parse_response "$(api_call POST "http://localhost:9696/api/v1/indexer" "$PROWLARR_KEY" "$payload")"
    if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
        log_ok "Added indexer '$def_name'"
    else
        log_err "Failed to add indexer '$def_name' (HTTP $RESP_CODE): $RESP_BODY"
    fi
}

FS_TAGS="[${FLARESOLVERR_TAG_ID:-}]"
NO_TAGS="[]"

add_indexer "1337x"         "https://1337x.to/"              "$FS_TAGS"
add_indexer "eztv"          "https://eztvx.to/"              "$NO_TAGS"
add_indexer "yts"           "https://yts.mx/"                "$NO_TAGS"
add_indexer "thepiratebay"  "https://thepiratebay.org/"      "$NO_TAGS"
add_indexer "limetorrents"  "https://www.limetorrents.lol/"  "$NO_TAGS"

# Knaben uses a different implementation
knaben_exists=$(echo "$existing_indexers" | jq -r '.[] | select(.definitionName == "Knaben") | .id')
if [ -z "$knaben_exists" ]; then
    knaben_payload=$(cat <<KEOF
{
  "name": "Knaben",
  "definitionName": "Knaben",
  "enable": true,
  "redirect": false,
  "priority": 25,
  "appProfileId": 1,
  "implementation": "Knaben",
  "configContract": "NoAuthTorrentBaseSettings",
  "tags": [],
  "fields": [
    {"name": "baseUrl", "value": "https://knaben.eu/"},
    {"name": "torrentBaseSettings.preferMagnetUrl", "value": true}
  ]
}
KEOF
)
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add indexer 'Knaben'"
    else
        parse_response "$(api_call POST "http://localhost:9696/api/v1/indexer" "$PROWLARR_KEY" "$knaben_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added indexer 'Knaben'"
        else
            log_err "Failed to add indexer 'Knaben' (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Indexer 'Knaben' already configured"
fi

# 3d: Add Sonarr as application
existing_apps=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:9696/api/v1/applications")
sonarr_app_exists=$(echo "$existing_apps" | jq -r '.[] | select(.name == "Sonarr") | .id')

if [ -z "$sonarr_app_exists" ]; then
    sonarr_app_payload=$(cat <<SEOF
{
  "syncLevel": "fullSync",
  "name": "Sonarr",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
    {"name": "baseUrl", "value": "http://sonarr:8989"},
    {"name": "apiKey", "value": "$SONARR_KEY"},
    {"name": "syncCategories", "value": [5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]},
    {"name": "animeSyncCategories", "value": [5070]}
  ],
  "tags": []
}
SEOF
)
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add Sonarr application"
    else
        parse_response "$(api_call POST "http://localhost:9696/api/v1/applications" "$PROWLARR_KEY" "$sonarr_app_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Sonarr as Prowlarr application"
        else
            log_err "Failed to add Sonarr application (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Sonarr application already configured in Prowlarr"
fi

# 3e: Add Radarr as application
radarr_app_exists=$(echo "$existing_apps" | jq -r '.[] | select(.name == "Radarr") | .id')

if [ -z "$radarr_app_exists" ]; then
    radarr_app_payload=$(cat <<REOF
{
  "syncLevel": "fullSync",
  "name": "Radarr",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
    {"name": "baseUrl", "value": "http://radarr:7878"},
    {"name": "apiKey", "value": "$RADARR_KEY"},
    {"name": "syncCategories", "value": [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]}
  ],
  "tags": []
}
REOF
)
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add Radarr application"
    else
        parse_response "$(api_call POST "http://localhost:9696/api/v1/applications" "$PROWLARR_KEY" "$radarr_app_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Radarr as Prowlarr application"
        else
            log_err "Failed to add Radarr application (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Radarr application already configured in Prowlarr"
fi

# 3f: Trigger ApplicationIndexerSync
if ! $DRY_RUN; then
    parse_response "$(api_call POST "http://localhost:9696/api/v1/command" "$PROWLARR_KEY" '{"name":"ApplicationIndexerSync"}')"
    if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
        log_ok "Triggered Prowlarr → Sonarr/Radarr indexer sync"
    else
        log_err "Failed to trigger indexer sync (HTTP $RESP_CODE)"
    fi
fi

# --- Section 4: Configure Sonarr ---

echo ""
log_info "=== Configuring Sonarr ==="

# Root folder
existing_roots=$(curl -sf -H "X-Api-Key: $SONARR_KEY" "http://localhost:8989/api/v3/rootfolder")
sonarr_root_exists=$(echo "$existing_roots" | jq -r '.[] | select(.path == "/data/media/tv") | .id')

if [ -z "$sonarr_root_exists" ]; then
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add Sonarr root folder /data/media/tv"
    else
        parse_response "$(api_call POST "http://localhost:8989/api/v3/rootfolder" "$SONARR_KEY" '{"path":"/data/media/tv"}')"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Sonarr root folder /data/media/tv"
        else
            log_err "Failed to add Sonarr root folder (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Sonarr root folder /data/media/tv already configured"
fi

# Download client
existing_dl=$(curl -sf -H "X-Api-Key: $SONARR_KEY" "http://localhost:8989/api/v3/downloadclient")
sonarr_dl_exists=$(echo "$existing_dl" | jq -r '.[] | select(.name == "Transmission") | .id')

if [ -z "$sonarr_dl_exists" ]; then
    sonarr_dl_payload=$(cat <<SDEOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": false,
  "removeFailedDownloads": false,
  "name": "Transmission",
  "implementation": "Transmission",
  "configContract": "TransmissionSettings",
  "fields": [
    {"name": "host", "value": "transmission"},
    {"name": "port", "value": 9091},
    {"name": "useSsl", "value": false},
    {"name": "urlBase", "value": "/transmission/rpc"},
    {"name": "tvCategory", "value": "tv-sonarr"},
    {"name": "recentTvPriority", "value": 0},
    {"name": "olderTvPriority", "value": 0},
    {"name": "addPaused", "value": false}
  ],
  "tags": []
}
SDEOF
)
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add Transmission download client to Sonarr"
    else
        parse_response "$(api_call POST "http://localhost:8989/api/v3/downloadclient" "$SONARR_KEY" "$sonarr_dl_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Transmission as Sonarr download client"
        else
            log_err "Failed to add Transmission to Sonarr (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Transmission already configured in Sonarr"
fi

# --- Section 5: Configure Radarr ---

echo ""
log_info "=== Configuring Radarr ==="

# Root folder
existing_roots=$(curl -sf -H "X-Api-Key: $RADARR_KEY" "http://localhost:7878/api/v3/rootfolder")
radarr_root_exists=$(echo "$existing_roots" | jq -r '.[] | select(.path == "/data/media/movies") | .id')

if [ -z "$radarr_root_exists" ]; then
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add Radarr root folder /data/media/movies"
    else
        parse_response "$(api_call POST "http://localhost:7878/api/v3/rootfolder" "$RADARR_KEY" '{"path":"/data/media/movies"}')"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Radarr root folder /data/media/movies"
        else
            log_err "Failed to add Radarr root folder (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Radarr root folder /data/media/movies already configured"
fi

# Download client
existing_dl=$(curl -sf -H "X-Api-Key: $RADARR_KEY" "http://localhost:7878/api/v3/downloadclient")
radarr_dl_exists=$(echo "$existing_dl" | jq -r '.[] | select(.name == "Transmission") | .id')

if [ -z "$radarr_dl_exists" ]; then
    radarr_dl_payload=$(cat <<RDEOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": false,
  "removeFailedDownloads": false,
  "name": "Transmission",
  "implementation": "Transmission",
  "configContract": "TransmissionSettings",
  "fields": [
    {"name": "host", "value": "transmission"},
    {"name": "port", "value": 9091},
    {"name": "useSsl", "value": false},
    {"name": "urlBase", "value": "/transmission/rpc"},
    {"name": "movieCategory", "value": "radarr"},
    {"name": "recentMoviePriority", "value": 0},
    {"name": "olderMoviePriority", "value": 0},
    {"name": "addPaused", "value": false}
  ],
  "tags": []
}
RDEOF
)
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add Transmission download client to Radarr"
    else
        parse_response "$(api_call POST "http://localhost:7878/api/v3/downloadclient" "$RADARR_KEY" "$radarr_dl_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Transmission as Radarr download client"
        else
            log_err "Failed to add Transmission to Radarr (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Transmission already configured in Radarr"
fi

# --- Section 6: Configure Transmission seed limits ---

echo ""
log_info "=== Configuring Transmission ==="

if $DRY_RUN; then
    log_info "[DRY RUN] Would set seed ratio=2.0, idle seeding limit=disabled (per-indexer seed times used instead)"
else
    SESSION_ID=$(curl -si http://localhost:9091/transmission/rpc 2>/dev/null | grep -i 'X-Transmission-Session-Id:' | head -1 | awk '{print $2}' | tr -cd 'a-zA-Z0-9')
    if [ -n "$SESSION_ID" ]; then
        result=$(curl -s -w '\n%{http_code}' -X POST http://localhost:9091/transmission/rpc \
            -H "X-Transmission-Session-Id: $SESSION_ID" \
            -H "Content-Type: application/json" \
            -d '{"method":"session-set","arguments":{"seedRatioLimited":true,"seedRatioLimit":2.0,"idle-seeding-limit-enabled":false}}')
        code=$(echo "$result" | tail -1)
        if [ "$code" = "200" ]; then
            log_ok "Set Transmission seed limits (ratio=2.0, idle seeding limit=disabled)"
        else
            log_err "Failed to set Transmission seed limits (HTTP $code)"
        fi
    else
        log_err "Could not get Transmission session ID"
    fi
fi

# --- Section 7: Configure Tautulli ---

echo ""
log_info "=== Configuring Tautulli ==="

if [ -z "$PLEX_TOKEN" ]; then
    log_warn "PLEX_TOKEN not set in .env — skipping Tautulli configuration"
    log_warn "Set PLEX_TOKEN in .env and re-run to configure Tautulli"
else
    TAUTULLI_INI="$CONFIG_DIR/tautulli/config.ini"
    if [ ! -f "$TAUTULLI_INI" ]; then
        log_err "Tautulli config.ini not found — is the container running?"
    else
        current_pms_ip=$(grep -m1 '^pms_ip' "$TAUTULLI_INI" | cut -d= -f2- | tr -d ' ')
        if [ "$current_pms_ip" = "127.0.0.1" ]; then
            log_ok "Tautulli already connected to Plex"
        else
            # Get Plex machine identifier
            PLEX_MACHINE_ID=$(curl -sf -H "X-Plex-Token: $PLEX_TOKEN" "http://localhost:32400/identity" | grep -oP 'machineIdentifier="\K[^"]+')

            if [ -z "$PLEX_MACHINE_ID" ]; then
                log_err "Could not get Plex machine ID — is Plex running and PLEX_TOKEN correct?"
            else
                if $DRY_RUN; then
                    log_info "[DRY RUN] Would configure Tautulli PMS connection"
                else
                    env_set "PLEX_MACHINE_ID" "$PLEX_MACHINE_ID"

                    # Stop Tautulli, edit config, restart
                    docker stop tautulli >/dev/null 2>&1

                    sed -i "s|^pms_ip =.*|pms_ip = 127.0.0.1|" "$TAUTULLI_INI"
                    sed -i "s|^pms_port =.*|pms_port = 32400|" "$TAUTULLI_INI"
                    sed -i "s|^pms_token =.*|pms_token = $PLEX_TOKEN|" "$TAUTULLI_INI"
                    sed -i "s|^pms_identifier =.*|pms_identifier = $PLEX_MACHINE_ID|" "$TAUTULLI_INI"
                    sed -i "s|^pms_url =.*|pms_url = http://127.0.0.1:32400|" "$TAUTULLI_INI"
                    sed -i "s|^pms_ssl =.*|pms_ssl = 0|" "$TAUTULLI_INI"

                    docker start tautulli >/dev/null 2>&1
                    log_ok "Configured Tautulli PMS connection and restarted"
                fi
            fi
        fi
    fi
fi

# --- Section 8: Email notifications ---

echo ""
log_info "=== Configuring Email Notifications ==="

SMTP_SERVER="${SMTP_SERVER:-}"
SMTP_PORT="${SMTP_PORT:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_FROM="${SMTP_FROM:-}"
SMTP_TO="${SMTP_TO:-}"
SEERR_SENDER_NAME="${SEERR_SENDER_NAME:-}"

if [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASSWORD" ] || [ -z "$SMTP_FROM" ]; then
    log_warn "SMTP credentials not set in .env — skipping email notifications"
    log_warn "Set SMTP_USER, SMTP_PASSWORD, and SMTP_FROM in .env and re-run"
else
    SMTP_SERVER="${SMTP_SERVER:-smtp-relay.brevo.com}"
    SMTP_PORT="${SMTP_PORT:-587}"
    SEERR_SENDER_NAME="${SEERR_SENDER_NAME:-Media Server}"

    # Build recipient array for Sonarr/Radarr (JSON array of strings)
    SMTP_TO_JSON=$(echo "$SMTP_TO" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)

    # Sonarr email notification
    existing_notif=$(curl -sf -H "X-Api-Key: $SONARR_KEY" "http://localhost:8989/api/v3/notification")
    sonarr_email_exists=$(echo "$existing_notif" | jq -r '.[] | select(.name == "Email") | .id')

    if [ -z "$sonarr_email_exists" ]; then
        sonarr_email_payload=$(jq -n \
            --arg server "$SMTP_SERVER" \
            --argjson port "$SMTP_PORT" \
            --arg user "$SMTP_USER" \
            --arg pass "$SMTP_PASSWORD" \
            --arg from "Freya Media Server <$SMTP_FROM>" \
            --argjson to "$SMTP_TO_JSON" \
            '{
                name: "Email",
                implementation: "Email",
                configContract: "EmailSettings",
                onGrab: false,
                onImportComplete: true,
                onUpgrade: true,
                onHealthIssue: true,
                fields: [
                    {name: "server", value: $server},
                    {name: "port", value: $port},
                    {name: "useEncryption", value: 0},
                    {name: "username", value: $user},
                    {name: "password", value: $pass},
                    {name: "from", value: $from},
                    {name: "to", value: $to}
                ]
            }')
        if $DRY_RUN; then
            log_info "[DRY RUN] Would add email notification to Sonarr"
        else
            parse_response "$(api_call POST "http://localhost:8989/api/v3/notification" "$SONARR_KEY" "$sonarr_email_payload")"
            if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                log_ok "Added email notification to Sonarr"
            else
                log_err "Failed to add email notification to Sonarr (HTTP $RESP_CODE): $RESP_BODY"
            fi
        fi
    else
        log_ok "Email notification already configured in Sonarr"
    fi

    # Radarr email notification
    existing_notif=$(curl -sf -H "X-Api-Key: $RADARR_KEY" "http://localhost:7878/api/v3/notification")
    radarr_email_exists=$(echo "$existing_notif" | jq -r '.[] | select(.name == "Email") | .id')

    if [ -z "$radarr_email_exists" ]; then
        radarr_email_payload=$(jq -n \
            --arg server "$SMTP_SERVER" \
            --argjson port "$SMTP_PORT" \
            --arg user "$SMTP_USER" \
            --arg pass "$SMTP_PASSWORD" \
            --arg from "Freya Media Server <$SMTP_FROM>" \
            --argjson to "$SMTP_TO_JSON" \
            '{
                name: "Email",
                implementation: "Email",
                configContract: "EmailSettings",
                onGrab: false,
                onImportComplete: true,
                onUpgrade: true,
                onHealthIssue: true,
                fields: [
                    {name: "server", value: $server},
                    {name: "port", value: $port},
                    {name: "useEncryption", value: 0},
                    {name: "username", value: $user},
                    {name: "password", value: $pass},
                    {name: "from", value: $from},
                    {name: "to", value: $to}
                ]
            }')
        if $DRY_RUN; then
            log_info "[DRY RUN] Would add email notification to Radarr"
        else
            parse_response "$(api_call POST "http://localhost:7878/api/v3/notification" "$RADARR_KEY" "$radarr_email_payload")"
            if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                log_ok "Added email notification to Radarr"
            else
                log_err "Failed to add email notification to Radarr (HTTP $RESP_CODE): $RESP_BODY"
            fi
        fi
    else
        log_ok "Email notification already configured in Radarr"
    fi

    # Seerr email notification
    if [ -n "$PLEX_TOKEN" ]; then
        # Authenticate with Seerr
        seerr_cookie=$(curl -s -c- -X POST "http://localhost:5055/api/v1/auth/plex" \
            -H "Content-Type: application/json" \
            -d "{\"authToken\":\"$PLEX_TOKEN\"}" 2>/dev/null | grep -i 'connect.sid' | awk '{print $NF}')

        if [ -n "$seerr_cookie" ]; then
            # Check current email settings
            seerr_email=$(curl -sf -b "connect.sid=$seerr_cookie" "http://localhost:5055/api/v1/settings/notifications/email")
            seerr_email_enabled=$(echo "$seerr_email" | jq -r '.enabled // false')

            if [ "$seerr_email_enabled" = "true" ]; then
                log_ok "Email notification already configured in Seerr"
            else
                seerr_email_payload=$(jq -n \
                    --arg from "$SMTP_FROM" \
                    --arg host "$SMTP_SERVER" \
                    --argjson port "$SMTP_PORT" \
                    --arg sender "$SEERR_SENDER_NAME" \
                    --arg user "$SMTP_USER" \
                    --arg pass "$SMTP_PASSWORD" \
                    '{
                        enabled: true,
                        embedPoster: true,
                        options: {
                            userEmailRequired: true,
                            emailFrom: $from,
                            smtpHost: $host,
                            smtpPort: $port,
                            secure: false,
                            ignoreTls: false,
                            requireTls: false,
                            allowSelfSigned: false,
                            senderName: $sender,
                            authUser: $user,
                            authPass: $pass
                        },
                        types: 4062
                    }')
                if $DRY_RUN; then
                    log_info "[DRY RUN] Would configure email notification in Seerr"
                else
                    seerr_result=$(curl -s -w '\n%{http_code}' -X POST \
                        "http://localhost:5055/api/v1/settings/notifications/email" \
                        -b "connect.sid=$seerr_cookie" \
                        -H "Content-Type: application/json" \
                        -d "$seerr_email_payload")
                    seerr_code=$(echo "$seerr_result" | tail -1)
                    if [ "$seerr_code" = "200" ] || [ "$seerr_code" = "201" ]; then
                        log_ok "Configured email notification in Seerr"
                    else
                        log_err "Failed to configure Seerr email (HTTP $seerr_code)"
                    fi
                fi
            fi
        else
            log_warn "Could not authenticate with Seerr — skipping Seerr email setup"
            log_warn "Complete the Seerr setup wizard first, then re-run"
        fi
    else
        log_warn "PLEX_TOKEN not set — skipping Seerr email notification"
    fi
fi

fi  # end of "if ! $DO_GUEST" (skip owner sections when --guest)

# --- Section 9: Guest pipeline ---

if $DO_GUEST; then
    echo ""
    log_info "=== Configuring Guest Pipeline ==="

    # Read guest API keys from config.xml
    SONARR_GUEST_KEY=$(get_api_key "sonarr-guest" "SONARR_GUEST_API_KEY") || true
    RADARR_GUEST_KEY=$(get_api_key "radarr-guest" "RADARR_GUEST_API_KEY") || true

    if [ -z "$SONARR_GUEST_KEY" ] || [ -z "$RADARR_GUEST_KEY" ]; then
        log_err "Guest API keys not found. Ensure sonarr-guest and radarr-guest containers have started."
    else
        log_ok "Guest API keys loaded"

        wait_for_service "Sonarr-Guest" "http://localhost:8990/api/v3/health" "$SONARR_GUEST_KEY"
        wait_for_service "Radarr-Guest" "http://localhost:7879/api/v3/health" "$RADARR_GUEST_KEY"

        # Guest Sonarr: root folder
        echo ""
        log_info "=== Configuring Guest Sonarr ==="

        existing_roots=$(curl -sf -H "X-Api-Key: $SONARR_GUEST_KEY" "http://localhost:8990/api/v3/rootfolder")
        guest_sonarr_root=$(echo "$existing_roots" | jq -r '.[] | select(.path == "/data/media/guest-tv") | .id')

        if [ -z "$guest_sonarr_root" ]; then
            if $DRY_RUN; then
                log_info "[DRY RUN] Would add Guest Sonarr root folder /data/media/guest-tv"
            else
                parse_response "$(api_call POST "http://localhost:8990/api/v3/rootfolder" "$SONARR_GUEST_KEY" '{"path":"/data/media/guest-tv"}')"
                if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                    log_ok "Added Guest Sonarr root folder /data/media/guest-tv"
                else
                    log_err "Failed to add Guest Sonarr root folder (HTTP $RESP_CODE): $RESP_BODY"
                fi
            fi
        else
            log_ok "Guest Sonarr root folder already configured"
        fi

        # Guest Sonarr: download client
        existing_dl=$(curl -sf -H "X-Api-Key: $SONARR_GUEST_KEY" "http://localhost:8990/api/v3/downloadclient")
        guest_sonarr_dl=$(echo "$existing_dl" | jq -r '.[] | select(.name == "Transmission") | .id')

        if [ -z "$guest_sonarr_dl" ]; then
            guest_sonarr_dl_payload=$(cat <<GSDEOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": false,
  "removeFailedDownloads": false,
  "name": "Transmission",
  "implementation": "Transmission",
  "configContract": "TransmissionSettings",
  "fields": [
    {"name": "host", "value": "transmission"},
    {"name": "port", "value": 9091},
    {"name": "useSsl", "value": false},
    {"name": "urlBase", "value": "/transmission/rpc"},
    {"name": "tvCategory", "value": "guest-sonarr"},
    {"name": "recentTvPriority", "value": 0},
    {"name": "olderTvPriority", "value": 0},
    {"name": "addPaused", "value": false}
  ],
  "tags": []
}
GSDEOF
)
            if $DRY_RUN; then
                log_info "[DRY RUN] Would add Transmission to Guest Sonarr (category: guest-sonarr)"
            else
                parse_response "$(api_call POST "http://localhost:8990/api/v3/downloadclient" "$SONARR_GUEST_KEY" "$guest_sonarr_dl_payload")"
                if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                    log_ok "Added Transmission as Guest Sonarr download client (category: guest-sonarr)"
                else
                    log_err "Failed to add Transmission to Guest Sonarr (HTTP $RESP_CODE): $RESP_BODY"
                fi
            fi
        else
            log_ok "Transmission already configured in Guest Sonarr"
        fi

        # Guest Sonarr: listSyncLevel
        if ! $DRY_RUN; then
            parse_response "$(api_call PUT "http://localhost:8990/api/v3/config/importlist" "$SONARR_GUEST_KEY" '{"listSyncLevel":"keepAndUnmonitor","id":1}')"
            if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "202" ]; then
                log_ok "Set Guest Sonarr listSyncLevel to keepAndUnmonitor"
            else
                log_warn "Could not set listSyncLevel on Guest Sonarr (HTTP $RESP_CODE)"
            fi
        fi

        # Guest Radarr: root folder
        echo ""
        log_info "=== Configuring Guest Radarr ==="

        existing_roots=$(curl -sf -H "X-Api-Key: $RADARR_GUEST_KEY" "http://localhost:7879/api/v3/rootfolder")
        guest_radarr_root=$(echo "$existing_roots" | jq -r '.[] | select(.path == "/data/media/guest-movies") | .id')

        if [ -z "$guest_radarr_root" ]; then
            if $DRY_RUN; then
                log_info "[DRY RUN] Would add Guest Radarr root folder /data/media/guest-movies"
            else
                parse_response "$(api_call POST "http://localhost:7879/api/v3/rootfolder" "$RADARR_GUEST_KEY" '{"path":"/data/media/guest-movies"}')"
                if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                    log_ok "Added Guest Radarr root folder /data/media/guest-movies"
                else
                    log_err "Failed to add Guest Radarr root folder (HTTP $RESP_CODE): $RESP_BODY"
                fi
            fi
        else
            log_ok "Guest Radarr root folder already configured"
        fi

        # Guest Radarr: download client
        existing_dl=$(curl -sf -H "X-Api-Key: $RADARR_GUEST_KEY" "http://localhost:7879/api/v3/downloadclient")
        guest_radarr_dl=$(echo "$existing_dl" | jq -r '.[] | select(.name == "Transmission") | .id')

        if [ -z "$guest_radarr_dl" ]; then
            guest_radarr_dl_payload=$(cat <<GRDEOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": false,
  "removeFailedDownloads": false,
  "name": "Transmission",
  "implementation": "Transmission",
  "configContract": "TransmissionSettings",
  "fields": [
    {"name": "host", "value": "transmission"},
    {"name": "port", "value": 9091},
    {"name": "useSsl", "value": false},
    {"name": "urlBase", "value": "/transmission/rpc"},
    {"name": "movieCategory", "value": "guest-radarr"},
    {"name": "recentMoviePriority", "value": 0},
    {"name": "olderMoviePriority", "value": 0},
    {"name": "addPaused", "value": false}
  ],
  "tags": []
}
GRDEOF
)
            if $DRY_RUN; then
                log_info "[DRY RUN] Would add Transmission to Guest Radarr (category: guest-radarr)"
            else
                parse_response "$(api_call POST "http://localhost:7879/api/v3/downloadclient" "$RADARR_GUEST_KEY" "$guest_radarr_dl_payload")"
                if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                    log_ok "Added Transmission as Guest Radarr download client (category: guest-radarr)"
                else
                    log_err "Failed to add Transmission to Guest Radarr (HTTP $RESP_CODE): $RESP_BODY"
                fi
            fi
        else
            log_ok "Transmission already configured in Guest Radarr"
        fi

        # Guest Radarr: listSyncLevel
        if ! $DRY_RUN; then
            parse_response "$(api_call PUT "http://localhost:7879/api/v3/config/importlist" "$RADARR_GUEST_KEY" '{"listSyncLevel":"keepAndUnmonitor","id":1}')"
            if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "202" ]; then
                log_ok "Set Guest Radarr listSyncLevel to keepAndUnmonitor"
            else
                log_warn "Could not set listSyncLevel on Guest Radarr (HTTP $RESP_CODE)"
            fi
        fi

        # Add guest instances to Prowlarr
        echo ""
        log_info "=== Adding Guest instances to Prowlarr ==="

        existing_apps=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:9696/api/v1/applications")

        # Guest Sonarr in Prowlarr
        guest_sonarr_app=$(echo "$existing_apps" | jq -r '.[] | select(.name == "Sonarr-Guest") | .id')
        if [ -z "$guest_sonarr_app" ]; then
            guest_sonarr_app_payload=$(cat <<GSAEOF
{
  "syncLevel": "fullSync",
  "name": "Sonarr-Guest",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
    {"name": "baseUrl", "value": "http://sonarr-guest:8989"},
    {"name": "apiKey", "value": "$SONARR_GUEST_KEY"},
    {"name": "syncCategories", "value": [5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]},
    {"name": "animeSyncCategories", "value": [5070]}
  ],
  "tags": []
}
GSAEOF
)
            if $DRY_RUN; then
                log_info "[DRY RUN] Would add Sonarr-Guest to Prowlarr"
            else
                parse_response "$(api_call POST "http://localhost:9696/api/v1/applications" "$PROWLARR_KEY" "$guest_sonarr_app_payload")"
                if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                    log_ok "Added Sonarr-Guest as Prowlarr application"
                else
                    log_err "Failed to add Sonarr-Guest to Prowlarr (HTTP $RESP_CODE): $RESP_BODY"
                fi
            fi
        else
            log_ok "Sonarr-Guest already configured in Prowlarr"
        fi

        # Guest Radarr in Prowlarr
        guest_radarr_app=$(echo "$existing_apps" | jq -r '.[] | select(.name == "Radarr-Guest") | .id')
        if [ -z "$guest_radarr_app" ]; then
            guest_radarr_app_payload=$(cat <<GRAEOF
{
  "syncLevel": "fullSync",
  "name": "Radarr-Guest",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
    {"name": "baseUrl", "value": "http://radarr-guest:7878"},
    {"name": "apiKey", "value": "$RADARR_GUEST_KEY"},
    {"name": "syncCategories", "value": [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]}
  ],
  "tags": []
}
GRAEOF
)
            if $DRY_RUN; then
                log_info "[DRY RUN] Would add Radarr-Guest to Prowlarr"
            else
                parse_response "$(api_call POST "http://localhost:9696/api/v1/applications" "$PROWLARR_KEY" "$guest_radarr_app_payload")"
                if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                    log_ok "Added Radarr-Guest as Prowlarr application"
                else
                    log_err "Failed to add Radarr-Guest to Prowlarr (HTTP $RESP_CODE): $RESP_BODY"
                fi
            fi
        else
            log_ok "Radarr-Guest already configured in Prowlarr"
        fi

        # Trigger indexer sync
        if ! $DRY_RUN; then
            parse_response "$(api_call POST "http://localhost:9696/api/v1/command" "$PROWLARR_KEY" '{"name":"ApplicationIndexerSync"}')"
            if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                log_ok "Triggered Prowlarr indexer sync (includes guest instances)"
            fi
        fi
    fi
fi

# --- Section 10: Trakt integration (interactive) ---

if $DO_TRAKT; then
    echo ""
    log_info "=== Trakt Integration ==="

    trakt_device_flow() {
        local service_name="$1" client_id="$2" base_url="$3" api_key="$4" root_folder="$5"

        echo ""
        log_info "Starting Trakt device code flow for $service_name..."
        echo "  Each Trakt user needs to authorize separately."
        echo ""

        local user_index=0
        while true; do
            user_index=$((user_index + 1))

            # Get device code
            local device_response
            device_response=$(curl -sf -X POST "https://api.trakt.tv/oauth/device/code" \
                -H "Content-Type: application/json" \
                -d "{\"client_id\":\"$client_id\"}")

            if [ -z "$device_response" ]; then
                log_err "Failed to get Trakt device code"
                return 1
            fi

            local user_code device_code interval expires_in
            user_code=$(echo "$device_response" | jq -r '.user_code')
            device_code=$(echo "$device_response" | jq -r '.device_code')
            interval=$(echo "$device_response" | jq -r '.interval')
            expires_in=$(echo "$device_response" | jq -r '.expires_in')

            echo "  Go to: https://trakt.tv/activate"
            echo "  Enter code: $user_code"
            echo "  (expires in $((expires_in / 60)) minutes)"
            echo ""
            read -rp "  Press Enter after authorizing on Trakt (or 'skip' to stop adding users): " confirm

            if [ "$confirm" = "skip" ]; then
                break
            fi

            # Poll for token
            local token_response=""
            local attempts=0 max_attempts=$((expires_in / interval))
            while [ $attempts -lt $max_attempts ]; do
                token_response=$(curl -s -X POST "https://api.trakt.tv/oauth/device/token" \
                    -H "Content-Type: application/json" \
                    -d "{\"code\":\"$device_code\",\"client_id\":\"$client_id\"}")

                local access_token
                access_token=$(echo "$token_response" | jq -r '.access_token // empty')
                if [ -n "$access_token" ]; then
                    break
                fi
                sleep "$interval"
                attempts=$((attempts + 1))
            done

            local access_token refresh_token expires_at
            access_token=$(echo "$token_response" | jq -r '.access_token // empty')
            refresh_token=$(echo "$token_response" | jq -r '.refresh_token // empty')
            expires_at=$(echo "$token_response" | jq -r '.created_at + .expires_in // empty')

            if [ -z "$access_token" ]; then
                log_err "Trakt authorization timed out or failed"
                continue
            fi

            # Get Trakt username
            local trakt_user
            trakt_user=$(curl -sf -H "Authorization: Bearer $access_token" \
                -H "trakt-api-key: $client_id" \
                -H "trakt-api-version: 2" \
                "https://api.trakt.tv/users/me" | jq -r '.username')

            log_ok "Authorized as Trakt user: $trakt_user"

            # Convert expires_at to ISO 8601
            local expires_iso
            expires_iso=$(date -d "@$expires_at" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")

            # Create import list
            local list_name="Trakt - $trakt_user"

            # Check if list already exists
            local existing_lists
            existing_lists=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/importlist")
            local list_exists
            list_exists=$(echo "$existing_lists" | jq -r ".[] | select(.name == \"$list_name\") | .id")

            if [ -n "$list_exists" ]; then
                log_ok "Import list '$list_name' already exists in $service_name"
            else
                local list_payload
                if [ "$service_name" = "Sonarr" ]; then
                    list_payload=$(cat <<TLEOF
{
  "enableAutomaticAdd": true,
  "searchForMissingEpisodes": true,
  "shouldMonitor": "all",
  "monitorNewItems": "all",
  "rootFolderPath": "$root_folder",
  "qualityProfileId": 1,
  "seriesType": "standard",
  "seasonFolder": true,
  "name": "$list_name",
  "implementation": "TraktUserImport",
  "configContract": "TraktUserSettings",
  "listType": "trakt",
  "fields": [
    {"name": "accessToken", "value": "$access_token"},
    {"name": "refreshToken", "value": "$refresh_token"},
    {"name": "expires", "value": "$expires_iso"},
    {"name": "authUser", "value": "$trakt_user"},
    {"name": "traktListType", "value": 0},
    {"name": "username", "value": ""},
    {"name": "limit", "value": 100}
  ],
  "tags": []
}
TLEOF
)
                else
                    list_payload=$(cat <<TLEOF
{
  "enabled": true,
  "enableAuto": true,
  "monitor": "movieOnly",
  "rootFolderPath": "$root_folder",
  "qualityProfileId": 1,
  "searchOnAdd": true,
  "minimumAvailability": "released",
  "name": "$list_name",
  "implementation": "TraktUserImport",
  "configContract": "TraktUserSettings",
  "listType": "trakt",
  "fields": [
    {"name": "accessToken", "value": "$access_token"},
    {"name": "refreshToken", "value": "$refresh_token"},
    {"name": "expires", "value": "$expires_iso"},
    {"name": "authUser", "value": "$trakt_user"},
    {"name": "traktListType", "value": 0},
    {"name": "username", "value": ""},
    {"name": "limit", "value": 100}
  ],
  "tags": []
}
TLEOF
)
                fi

                if $DRY_RUN; then
                    log_info "[DRY RUN] Would create import list '$list_name' in $service_name"
                else
                    parse_response "$(api_call POST "$base_url/api/v3/importlist?forceSave=true" "$api_key" "$list_payload")"
                    if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                        log_ok "Created import list '$list_name' in $service_name"
                    else
                        log_err "Failed to create import list (HTTP $RESP_CODE): $RESP_BODY"
                    fi
                fi
            fi

            echo ""
            read -rp "  Add another Trakt user to $service_name? (y/N): " add_more
            if [ "$add_more" != "y" ] && [ "$add_more" != "Y" ]; then
                break
            fi
        done

        # Set listSyncLevel to keepAndUnmonitor
        if ! $DRY_RUN; then
            parse_response "$(api_call PUT "$base_url/api/v3/config/importlist" "$api_key" '{"listSyncLevel":"keepAndUnmonitor","id":1}')"
            if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "202" ]; then
                log_ok "Set $service_name listSyncLevel to keepAndUnmonitor"
            else
                log_warn "Could not set listSyncLevel on $service_name (HTTP $RESP_CODE)"
            fi
        fi
    }

    if [ -z "$SONARR_TRAKT_CLIENT_ID" ] || [ -z "$RADARR_TRAKT_CLIENT_ID" ]; then
        log_err "SONARR_TRAKT_CLIENT_ID and RADARR_TRAKT_CLIENT_ID must be set in .env"
        exit 1
    fi

    trakt_device_flow "Sonarr" "$SONARR_TRAKT_CLIENT_ID" "http://localhost:8989" "$SONARR_KEY" "/data/media/tv"
    trakt_device_flow "Radarr" "$RADARR_TRAKT_CLIENT_ID" "http://localhost:7878" "$RADARR_KEY" "/data/media/movies"

    # Trigger initial sync
    if ! $DRY_RUN; then
        api_call POST "http://localhost:8989/api/v3/command" "$SONARR_KEY" '{"name":"ImportListSync"}' >/dev/null
        api_call POST "http://localhost:7878/api/v3/command" "$RADARR_KEY" '{"name":"ImportListSync"}' >/dev/null
        log_ok "Triggered ImportListSync on Sonarr and Radarr"
    fi
fi

# --- Section 11: Summary ---

echo ""
echo "=== Setup Summary ==="
echo ""

if [ $ERRORS -gt 0 ]; then
    log_warn "Completed with $ERRORS error(s) — review messages above"
else
    log_ok "All automated steps completed successfully"
fi

echo ""
echo "Remaining manual steps:"
echo "  1. Plex: Sign in at http://localhost:32400/web and add /tv + /movies libraries"
echo "  2. Seerr: Complete setup wizard at http://localhost:5055"
if ! $DO_TRAKT; then
    echo "  3. Trakt: Re-run with --trakt flag to set up watchlist integration"
fi
if ! $DO_GUEST; then
    echo "  5. Guest: Re-run with --guest flag after starting guest containers"
fi
echo "  4. Install cron jobs (see wiki Maintenance page):"
echo "     crontab -e"
echo "     0 3 * * * docker exec prunarr prunarr movies remove --watched --days-watched 30 --force >> /tmp/prunarr-movies.log 2>&1"
echo "     15 3 * * * docker exec prunarr prunarr series remove --watched --days-watched 30 --force >> /tmp/prunarr-series.log 2>&1"
echo "     0 * * * * $PROJECT_DIR/scripts/trakt-sync.sh >> /tmp/trakt-sync.log 2>&1"
echo "     */30 * * * * $PROJECT_DIR/scripts/plex-cleanup.sh >> /tmp/plex-cleanup.log 2>&1"
echo ""

exit $ERRORS
