FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    python3 \
    sqlite \
    coreutils \
    grep \
    && mkdir -p /var/log/cron /scripts

COPY cron/crontab /etc/crontabs/root
COPY cron/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
