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
        xauth \
        python3 \
        python-is-python3 \
        libxrender1 \
        libxext6 \
        libgl1 \
        libegl1 \
        libopengl0 \
        libnss3 \
        libfontconfig1 \
        libxkbcommon0 \
        libxkbcommon-x11-0 \
        libxcb-cursor0 \
        fonts-liberation \
        locales \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && curl -fsSL https://download.calibre-ebook.com/linux-installer.sh -o /tmp/calibre-installer.sh \
    && bash /tmp/calibre-installer.sh \
    && rm -f /tmp/calibre-installer.sh \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/log/cron /scripts

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
ENV PATH="/opt/calibre:${PATH}"

COPY ebook-pipeline/crontab /etc/cron.d/ebook-pipeline
# /etc/cron.d files need the user-field column and are picked up automatically
# by cron - do NOT also `crontab`-load this file into root's personal
# crontab, which uses the classic 5-field format with no user column and
# would misparse "root" as the command to run.
RUN chmod 0644 /etc/cron.d/ebook-pipeline

COPY ebook-pipeline/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
