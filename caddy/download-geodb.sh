#!/bin/sh
# Download MaxMind GeoLite2-Country database
set -e

DB_DIR="/data/geolite2"
DB_FILE="$DB_DIR/GeoLite2-Country.mmdb"
ACCOUNT_ID="${MAXMIND_ACCOUNT_ID}"
LICENSE_KEY="${MAXMIND_LICENSE_KEY}"

mkdir -p "$DB_DIR"

URL="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${LICENSE_KEY}&suffix=tar.gz"

echo "Downloading GeoLite2-Country database..."
curl -sL "$URL" -o /tmp/geolite2.tar.gz
tar -xzf /tmp/geolite2.tar.gz -C /tmp
cp /tmp/GeoLite2-Country_*/GeoLite2-Country.mmdb "$DB_FILE"
rm -rf /tmp/geolite2.tar.gz /tmp/GeoLite2-Country_*
echo "GeoLite2-Country database updated at $DB_FILE"
