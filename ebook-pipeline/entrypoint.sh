#!/bin/bash
# Unlike cron, this container is NOT given the whole .env - only the
# specific secrets scripts/ebook-pipeline.sh actually uses are passed in
# via docker-compose's `environment:` (it parses untrusted downloaded
# file content through Calibre, so it shouldn't have blast-radius access
# to every other service's credentials). scripts/ebook-pipeline.sh still
# expects to `source` a .env file at $SCRIPT_DIR/../.env though - write
# one out from the already-scoped environment docker-compose gave this
# container, rather than mounting/sourcing the real .env.
{
    for var in TZ SERVER_NAME ADMIN_EMAIL AUDIOBOOKSHELF_API_KEY \
               SMTP_SERVER SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_FROM; do
        printf '%s=%s\n' "$var" "${!var@Q}"
    done
} > /.env

# Write env vars to file so cron subprocesses inherit them
env | grep -v '^_=\|^PWD=\|^SHLVL=\|^HOSTNAME=' > /etc/environment

mkdir -p /var/log/cron
echo "$(date) Ebook pipeline container started" >> /var/log/cron/ebook-pipeline.log

# Volume may have been created (or left over from before this container ran
# jobs as non-root) with root ownership - fix it on every start so ebookjob
# can write logs, regardless of prior state. Safe/idempotent to always run.
# Must run AFTER the line above: that "started" message is written by this
# still-root entrypoint and would otherwise create the log file owned by
# root (undoing the chown for that specific file) if this ran first.
chown -R ebookjob:ebookjob /var/log/cron

# Run cron in foreground (stays root - it needs that to switch to ebookjob
# per-job per the crontab's user-field column; only the jobs it spawns run
# unprivileged)
exec cron -f
