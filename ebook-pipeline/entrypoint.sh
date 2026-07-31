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

# Run cron in foreground
exec cron -f
