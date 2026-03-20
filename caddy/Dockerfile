# caddy with duckdns DNS plugin and MaxMind GeoIP (pinned digests)
FROM caddy:2-builder@sha256:d4f984844fc3b867ac88fd814285a38eaaf5b3ecadb9ca1b3b0397182ef60cfe AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/duckdns \
    --with github.com/porech/caddy-maxmind-geolocation
FROM caddy:2
RUN apk add --no-cache curl
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY download-geodb.sh /usr/local/bin/download-geodb.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/download-geodb.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
