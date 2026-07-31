#!/bin/bash
# Scripts expect .env at $SCRIPT_DIR/../.env — symlink so /scripts/../.env works
ln -sf /config/.env /.env

# Load .env into environment for cron jobs
set -a
source /config/.env
set +a

# Write env vars to file so cron subprocesses inherit them
env | grep -v '^_=\|^PWD=\|^SHLVL=\|^HOSTNAME=' > /etc/environment

# These volumes may have been created (or left over from before jobs ran
# as non-root) with root ownership - fix it on every start so the cronjob
# user can write, regardless of prior state. Safe/idempotent to always run.
chown -R cronjob:cronjob /var/log/cron /var/tmp

echo "$(date) Cron container started" >> /var/log/cron/cron.log

# Run crond in foreground (stays root - it needs that to switch to cronjob
# per-job via /etc/crontabs/cronjob; only the jobs it spawns run
# unprivileged)
exec crond -f -l 2 -L /var/log/cron/cron.log
