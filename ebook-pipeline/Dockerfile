FROM debian:bookworm-slim

# Calibre's official installer ships its own bundled Qt runtime built against
# glibc — this is why this service is Debian-based rather than joining the
# Alpine (musl) cron container: Calibre on Alpine is a real compatibility risk.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        curl \
        jq \
        ca-certificates \
        cron \
        xz-utils \
        xvfb \
        libxrender1 \
        libxext6 \
        libgl1 \
        libegl1 \
        libnss3 \
        libfontconfig1 \
        libxkbcommon0 \
        libxkbcommon-x11-0 \
        libxcb-cursor0 \
        fonts-liberation \
    && curl -fsSL https://download.calibre-ebook.com/linux-installer.sh -o /tmp/calibre-installer.sh \
    && bash /tmp/calibre-installer.sh \
    && rm -f /tmp/calibre-installer.sh \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/log/cron /scripts

COPY ebook-pipeline/crontab /etc/cron.d/ebook-pipeline
RUN chmod 0644 /etc/cron.d/ebook-pipeline && crontab /etc/cron.d/ebook-pipeline

COPY ebook-pipeline/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
