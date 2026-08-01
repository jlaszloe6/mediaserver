# debian bookworm-slim
FROM debian@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

# Non-root user for actual job execution (this container parses untrusted
# downloaded file content through Calibre - jobs should not run as root).
# The `cron` daemon itself still starts as root, which it needs in order to
# switch to this user per-job (see the crontab's user-field column below) -
# only the jobs it runs drop privileges, not the daemon.
ARG PUID=1000
ARG PGID=1000
RUN groupadd -g "$PGID" ebookjob \
    && useradd -M -u "$PUID" -g ebookjob -s /usr/sbin/nologin ebookjob

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
    # Verify the installer script itself against a known hash before
    # executing it - the installer already independently verifies the
    # actual Calibre tarball's signature over a separate HTTPS channel
    # (see check_signature()/download_tarball() in the script), but
    # nothing was pinning the outer script's own content.
    #
    # Deliberately NOT pinning to a specific Calibre version=X.Y.Z here:
    # tried it (9.12, the version this was originally tested against) and
    # the build broke a short time later with a 404 fetching that
    # version's signature file - calibre-ebook.com only retains signatures
    # for a limited window of past releases, so a hardcoded old version
    # can silently stop building. The installer's own signature check
    # already guarantees whatever version it does fetch is authentic.
    && curl -fsSL https://download.calibre-ebook.com/linux-installer.sh -o /tmp/calibre-installer.sh \
    && echo "5ae3933e8d0c484d8621ab8a169488e99735fe22a0cfc01536f260d2ce1a86e0  /tmp/calibre-installer.sh" | sha256sum -c - \
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
