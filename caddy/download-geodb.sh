#!/bin/sh
# Download MaxMind GeoLite2-Country database
#
# entrypoint.sh only calls this when $DB_FILE doesn't exist yet, and only
# starts Caddy afterward if it does - this is a fail-closed security
# control (no GeoIP filtering without a real database means Caddy must not
# start at all), so a partial/corrupt download must never leave anything
# at $DB_FILE that a later container restart would mistake for a valid,
# already-present database. Everything below downloads and extracts into
# temporary locations first; $DB_FILE is only ever written once, via a
# same-filesystem atomic rename, after the extracted .mmdb is confirmed
# present and non-empty.
set -e

DB_DIR="/data/geolite2"
DB_FILE="$DB_DIR/GeoLite2-Country.mmdb"
ACCOUNT_ID="${MAXMIND_ACCOUNT_ID}"
LICENSE_KEY="${MAXMIND_LICENSE_KEY}"

mkdir -p "$DB_DIR"

URL="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${LICENSE_KEY}&suffix=tar.gz"

TMP_ARCHIVE=$(mktemp)
# Explicitly reset before the trap is installed: an inherited environment
# variable named TMP_EXTRACT_DIR (however unlikely) must not be handed to
# `rm -rf` if the mktemp -d below fails before ever assigning it itself.
TMP_EXTRACT_DIR=""
# Trap installed right after the first tempfile exists, before attempting
# to create the second one below - if that second mktemp fails, set -e
# would otherwise exit before any trap was registered, leaking
# $TMP_ARCHIVE. $TMP_EXTRACT_DIR is safely empty at that point; `rm -rf
# ""` is a harmless no-op (verified directly), not an error.
cleanup() {
    rm -f "$TMP_ARCHIVE"
    rm -rf "$TMP_EXTRACT_DIR"
}
trap cleanup EXIT

# Created inside $DB_DIR itself (not /tmp) specifically so the final `mv`
# below is guaranteed to be a same-filesystem rename - atomic - rather
# than a cross-filesystem fallback copy that could itself be interrupted
# partway through.
TMP_EXTRACT_DIR=$(mktemp -d "${DB_DIR}/.download-XXXXXX")

echo "Downloading GeoLite2-Country database..."
# POSIX sh has no <(...) process substitution. A heredoc redirected onto a
# numbered fd gets us the same effect: curl's argv only ever shows
# --config /dev/fd/3, never the license key embedded in $URL.
exec 3<<EOF
url = "$URL"
EOF

# --fail: a non-2xx response (e.g. an expired license key) must be treated
# as a failure, not downloaded and extracted as if it were the real
# database.
# -w '%{http_code}': captured into HTTP_CODE regardless of --fail's own
# exit status - curl still reports the real status code it received even
# when --fail makes the overall command fail. That's what lets the error
# branch below tell an actual HTTP error (a real code came back) apart
# from a transport failure ("000" - no response was ever received at all,
# e.g. DNS failure or connection refused) instead of misreporting a
# timeout as if it were "HTTP 000". Verified this behavior directly
# against a real MaxMind-shaped failure and a genuinely unreachable host
# before relying on it here.
# --connect-timeout/--max-time: bound the request so a stalled connection
# can't hang container startup indefinitely.
# --retry/--retry-delay/--retry-connrefused: this is a plain idempotent
# GET, safe to retry a bounded number of times on transient network
# failures via curl's own retry mechanism rather than a hand-rolled loop.
if HTTP_CODE=$(curl -s --show-error --fail --location \
    --connect-timeout 10 --max-time 120 \
    --retry 3 --retry-delay 5 --retry-connrefused \
    --config /dev/fd/3 -o "$TMP_ARCHIVE" -w '%{http_code}'); then
    :
else
    CURL_EXIT=$?
    if [ "$HTTP_CODE" = "000" ] || [ -z "$HTTP_CODE" ]; then
        echo "ERROR: Failed to download GeoLite2-Country database (connection/transport error or timeout, curl exit $CURL_EXIT)" >&2
    else
        echo "ERROR: Failed to download GeoLite2-Country database (HTTP $HTTP_CODE)" >&2
    fi
    exit 1
fi

if [ ! -s "$TMP_ARCHIVE" ]; then
    echo "ERROR: Downloaded GeoLite2-Country archive is empty" >&2
    exit 1
fi

if ! tar -xzf "$TMP_ARCHIVE" -C "$TMP_EXTRACT_DIR"; then
    echo "ERROR: Downloaded GeoLite2-Country archive is not a valid gzip/tar file" >&2
    exit 1
fi

EXTRACTED_MMDB=$(find "$TMP_EXTRACT_DIR" -name 'GeoLite2-Country.mmdb' -type f | head -1)
if [ -z "$EXTRACTED_MMDB" ] || [ ! -s "$EXTRACTED_MMDB" ]; then
    echo "ERROR: Extracted archive does not contain a valid, non-empty GeoLite2-Country.mmdb" >&2
    exit 1
fi

# Same marker check entrypoint.sh uses to decide whether an existing
# $DB_FILE can be trusted - applied here too so a corrupt-but-non-empty
# extraction (truncated download, wrong file substituted upstream) can't
# get moved into place as if it were a real database. `strings | grep`,
# not `grep -a` directly on the binary - verified against the real
# production database that busybox/Alpine grep's `-a` mode misses this
# marker even though it's genuinely present; strings' text extraction
# finds it reliably.
if ! strings "$EXTRACTED_MMDB" | grep -q 'MaxMind.com'; then
    echo "ERROR: Extracted GeoLite2-Country.mmdb does not contain the expected MaxMind database marker" >&2
    exit 1
fi

# Same-filesystem rename (both under $DB_DIR) - atomic, so $DB_FILE only
# ever shows up as either fully absent or fully valid, never partial.
mv "$EXTRACTED_MMDB" "$DB_FILE"

echo "GeoLite2-Country database updated at $DB_FILE"
