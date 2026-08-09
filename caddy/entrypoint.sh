#!/bin/sh
# Download GeoLite2 database if not present, then start Caddy
set -e

DB_FILE="/data/geolite2/GeoLite2-Country.mmdb"

# A file that merely *exists* isn't enough to trust: on a persistent
# /data volume, a leftover empty or truncated file from an interrupted
# download (including from before this validation existed at all) would
# otherwise pass a bare `-f` check and either skip re-downloading a real
# database, or let a "successful" downloader's claim go unverified. Every
# real GeoLite2-Country.mmdb contains this MaxMind DB format marker, so
# checking for it (plus non-zero size) is a cheap, meaningful floor above
# "the path exists" without needing a full MMDB parser.
#
# Verified directly against the live production database: busybox/Alpine
# `grep -a` fails to find this marker in the real binary file (likely
# tripped up by embedded NUL bytes), even though the string genuinely is
# present - `strings` extracts the printable runs first, then a plain
# `grep` on that text output finds it reliably. Confirmed this matches
# between GNU grep/strings (this dev machine) and the actual busybox
# build running in the caddy container - do not simplify back to a bare
# `grep -a` on the binary file.
is_valid_geodb() {
    [ -s "$1" ] && strings "$1" | grep -q 'MaxMind.com'
}

if ! is_valid_geodb "$DB_FILE"; then
    echo "GeoLite2 database missing or invalid, downloading..."
    /usr/local/bin/download-geodb.sh
fi

# Independent re-check, not just trusting download-geodb.sh's exit code:
# this is the fail-closed guarantee's actual enforcement point, so it must
# not rely solely on the downloader behaving correctly (now, or in some
# future edit) - if it ever reports success without a real database
# actually present, Caddy must still refuse to start without GeoIP
# protection.
if ! is_valid_geodb "$DB_FILE"; then
    echo "ERROR: GeoLite2 database still missing or invalid after download attempt - refusing to start Caddy without GeoIP protection" >&2
    exit 1
fi

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
