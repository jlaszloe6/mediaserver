#!/bin/sh
# Download GeoLite2 database if not present, then start Caddy
set -e

DB_FILE="/data/geolite2/GeoLite2-Country.mmdb"

if [ ! -f "$DB_FILE" ]; then
    echo "GeoLite2 database not found, downloading..."
    /usr/local/bin/download-geodb.sh
fi

# Independent re-check, not just trusting download-geodb.sh's exit code:
# this is the fail-closed guarantee's actual enforcement point, so it must
# not rely solely on the downloader behaving correctly (now, or in some
# future edit) - if it ever reports success without the file actually
# existing, Caddy must still refuse to start without GeoIP protection.
if [ ! -f "$DB_FILE" ]; then
    echo "ERROR: GeoLite2 database still missing after download attempt - refusing to start Caddy without GeoIP protection" >&2
    exit 1
fi

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
