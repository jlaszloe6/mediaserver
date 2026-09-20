import os
import re
import time

CRON_LOG_DIR = "/var/log/cron"

# (display name, log filename, expected cadence in minutes). Cadence must
# match cron/crontab exactly - this is what "overdue" is measured against.
CRON_JOBS = [
    ("jellyfin-cleanup.sh", "jellyfin-cleanup.log", 30),
    ("queue-cleanup.sh", "queue-cleanup.log", 30),
    ("jellyfin-watched-cleanup.sh", "jellyfin-watched-cleanup.log", 24 * 60),
    ("geodb-update.sh", "geodb-update.log", 7 * 24 * 60),
    ("jellyfin-scan.sh", "jellyfin-scan.log", 1),
    ("pipeline-monitor.sh", "pipeline-monitor.log", 30),
    ("subtitle-sync-check.sh", "subtitle-sync-check.log", 30),
    ("subtitle-preextract.sh", "subtitle-preextract.log", 1),
    ("backup.sh", "backup.log", 24 * 60),
    ("log-rotate.sh", "log-rotate.log", 24 * 60),
]

# Cron jitter plus this container's own clock/scan delay - a job isn't
# "overdue" just because it's a few minutes past its exact cadence. Applied
# as max(cadence * 2, cadence + STALE_GRACE_MINUTES) so both very frequent
# (1 min) and very infrequent (weekly) jobs get a sane grace window.
STALE_GRACE_MINUTES = 10


def _format_age(seconds):
    if seconds < 60:
        return "just now"
    minutes = int(seconds // 60)
    if minutes < 60:
        return f"{minutes}m ago"
    hours = minutes // 60
    if hours < 48:
        return f"{hours}h ago"
    return f"{hours // 24}d ago"


def fetch_cron_status():
    """Check each cron job's log file mtime against its expected cadence.

    This is deliberately mtime-based, not a separate status file the jobs
    write themselves: if the cron container itself is down (as happened for
    ~26h during this project's SSD migration, undetected the whole time),
    every job's log simply stops updating, which this catches directly -
    a job-authored "I'm fine" status file would go equally silent right
    along with it and prove nothing.
    """
    results = []
    for name, filename, cadence_minutes in CRON_JOBS:
        path = os.path.join(CRON_LOG_DIR, filename)
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            results.append({"name": name, "last_run": "never", "stale": True})
            continue
        age_seconds = time.time() - mtime
        grace_minutes = max(cadence_minutes * 2, cadence_minutes + STALE_GRACE_MINUTES)
        results.append({
            "name": name,
            "last_run": _format_age(age_seconds),
            "stale": age_seconds > grace_minutes * 60,
        })
    return results


_BACKUP_START_RE = re.compile(r"^\[(?P<ts>[\d-]+ [\d:]+)\] Starting backup")


def fetch_backup_status():
    """Parse backup.log's last run for success/failure.

    backup.sh runs under `set -euo pipefail` like every script in this repo
    - any unhandled error aborts the script immediately, so a run that
    didn't reach its own final "Backup complete" line simply never logs
    one. Success is "the last 'Starting backup' block is followed by a
    'Backup complete' line before EOF", not the mere presence of either
    line on its own.
    """
    path = os.path.join(CRON_LOG_DIR, "backup.log")
    try:
        with open(path, "r", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return {"last_run": "never", "ok": False}

    last_start_idx = None
    last_start_ts = None
    for i, line in enumerate(lines):
        m = _BACKUP_START_RE.match(line)
        if m:
            last_start_idx = i
            last_start_ts = m.group("ts")

    if last_start_idx is None:
        return {"last_run": "never", "ok": False}

    completed = any("Backup complete" in line for line in lines[last_start_idx:])
    return {"last_run": last_start_ts, "ok": completed}
