#!/bin/sh
# Download GeoLite2 database if not present, then start Caddy
set -e

DB_FILE="/data/geolite2/GeoLite2-Country.mmdb"

if [ ! -f "$DB_FILE" ]; then
    echo "GeoLite2 database not found, downloading..."
    /usr/local/bin/download-geodb.sh
fi

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
