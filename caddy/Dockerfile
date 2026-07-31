# caddy with duckdns DNS plugin and MaxMind GeoIP (pinned digests)
FROM caddy:2-builder@sha256:d4f984844fc3b867ac88fd814285a38eaaf5b3ecadb9ca1b3b0397182ef60cfe AS builder
# Pinned to specific tagged releases (was previously unpinned - always
# building against whatever each plugin's default branch HEAD was at
# build time) so an upstream change or compromise doesn't automatically
# flow into the next image build unreviewed.
RUN xcaddy build \
    --with github.com/caddy-dns/duckdns@v0.5.0 \
    --with github.com/porech/caddy-maxmind-geolocation@v1.0.3
FROM caddy:2@sha256:af5fdcd76f2db5e4e974ee92f96ee8c0fc3edb55bd4ba5032547cbf3f65e486d
RUN apk add --no-cache curl
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY download-geodb.sh /usr/local/bin/download-geodb.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/download-geodb.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
