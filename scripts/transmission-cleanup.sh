#!/bin/bash
# transmission-cleanup.sh - Remove orphaned torrents from Transmission
#
# Finds completed torrents whose media has been deleted from Sonarr/Radarr
# and removes them — with different rules for private vs public trackers.
#
# Private trackers (nCore, etc.) have hit-and-run policies:
#   → Must seed for at least HNR_HOURS (72h) after download completes
#   → After that, remove if orphaned
#
# Public trackers (1337x, YTS, TPB, etc.) have no seed obligation:
#   → Remove immediately if orphaned (media deleted from library)
#
# Also "superseded": the movie/series is still in Radarr/Sonarr, but the
# library has since switched to a different file (quality upgrade, PROPER,
# or a duplicate grab) - so nothing links to this torrent's files any more.
# See is_superseded() for the (deliberately strict) conditions. Same H&R
# rules apply afterwards.
#
# Detection: Cross-references torrent hashes against Sonarr/Radarr download
# history. Falls back to filesystem hardlink check for old hashes.
#
# Called by: jellyfin-cleanup.sh or standalone.

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

SONARR_KEY="$SONARR_API_KEY"
RADARR_KEY="$RADARR_API_KEY"

# Instance configs: "sonarr_url|sonarr_key|radarr_url|radarr_key"
INSTANCE_CONFIGS="http://sonarr:8989|$SONARR_KEY|http://radarr:7878|$RADARR_KEY"

TRANSMISSION_URL="http://transmission:9091/transmission/rpc"
SONARR_URL="${INSTANCE_CONFIGS%%|*}"

# Where Transmission's /downloads lives inside this (cron) container.
TORRENTS_HOST_ROOT="/mnt/mediaserver/torrents"

# Superseded torrents (see is_superseded): only judged this long after the
# download finished, so an import that's merely slow is never mistaken
# for a replaced one.
SUPERSEDED_GRACE_HOURS=48
VIDEO_EXT_RE='\.(mkv|mp4|avi|m4v|ts|wmv)$'
SAMPLE_RE='(^|[/._ -])sample([/._ -]|$)'

# --- Hit-and-run configuration ---
# Tracker domains with H&R policies and their minimum seed hours.
# Add new private trackers here as needed.
# Format: "domain:hours" — if any tracker URL contains the domain, it's matched.
HNR_TRACKERS=(
    "ncore.pro:72"
    "ncore.sh:72"
)

# Default minimum seed hours for unrecognized private trackers (safety net)
HNR_DEFAULT_HOURS=72

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

transmission_rpc() {
    # --max-time bounds every caller of this helper (session-get,
    # torrent-get, torrent-remove) - without it, a stalled (not just
    # refused/errored) connection to Transmission would hang this cron
    # job indefinitely instead of ever reaching any of the `||` error
    # handling built around these calls.
    curl -sf --max-time 30 "$TRANSMISSION_URL" \
        -H "X-Transmission-Session-Id: $1" \
        -H "Content-Type: application/json" \
        -d "$2" 2>/dev/null
}

# A torrent the library has moved past: returns 0 only if ALL hold -
#  - finished >= SUPERSEDED_GRACE_HOURS ago, in a Sonarr/Radarr category dir
#  - nothing it was grabbed for still needs it: the movie / every episode
#    Sonarr's history ties to this hash either already has a (different)
#    file, or has no file AND is unmonitored - i.e. it was let go on
#    purpose, e.g. jellyfin-watched-cleanup.sh clearing a still-running
#    series' watched episodes (it unmonitors them, then deletes the files,
#    leaving the torrent copy as the only link-count-1 remnant).
#    This is what keeps the Mayday case safe (import never happened, the
#    torrent holds the ONLY copy of something still wanted): there the item
#    has no file but is still monitored, so the torrent is kept.
#  - it has >= 1 non-sample video file, and every one of them exists and
#    has link count 1, i.e. no library file is a hardlink of it.
# Anything unexpected (API/RPC failure, missing/unreadable file, ".." in a
# torrent-supplied name) returns 1 = keep.
is_superseded() {
    local id="$1" dldir="$2" done_date="$3" movie_id="$4" series_id="$5" hash="$6"
    local eps ep cache files name path host_dir nvideo=0

    [ "${done_date:-0}" -gt 0 ] 2>/dev/null || return 1
    [ $((NOW - done_date)) -ge $((SUPERSEDED_GRACE_HOURS * 3600)) ] || return 1
    [[ "$dldir" =~ ^/downloads/complete/(radarr|tv-sonarr|guest-radarr|guest-sonarr)/?$ ]] || return 1

    if [ -n "$movie_id" ]; then
        grep -qx "$movie_id" "$RADARR_SETTLED" || return 1
    elif [ -n "$series_id" ]; then
        eps=$(grep "^E:${hash}:" "$HISTORY_MAP" | cut -d: -f3 | sort -u)
        [ -n "$eps" ] || return 1
        cache="$EP_CACHE/$series_id"
        if [ ! -e "$cache" ]; then
            curl -sf --max-time 15 -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/episode?seriesId=$series_id" \
                | jq -r '.[] | select(.hasFile == true or .monitored == false) | .id' > "$cache.tmp" \
                && mv "$cache.tmp" "$cache" || { rm -f "$cache.tmp"; return 1; }
        fi
        for ep in $eps; do
            grep -qx "$ep" "$cache" || return 1
        done
    else
        return 1
    fi

    files=$(transmission_rpc "$SID" \
        "{\"method\":\"torrent-get\",\"arguments\":{\"ids\":[$id],\"fields\":[\"files\"]}}" \
        | jq -r '.arguments.torrents[0].files[].name') || return 1
    host_dir="${dldir/#\/downloads/$TORRENTS_HOST_ROOT}"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        case "$name" in *..*) return 1 ;; esac
        echo "$name" | grep -qiE "$VIDEO_EXT_RE" || continue
        echo "$name" | grep -qiE "$SAMPLE_RE" && continue
        path="$host_dir/$name"
        [ -f "$path" ] || return 1
        [ "$(stat -c '%h' "$path" 2>/dev/null || echo 0)" = "1" ] || return 1
        nvideo=$((nvideo + 1))
    done <<< "$files"
    [ "$nvideo" -gt 0 ]
}

float_gte() {
    python3 -c "import sys; sys.exit(0 if float('$1') >= float('$2') else 1)"
}

# Returns the required H&R seed hours for a torrent, or 0 if public
get_hnr_hours() {
    local is_private="$1"
    local tracker_domains="$2"  # space-separated list of tracker domains

    # Public trackers: no seed obligation
    if [ "$is_private" != "true" ]; then
        echo 0
        return
    fi

    # Check against known H&R trackers
    for entry in "${HNR_TRACKERS[@]}"; do
        local domain="${entry%%:*}"
        local hours="${entry#*:}"
        if echo "$tracker_domains" | grep -q "$domain" 2>/dev/null; then
            echo "$hours"
            return
        fi
    done

    # Unknown private tracker: use safe default
    echo "$HNR_DEFAULT_HOURS"
}

log "=== Transmission orphan cleanup ==="

# --- Connect to Transmission ---
SID=$(curl -si --max-time 15 "$TRANSMISSION_URL" 2>/dev/null \
    | grep -oP '(?<=X-Transmission-Session-Id: )\S+' | head -1) || true
if [ -z "$SID" ]; then
    log "ERROR: Cannot connect to Transmission"
    exit 1
fi

# Session info is essential (feeds the ratio-based removal check below) -
# fail the whole run rather than silently fall back to jq's `// 2.0` on
# empty input from a failed request, which would apply the wrong ratio
# limit to every private-tracker torrent without any indication why.
SESSION_INFO=$(transmission_rpc "$SID" \
    '{"method":"session-get","arguments":{"fields":["seedRatioLimit"]}}') || {
    log "ERROR: Failed to query Transmission session info"
    exit 1
}
SEED_RATIO_LIMIT=$(echo "$SESSION_INFO" | jq -r '.arguments.seedRatioLimit // 2.0')
log "Session seed ratio limit: $SEED_RATIO_LIMIT"

# --- Build orphan detection data (from ALL instances) ---
QUEUE_HASHES=$(mktemp)
RADARR_IDS=$(mktemp)
RADARR_SETTLED=$(mktemp)
SONARR_IDS=$(mktemp)
HISTORY_MAP=$(mktemp)
TMPFILE=$(mktemp)
EP_CACHE=$(mktemp -d)
trap 'rm -rf "$QUEUE_HASHES" "$RADARR_IDS" "$RADARR_SETTLED" "$SONARR_IDS" "$HISTORY_MAP" "$TMPFILE" "$EP_CACHE"' EXIT

# Every fetch below feeds orphan detection further down (a torrent is
# "orphaned" if it's NOT found in these lists) - a transient fetch failure
# must NOT be silently treated as "confirmed empty", or a Radarr/Sonarr
# blip during this run would make every one of its torrents look orphaned
# and get deleted along with their downloaded data. FETCH_ERRORS tracks
# that distinction; the old bare `|| true` only prevented a set -e abort
# and made no such distinction at all.
FETCH_ERRORS=0

while IFS= read -r inst; do
    [ -z "$inst" ] && continue
    IFS='|' read -r s_url s_key r_url r_key <<< "$inst"

    # Queue hashes
    curl -sf --max-time 15 -H "X-Api-Key: $s_key" "$s_url/api/v3/queue?pageSize=200" 2>/dev/null \
        | jq -r '.records[].downloadId // empty' 2>/dev/null >> "$QUEUE_HASHES" \
        || { log "ERROR: Failed to fetch Sonarr queue ($s_url)"; FETCH_ERRORS=$((FETCH_ERRORS + 1)); }
    curl -sf --max-time 15 -H "X-Api-Key: $r_key" "$r_url/api/v3/queue?pageSize=200" 2>/dev/null \
        | jq -r '.records[].downloadId // empty' 2>/dev/null >> "$QUEUE_HASHES" \
        || { log "ERROR: Failed to fetch Radarr queue ($r_url)"; FETCH_ERRORS=$((FETCH_ERRORS + 1)); }

    # Library IDs
    curl -sf --max-time 15 -H "X-Api-Key: $r_key" "$r_url/api/v3/movie" 2>/dev/null \
        | jq -r '.[] | "\(.id) \(.hasFile) \(.monitored)"' >> "$RADARR_IDS" \
        || { log "ERROR: Failed to fetch Radarr movie library ($r_url)"; FETCH_ERRORS=$((FETCH_ERRORS + 1)); }
    curl -sf --max-time 15 -H "X-Api-Key: $s_key" "$s_url/api/v3/series" 2>/dev/null \
        | jq -r '.[].id' >> "$SONARR_IDS" \
        || { log "ERROR: Failed to fetch Sonarr series library ($s_url)"; FETCH_ERRORS=$((FETCH_ERRORS + 1)); }

    # History mapping
    curl -sf --max-time 15 -H "X-Api-Key: $r_key" "$r_url/api/v3/history?pageSize=500" 2>/dev/null \
        | jq -r '.records[] | select(.downloadId != null) | "R:" + (.downloadId | ascii_downcase) + ":" + (.movieId | tostring)' 2>/dev/null >> "$HISTORY_MAP" \
        || { log "ERROR: Failed to fetch Radarr history ($r_url)"; FETCH_ERRORS=$((FETCH_ERRORS + 1)); }
    curl -sf --max-time 15 -H "X-Api-Key: $s_key" "$s_url/api/v3/history?pageSize=500" 2>/dev/null \
        | jq -r '.records[] | select(.downloadId != null) | ("S:" + (.downloadId | ascii_downcase) + ":" + (.seriesId | tostring)), (select(.episodeId != null) | "E:" + (.downloadId | ascii_downcase) + ":" + (.episodeId | tostring))' 2>/dev/null >> "$HISTORY_MAP" \
        || { log "ERROR: Failed to fetch Sonarr history ($s_url)"; FETCH_ERRORS=$((FETCH_ERRORS + 1)); }
done <<< "$INSTANCE_CONFIGS"

if [ "$FETCH_ERRORS" -gt 0 ]; then
    log "ERROR: $FETCH_ERRORS data fetch(es) failed - skipping this run rather than risk removing torrents based on incomplete orphan-detection data"
    exit 1
fi

# Deduplicate and normalize
sort -u -o "$QUEUE_HASHES" "$QUEUE_HASHES"
tr '[:upper:]' '[:lower:]' < "$QUEUE_HASHES" > "$QUEUE_HASHES.tmp" && mv "$QUEUE_HASHES.tmp" "$QUEUE_HASHES"
# "Settled" = has a file, or deliberately unwanted (no file + unmonitored).
awk '$2 == "true" || $3 == "false" {print $1}' "$RADARR_IDS" | sort -u > "$RADARR_SETTLED"
cut -d' ' -f1 "$RADARR_IDS" | sort -u -o "$RADARR_IDS"
sort -u -o "$SONARR_IDS" "$SONARR_IDS"
sort -u -o "$HISTORY_MAP" "$HISTORY_MAP"

# --- Get torrents (with tracker info) ---
# Also essential - without it there's nothing to iterate below, so fail
# loudly rather than let set -e abort mid-pipeline with no explanation.
transmission_rpc "$SID" '{
    "method": "torrent-get",
    "arguments": {
        "fields": ["id","name","hashString","downloadDir","percentDone","status","uploadRatio",
                    "seedRatioLimit","seedRatioMode","isFinished","doneDate","activityDate",
                    "trackers","isPrivate"]
    }
}' | jq -c '.arguments.torrents[]' > "$TMPFILE" || {
    log "ERROR: Failed to fetch torrent list from Transmission"
    exit 1
}

REMOVED=0
SKIPPED=0
KEPT=0
FAILED=0
NOW=$(date +%s)

while IFS= read -r torrent; do
    NAME=$(echo "$torrent" | jq -r '.name')
    ID=$(echo "$torrent" | jq -r '.id')
    HASH=$(echo "$torrent" | jq -r '.hashString')
    PERCENT=$(echo "$torrent" | jq -r '.percentDone')
    STATUS=$(echo "$torrent" | jq -r '.status')
    RATIO=$(echo "$torrent" | jq -r '.uploadRatio')
    RATIO_MODE=$(echo "$torrent" | jq -r '.seedRatioMode')
    RATIO_LIMIT=$(echo "$torrent" | jq -r '.seedRatioLimit')
    IS_FINISHED=$(echo "$torrent" | jq -r '.isFinished')
    DONE_DATE=$(echo "$torrent" | jq -r '.doneDate')
    IS_PRIVATE=$(echo "$torrent" | jq -r '.isPrivate')
    TRACKER_DOMAINS=$(echo "$torrent" | jq -r '[.trackers[].announce] | map(split("/")[2] // empty) | unique | join(" ")')

    # Skip incomplete downloads
    if ! float_gte "$PERCENT" "1.0"; then
        continue
    fi

    # Skip if still in active download queue
    if grep -qx "$HASH" "$QUEUE_HASHES" 2>/dev/null; then
        KEPT=$((KEPT + 1))
        continue
    fi

    # --- Check if orphaned ---
    ORPHANED=false

    MOVIE_ID=$(grep "^R:${HASH}:" "$HISTORY_MAP" 2>/dev/null | head -1 | cut -d: -f3 || true)
    if [ -n "$MOVIE_ID" ]; then
        if ! grep -qx "$MOVIE_ID" "$RADARR_IDS" 2>/dev/null; then
            ORPHANED=true
        fi
    fi

    if ! $ORPHANED; then
        SERIES_ID=$(grep "^S:${HASH}:" "$HISTORY_MAP" 2>/dev/null | head -1 | cut -d: -f3 || true)
        if [ -n "$SERIES_ID" ]; then
            if ! grep -qx "$SERIES_ID" "$SONARR_IDS" 2>/dev/null; then
                ORPHANED=true
            fi
        fi
    fi

    # Fallback: filesystem hardlink check for old torrents not in history
    if ! $ORPHANED && [ -z "$MOVIE_ID" ] && [ -z "$SERIES_ID" ]; then
        DLDIR=$(echo "$torrent" | jq -r '.downloadDir // empty' 2>/dev/null || true)
        if [ -n "$DLDIR" ]; then
            HOST_DIR="${DLDIR/#\/downloads/$TORRENTS_HOST_ROOT}"
            # `|| MAIN_FILE=""`: this per-torrent RPC call is now bounded by
            # transmission_rpc's --max-time, so a stalled/failed lookup for
            # ONE old torrent actually returns a failure rather than
            # hanging - without this guard, that failure would abort the
            # whole script under set -e/pipefail, stopping processing of
            # every other torrent in the loop over a single item's lookup.
            # An empty MAIN_FILE just means "can't confirm via hardlink
            # check", which correctly leaves ORPHANED unset for this
            # torrent rather than wrongly asserting either outcome.
            MAIN_FILE=$(transmission_rpc "$SID" \
                "{\"method\":\"torrent-get\",\"arguments\":{\"ids\":[$ID],\"fields\":[\"files\"]}}" \
                | jq -r '[.arguments.torrents[0].files[] | {name, length}] | sort_by(-.length) | .[0].name // empty') || {
                log "  WARN: Could not query files for '$NAME' (RPC failed) - skipping hardlink check"
                MAIN_FILE=""
            }
            # File names come from the torrent's own metadata (attacker-
            # influenced) - reject anything containing ".." before joining
            # it into a filesystem path, even though this only feeds a
            # read-only existence/hardlink check below.
            case "$MAIN_FILE" in
                *..*) MAIN_FILE="" ;;
            esac
            if [ -n "$MAIN_FILE" ]; then
                FULL_PATH="$HOST_DIR/$MAIN_FILE"
                if [ ! -e "$FULL_PATH" ]; then
                    ORPHANED=true
                elif [ "$(stat -c '%h' "$FULL_PATH" 2>/dev/null || echo 2)" = "1" ]; then
                    ORPHANED=true
                fi
            fi
        fi
    fi

    # Still-tracked media whose library copy is now a different file.
    SUPERSEDED=false
    if ! $ORPHANED && { [ -n "$MOVIE_ID" ] || [ -n "$SERIES_ID" ]; }; then
        if is_superseded "$ID" "$(echo "$torrent" | jq -r '.downloadDir // empty')" "$DONE_DATE" "$MOVIE_ID" "$SERIES_ID" "$HASH"; then
            ORPHANED=true
            SUPERSEDED=true
        fi
    fi

    if ! $ORPHANED; then
        KEPT=$((KEPT + 1))
        continue
    fi

    # --- Orphaned: determine removal eligibility based on tracker type ---
    HNR_HOURS=$(get_hnr_hours "$IS_PRIVATE" "$TRACKER_DOMAINS")
    CAN_REMOVE=false
    REASON=""

    if [ "$HNR_HOURS" = "0" ]; then
        # Public tracker: no seed obligation, remove immediately
        CAN_REMOVE=true
        REASON="public tracker, no seed obligation"
    else
        # Private tracker with H&R policy
        # Check 1: Transmission says seeding is done
        if [ "$IS_FINISHED" = "true" ]; then
            CAN_REMOVE=true
            REASON="isFinished=true (seed goal met)"
        fi

        # Check 2: Ratio met
        if ! $CAN_REMOVE; then
            EFFECTIVE_LIMIT="$SEED_RATIO_LIMIT"
            if [ "$RATIO_MODE" = "1" ]; then
                EFFECTIVE_LIMIT="$RATIO_LIMIT"
            fi
            if float_gte "$RATIO" "$EFFECTIVE_LIMIT"; then
                CAN_REMOVE=true
                REASON="ratio=$RATIO >= limit=$EFFECTIVE_LIMIT"
            fi
        fi

        # Check 3: H&R period elapsed (time since download completed)
        if ! $CAN_REMOVE && [ "${DONE_DATE:-0}" -gt 0 ] 2>/dev/null; then
            SEED_SECONDS=$((NOW - DONE_DATE))
            REQUIRED_SECONDS=$((HNR_HOURS * 3600))
            if [ "$SEED_SECONDS" -ge "$REQUIRED_SECONDS" ]; then
                CAN_REMOVE=true
                REASON="h&r period done (${SEED_SECONDS}s >= ${REQUIRED_SECONDS}s / ${HNR_HOURS}h)"
            else
                REMAINING=$(( (REQUIRED_SECONDS - SEED_SECONDS) / 3600 ))
                log "  Waiting (H&R ${HNR_HOURS}h): $NAME (~${REMAINING}h remaining, ratio=$RATIO)"
                SKIPPED=$((SKIPPED + 1))
                continue
            fi
        fi

        if ! $CAN_REMOVE; then
            log "  Skipped (private, seeding): $NAME (ratio=$RATIO, status=$STATUS, h&r=${HNR_HOURS}h)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    $SUPERSEDED && REASON="superseded, no library file links to it and nothing still wants it; $REASON"

    # --- Remove the orphaned torrent ---
    if $DRY_RUN; then
        log "  [DRY RUN] Would remove orphan: $NAME ($REASON)"
        REMOVED=$((REMOVED + 1))
    else
        # `|| RESULT=""` guards the transport-level failure case (e.g.
        # Transmission mid-restart) so it falls through to the same
        # "not success" branch as an RPC-level failure, instead of
        # aborting the whole script under set -e. REMOVED only increments
        # on a *confirmed* "success" result - previously it incremented
        # unconditionally, so a failed removal (network error or RPC
        # rejection) was still counted and reported as if the torrent
        # and its data had actually been deleted.
        RESULT=$(transmission_rpc "$SID" \
            "{\"method\":\"torrent-remove\",\"arguments\":{\"ids\":[$ID],\"delete-local-data\":true}}") || RESULT=""
        if [ "$(echo "$RESULT" | jq -r '.result // "error"' 2>/dev/null)" = "success" ]; then
            log "  Removed orphan + data: $NAME ($REASON)"
            REMOVED=$((REMOVED + 1))
        else
            log "  ERROR: Failed to remove '$NAME'"
            FAILED=$((FAILED + 1))
        fi
    fi
done < "$TMPFILE"

log "Done: removed=$REMOVED skipped=$SKIPPED kept=$KEPT failed=$FAILED"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
