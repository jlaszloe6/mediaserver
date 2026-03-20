#!/bin/bash
# Scripts expect .env at $SCRIPT_DIR/../.env — symlink so /scripts/../.env works
ln -sf /config/.env /.env

# Load .env into environment for cron jobs
set -a
source /config/.env
set +a

# Write env vars to file so cron subprocesses inherit them
env | grep -v '^_=\|^PWD=\|^SHLVL=\|^HOSTNAME=' > /etc/environment

echo "$(date) Cron container started" >> /var/log/cron/cron.log

# Run crond in foreground
exec crond -f -l 2 -L /var/log/cron/cron.log
