# caddy with duckdns DNS plugin and MaxMind GeoIP (pinned digests)
FROM caddy:2-builder@sha256:3db11aead97f1fdff9c563d0dd8e7fba2e4c7031bef40f3e44fd1982f3e8366b AS builder
# Pinned to specific tagged releases (was previously unpinned - always
# building against whatever each plugin's default branch HEAD was at
# build time) so an upstream change or compromise doesn't automatically
# flow into the next image build unreviewed.
RUN xcaddy build \
    --with github.com/caddy-dns/duckdns@v0.5.0 \
    --with github.com/porech/caddy-maxmind-geolocation@v1.0.3
FROM caddy:2@sha256:ce773ec7a742ce15ee6bf2bb5f65882b9e2a4487b10733e6f1484f86e6b5d8bc
RUN apk add --no-cache curl
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY download-geodb.sh /usr/local/bin/download-geodb.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/download-geodb.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
