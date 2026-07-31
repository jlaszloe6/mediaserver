#!/bin/bash
# Scripts expect .env at $SCRIPT_DIR/../.env - symlink so /scripts/../.env works
ln -sf /config/.env /.env

# Load .env into environment for cron jobs
set -a
source /config/.env
set +a

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
