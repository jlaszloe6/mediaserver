#!/bin/bash
# init-setup.sh - Automated initial configuration of the media server stack
#
# Configures Prowlarr, Sonarr, Radarr, Transmission, and Jellyfin via their
# APIs after first boot. Reads/writes credentials in .env.
#
# Prerequisites:
#   - docker compose up -d (all containers running)
#   - Jellyfin setup wizard completed via browser
#
# Note: This script runs inside the cron container (on bridge network),
# so Docker service names are used for all URLs.
#
# Usage: ./scripts/init-setup.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
CONFIG_DIR="$PROJECT_DIR/config"

ERRORS=0
DRY_RUN=false

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
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Usage: init-setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
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

if [ -z "$PROWLARR_KEY" ] || [ -z "$SONARR_KEY" ] || [ -z "$RADARR_KEY" ]; then
    log_err "Missing API keys. Ensure all services have started at least once."
    exit 1
fi

log_ok "API keys loaded (Prowlarr, Sonarr, Radarr)"

# --- Section 2: Wait for services ---

echo ""
wait_for_service "Jellyfin"     "http://jellyfin:8096/health"
wait_for_service "Prowlarr"     "http://prowlarr:9696/api/v1/health"     "$PROWLARR_KEY"
wait_for_service "Sonarr"       "http://sonarr:8989/api/v3/health"       "$SONARR_KEY"
wait_for_service "Radarr"       "http://radarr:7878/api/v3/health"       "$RADARR_KEY"
wait_for_service "Transmission" "http://transmission:9091/transmission/rpc"

# --- Section 3: Configure Prowlarr ---

echo ""
log_info "=== Configuring Prowlarr ==="

# 3a: Add indexers
existing_indexers=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "http://prowlarr:9696/api/v1/indexer")

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

    parse_response "$(api_call POST "http://prowlarr:9696/api/v1/indexer" "$PROWLARR_KEY" "$payload")"
    if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
        log_ok "Added indexer '$def_name'"
    else
        log_err "Failed to add indexer '$def_name' (HTTP $RESP_CODE): $RESP_BODY"
    fi
}

NO_TAGS="[]"

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
        parse_response "$(api_call POST "http://prowlarr:9696/api/v1/indexer" "$PROWLARR_KEY" "$knaben_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added indexer 'Knaben'"
        else
            log_err "Failed to add indexer 'Knaben' (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Indexer 'Knaben' already configured"
fi

# 3b: Add Sonarr as application
existing_apps=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "http://prowlarr:9696/api/v1/applications")
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
        parse_response "$(api_call POST "http://prowlarr:9696/api/v1/applications" "$PROWLARR_KEY" "$sonarr_app_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Sonarr as Prowlarr application"
        else
            log_err "Failed to add Sonarr application (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Sonarr application already configured in Prowlarr"
fi

# 3c: Add Radarr as application
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
        parse_response "$(api_call POST "http://prowlarr:9696/api/v1/applications" "$PROWLARR_KEY" "$radarr_app_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Radarr as Prowlarr application"
        else
            log_err "Failed to add Radarr application (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Radarr application already configured in Prowlarr"
fi

# 3d: Trigger ApplicationIndexerSync
if ! $DRY_RUN; then
    parse_response "$(api_call POST "http://prowlarr:9696/api/v1/command" "$PROWLARR_KEY" '{"name":"ApplicationIndexerSync"}')"
    if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
        log_ok "Triggered Prowlarr → Sonarr/Radarr indexer sync"
    else
        log_err "Failed to trigger indexer sync (HTTP $RESP_CODE)"
    fi
fi

# --- Section 4: Custom formats and quality profiles ---

echo ""
log_info "=== Configuring Quality Profiles ==="

setup_quality_profile() {
    local url="$1" key="$2" svc="$3"

    # Check if custom formats already exist
    local existing_cf
    existing_cf=$(curl -sf -H "X-Api-Key: $key" "$url/api/v3/customformat")
    if echo "$existing_cf" | jq -e '.[] | select(.name == "Hungarian + Original")' > /dev/null 2>&1; then
        log_ok "$svc custom formats already configured"
    else
        if $DRY_RUN; then
            log_info "[DRY RUN] Would create custom formats in $svc"
        else
            local cf_specs='[
                {"name":"Hungarian + Original","specifications":[{"name":"Hungarian Audio","implementation":"LanguageSpecification","fields":[{"name":"value","value":22}],"negate":false,"required":true},{"name":"English Audio","implementation":"LanguageSpecification","fields":[{"name":"value","value":1}],"negate":false,"required":true}]},
                {"name":"English SRT Subs","specifications":[{"name":"English Sub","implementation":"LanguageSpecification","fields":[{"name":"value","value":1}],"negate":false,"required":true}]},
                {"name":"Hungarian Only","specifications":[{"name":"Hungarian Audio","implementation":"LanguageSpecification","fields":[{"name":"value","value":22}],"negate":false,"required":true},{"name":"No English","implementation":"LanguageSpecification","fields":[{"name":"value","value":1}],"negate":true,"required":true}]},
                {"name":"4K","specifications":[{"name":"4K Resolution","implementation":"ResolutionSpecification","fields":[{"name":"value","value":2160}],"negate":false,"required":true}]}
            ]'
            local cf
            for cf in $(echo "$cf_specs" | jq -c '.[]'); do
                local cfname
                cfname=$(echo "$cf" | jq -r '.name')
                parse_response "$(api_call POST "$url/api/v3/customformat" "$key" "$cf")"
                if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
                    log_ok "$svc: Created custom format '$cfname'"
                else
                    log_err "$svc: Failed to create '$cfname' (HTTP $RESP_CODE)"
                fi
            done
        fi
    fi

    # Update HD-1080p profile to HD-1080p Max with custom format scores
    local profile_name
    profile_name=$(curl -sf -H "X-Api-Key: $key" "$url/api/v3/qualityprofile/4" | jq -r '.name')
    if [ "$profile_name" = "HD-1080p Max" ]; then
        log_ok "$svc quality profile 'HD-1080p Max' already configured"
    else
        if $DRY_RUN; then
            log_info "[DRY RUN] Would update $svc quality profile to HD-1080p Max"
        else
            local formats
            formats=$(curl -sf -H "X-Api-Key: $key" "$url/api/v3/customformat")
            local ho es honly fk
            ho=$(echo "$formats" | jq -r '.[] | select(.name=="Hungarian + Original") | .id')
            es=$(echo "$formats" | jq -r '.[] | select(.name=="English SRT Subs") | .id')
            honly=$(echo "$formats" | jq -r '.[] | select(.name=="Hungarian Only") | .id')
            fk=$(echo "$formats" | jq -r '.[] | select(.name=="4K") | .id')

            local profile updated
            profile=$(curl -sf -H "X-Api-Key: $key" "$url/api/v3/qualityprofile/4")
            updated=$(echo "$profile" | jq \
                --argjson ho "$ho" --argjson es "$es" --argjson honly "$honly" --argjson fk "$fk" \
                '.name = "HD-1080p Max" | .upgradeAllowed = true | .formatItems = [
                    {format: $ho, name: "Hungarian + Original", score: 150},
                    {format: $es, name: "English SRT Subs", score: 100},
                    {format: $honly, name: "Hungarian Only", score: -50},
                    {format: $fk, name: "4K", score: -200}
                ]')

            parse_response "$(api_call PUT "$url/api/v3/qualityprofile/4" "$key" "$updated")"
            if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "202" ]; then
                log_ok "$svc: Updated quality profile to 'HD-1080p Max'"
            else
                log_err "$svc: Failed to update quality profile (HTTP $RESP_CODE)"
            fi
        fi
    fi
}

setup_quality_profile "http://sonarr:8989" "$SONARR_KEY" "Sonarr"
setup_quality_profile "http://radarr:7878" "$RADARR_KEY" "Radarr"

# --- Section 5: Configure Sonarr ---

echo ""
log_info "=== Configuring Sonarr ==="

# Root folder
existing_roots=$(curl -sf -H "X-Api-Key: $SONARR_KEY" "http://sonarr:8989/api/v3/rootfolder")
sonarr_root_exists=$(echo "$existing_roots" | jq -r '.[] | select(.path == "/data/media/tv") | .id')

if [ -z "$sonarr_root_exists" ]; then
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add Sonarr root folder /data/media/tv"
    else
        parse_response "$(api_call POST "http://sonarr:8989/api/v3/rootfolder" "$SONARR_KEY" '{"path":"/data/media/tv"}')"
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
existing_dl=$(curl -sf -H "X-Api-Key: $SONARR_KEY" "http://sonarr:8989/api/v3/downloadclient")
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
        parse_response "$(api_call POST "http://sonarr:8989/api/v3/downloadclient" "$SONARR_KEY" "$sonarr_dl_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Transmission as Sonarr download client"
        else
            log_err "Failed to add Transmission to Sonarr (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Transmission already configured in Sonarr"
fi

# --- Section 6: Configure Radarr ---

echo ""
log_info "=== Configuring Radarr ==="

# Root folder
existing_roots=$(curl -sf -H "X-Api-Key: $RADARR_KEY" "http://radarr:7878/api/v3/rootfolder")
radarr_root_exists=$(echo "$existing_roots" | jq -r '.[] | select(.path == "/data/media/movies") | .id')

if [ -z "$radarr_root_exists" ]; then
    if $DRY_RUN; then
        log_info "[DRY RUN] Would add Radarr root folder /data/media/movies"
    else
        parse_response "$(api_call POST "http://radarr:7878/api/v3/rootfolder" "$RADARR_KEY" '{"path":"/data/media/movies"}')"
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
existing_dl=$(curl -sf -H "X-Api-Key: $RADARR_KEY" "http://radarr:7878/api/v3/downloadclient")
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
        parse_response "$(api_call POST "http://radarr:7878/api/v3/downloadclient" "$RADARR_KEY" "$radarr_dl_payload")"
        if [ "$RESP_CODE" = "200" ] || [ "$RESP_CODE" = "201" ]; then
            log_ok "Added Transmission as Radarr download client"
        else
            log_err "Failed to add Transmission to Radarr (HTTP $RESP_CODE): $RESP_BODY"
        fi
    fi
else
    log_ok "Transmission already configured in Radarr"
fi

# --- Section 7: Configure Transmission seed limits ---

echo ""
log_info "=== Configuring Transmission ==="

if $DRY_RUN; then
    log_info "[DRY RUN] Would set seed ratio=2.0, idle seeding limit=disabled (per-indexer seed times used instead)"
else
    SESSION_ID=$(curl -si http://transmission:9091/transmission/rpc 2>/dev/null | grep -i 'X-Transmission-Session-Id:' | head -1 | awk '{print $2}' | tr -cd 'a-zA-Z0-9')
    if [ -n "$SESSION_ID" ]; then
        result=$(curl -s -w '\n%{http_code}' -X POST http://transmission:9091/transmission/rpc \
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
    existing_notif=$(curl -sf -H "X-Api-Key: $SONARR_KEY" "http://sonarr:8989/api/v3/notification")
    sonarr_email_exists=$(echo "$existing_notif" | jq -r '.[] | select(.name == "Email") | .id')

    if [ -z "$sonarr_email_exists" ]; then
        sonarr_email_payload=$(jq -n \
            --arg server "$SMTP_SERVER" \
            --argjson port "$SMTP_PORT" \
            --arg user "$SMTP_USER" \
            --arg pass "$SMTP_PASSWORD" \
            --arg from "${SERVER_NAME:-Media Server} <$SMTP_FROM>" \
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
            parse_response "$(api_call POST "http://sonarr:8989/api/v3/notification" "$SONARR_KEY" "$sonarr_email_payload")"
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
    existing_notif=$(curl -sf -H "X-Api-Key: $RADARR_KEY" "http://radarr:7878/api/v3/notification")
    radarr_email_exists=$(echo "$existing_notif" | jq -r '.[] | select(.name == "Email") | .id')

    if [ -z "$radarr_email_exists" ]; then
        radarr_email_payload=$(jq -n \
            --arg server "$SMTP_SERVER" \
            --argjson port "$SMTP_PORT" \
            --arg user "$SMTP_USER" \
            --arg pass "$SMTP_PASSWORD" \
            --arg from "${SERVER_NAME:-Media Server} <$SMTP_FROM>" \
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
            parse_response "$(api_call POST "http://radarr:7878/api/v3/notification" "$RADARR_KEY" "$radarr_email_payload")"
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
    seerr_settings=$(curl -sf "http://seerr:5055/api/v1/settings/notifications/email" 2>/dev/null)
    seerr_email_enabled=$(echo "$seerr_settings" | jq -r '.enabled // false' 2>/dev/null)

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
                "http://seerr:5055/api/v1/settings/notifications/email" \
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
fi

# --- Section 9: Summary ---

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
echo "  1. Jellyfin: Complete setup wizard at http://jellyfin:8096 (via browser)"
echo "  2. Seerr: Complete setup wizard at http://seerr:5055"
echo ""

exit $ERRORS
