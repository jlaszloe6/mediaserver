# alpine 3.21
FROM alpine@sha256:bc21487101ae47172509130ee1092cc273a831968d64b617776d1f69c81e42ab

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    python3 \
    sqlite \
    coreutils \
    grep \
    openssl \
    && mkdir -p /var/log/cron /scripts

# Non-root user for actual job execution. crond itself still starts as
# root, which it needs in order to switch to this user per-job (crond reads
# /etc/crontabs/<username> and setuid()s to whichever user the filename
# names) - only the jobs it runs drop privileges, not the daemon.
ARG PUID=1000
ARG PGID=1000
RUN addgroup -g "$PGID" cronjob \
    && adduser -D -H -u "$PUID" -G cronjob cronjob

COPY cron/crontab /etc/crontabs/cronjob
COPY cron/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
