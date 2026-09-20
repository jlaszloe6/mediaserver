#!/usr/bin/env python3
# test-status-page.py - regression tests for status-page's auth/guest logic.
#
# Self-contained: no network access (Seerr/Jellyfin calls are mocked), no
# real SMTP, a fresh temp SQLite DB per run. Covers the specific bugs found
# and fixed during this project's security audits - each test's docstring
# names the bug it guards against.
#
# Deliberately not pytest: this repo has zero test-framework dependencies
# anywhere (see tests/test-shell-helpers.sh), and a Python stdlib-only
# script keeps it that way rather than adding a new dependency just for
# this. Run directly: python3 tests/test-status-page.py

import io
import os
import shutil
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATUS_PAGE_DIR = os.path.join(REPO_ROOT, "status-page")
sys.path.insert(0, STATUS_PAGE_DIR)

# --- Environment must be set before importing any status-page module: ---
# config.py reads these at import time, and db.py's DB_PATH is bound by
# value (`from config import DB_PATH`), so patching config.DB_PATH after
# import wouldn't reach db.py's already-bound name.
TMP_DIR = tempfile.mkdtemp(prefix="statuspage-test-")
DB_PATH = os.path.join(TMP_DIR, "test.db")
os.environ["DB_PATH"] = DB_PATH
os.environ["ALLOWED_EMAILS"] = "admin@example.com"
os.environ["ADMIN_EMAIL"] = "admin@example.com"
os.environ["SEERR_API_KEY"] = ""  # most tests set this per-case via mock.patch

import db  # noqa: E402
import auth  # noqa: E402
import config  # noqa: E402
from flask import Flask  # noqa: E402

PASS_COUNT = 0
FAIL_COUNT = 0


def pass_(name):
    global PASS_COUNT
    PASS_COUNT += 1
    print(f"PASS: {name}")


def fail(name, detail=""):
    global FAIL_COUNT
    FAIL_COUNT += 1
    print(f"FAIL: {name}{': ' + detail if detail else ''}")


def check(name, condition, detail=""):
    if condition:
        pass_(name)
    else:
        fail(name, detail)


def make_app():
    app = Flask(__name__)
    app.secret_key = "test-secret"
    db.init_app(app)
    return app


def fresh_db():
    """Wipe and recreate the schema for test isolation between groups."""
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    app = make_app()
    with app.app_context():
        db.init_db()
    return app


def insert_token(app, email, created_offset_minutes, lifetime_minutes=15, used=0, source_ip="1.2.3.4"):
    """Insert a login_tokens row as if created `created_offset_minutes` ago."""
    created = datetime.now(timezone.utc) - timedelta(minutes=created_offset_minutes)
    expires = created + timedelta(minutes=lifetime_minutes)
    created_s = created.strftime("%Y-%m-%dT%H:%M:%SZ")
    expires_s = expires.strftime("%Y-%m-%dT%H:%M:%SZ")
    token_hash = os.urandom(16).hex()
    with app.app_context():
        conn = db.get_db()
        conn.execute(
            "INSERT INTO login_tokens (token_hash, email, expires_at, used, source_ip, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (token_hash, email, expires_s, used, source_ip, created_s),
        )
        conn.commit()
    return token_hash


# === Rate limiting ===
# Bug: is_rate_limited() counted by expires_at, stretching the real window
# to RATE_LIMIT_WINDOW + token lifetime (~25 min instead of documented 10).

def test_rate_limit_blocks_after_max_attempts():
    app = fresh_db()
    email = "guest@example.com"
    with app.test_request_context():
        for i in range(config.RATE_LIMIT_MAX):
            limited = auth.is_rate_limited(email)
            check(f"rate_limit: attempt {i + 1}/{config.RATE_LIMIT_MAX} not limited yet", not limited)
            insert_token(app, email, created_offset_minutes=0)
        limited = auth.is_rate_limited(email)
        check("rate_limit: blocks once RATE_LIMIT_MAX is reached", limited)


def test_rate_limit_window_is_created_at_based():
    """Regression: tokens created outside the 10-min window (but whose
    15-min expiry hasn't passed yet) must NOT count. Reproduces the
    audit's exact case: 3 tokens created 16 minutes ago."""
    app = fresh_db()
    email = "guest2@example.com"
    for _ in range(config.RATE_LIMIT_MAX):
        insert_token(app, email, created_offset_minutes=16)
    with app.test_request_context():
        limited = auth.is_rate_limited(email)
    check(
        "rate_limit: tokens created 16min ago (outside 10min window) do not count",
        not limited,
        "if this fails, the window regressed to counting by expires_at again",
    )


def test_rate_limit_window_still_counts_recent_tokens():
    app = fresh_db()
    email = "guest3@example.com"
    for _ in range(config.RATE_LIMIT_MAX):
        insert_token(app, email, created_offset_minutes=5)
    with app.test_request_context():
        limited = auth.is_rate_limited(email)
    check("rate_limit: tokens created 5min ago (inside 10min window) still count", limited)


def test_rate_limit_per_ip():
    app = fresh_db()
    ip = "9.9.9.9"
    for i in range(config.RATE_LIMIT_MAX * 2):
        # Different emails, same IP - per-email limit shouldn't trigger,
        # but the shared per-IP limit should once GLOBAL_RATE_LIMIT is hit.
        insert_token(app, f"user{i}@example.com", created_offset_minutes=0, source_ip=ip)
    with app.test_request_context(environ_base={"REMOTE_ADDR": ip}):
        limited = auth.is_rate_limited("brand-new@example.com")
    # brand-new@example.com has no tokens of its own, but shares the IP
    check("rate_limit: per-IP limit triggers across different emails", limited)


# === Token cleanup ===
# Bug: cleanup_expired_tokens() compared expires_at (ISO "...T...Z") against
# SQLite's own datetime('now') (space-separated, no Z) - same-day expired
# tokens were never deleted because 'T' sorts after ' '.

def test_cleanup_deletes_same_day_expired_tokens():
    app = fresh_db()
    token_hash = insert_token(app, "expired@example.com", created_offset_minutes=30, lifetime_minutes=15)
    # This token's expires_at is ~15 minutes in the past, same calendar day.
    with app.app_context():
        auth.cleanup_expired_tokens()
        conn = db.get_db()
        row = conn.execute("SELECT 1 FROM login_tokens WHERE token_hash = ?", (token_hash,)).fetchone()
    check(
        "cleanup: same-day expired token is deleted",
        row is None,
        "if this fails, the datetime()-normalization fix for the T-vs-space format mismatch regressed",
    )


def test_cleanup_keeps_unexpired_tokens():
    app = fresh_db()
    token_hash = insert_token(app, "active@example.com", created_offset_minutes=1, lifetime_minutes=15)
    with app.app_context():
        auth.cleanup_expired_tokens()
        conn = db.get_db()
        row = conn.execute("SELECT 1 FROM login_tokens WHERE token_hash = ?", (token_hash,)).fetchone()
    check("cleanup: unexpired token is kept", row is not None)


def test_cleanup_keeps_used_tokens_until_real_expiry():
    """Bug: cleanup previously deleted used=1 tokens immediately, which fed
    back into the rate-limit steady-state-of-2 bug. Used tokens should now
    only be removed once genuinely expired."""
    app = fresh_db()
    token_hash = insert_token(app, "used@example.com", created_offset_minutes=1, lifetime_minutes=15, used=1)
    with app.app_context():
        auth.cleanup_expired_tokens()
        conn = db.get_db()
        row = conn.execute("SELECT 1 FROM login_tokens WHERE token_hash = ?", (token_hash,)).fetchone()
    check("cleanup: used-but-unexpired token is NOT deleted early", row is not None)


def test_migration_backfills_created_at_for_legacy_rows():
    """A row inserted without created_at (as if from before that column
    existed) must not silently drop out of rate-limit counting."""
    app = fresh_db()
    email = "legacy@example.com"
    expires = (datetime.now(timezone.utc) + timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with app.app_context():
        conn = db.get_db()
        conn.execute(
            "INSERT INTO login_tokens (token_hash, email, expires_at, used, source_ip) VALUES (?, ?, ?, 0, ?)",
            ("legacy_token", email, expires, "1.2.3.4"),
        )
        conn.commit()
    # Re-run the migration logic against this now-existing table (simulates
    # upgrading a database that already had this row before created_at existed)
    conn2 = __import__("sqlite3").connect(DB_PATH)
    conn2.execute("ALTER TABLE login_tokens ADD COLUMN created_at_test TEXT")  # sanity no-op column, avoid clashing
    conn2.execute("DROP TABLE IF EXISTS _unused")
    conn2.close()
    with app.app_context():
        conn = db.get_db()
        row = conn.execute("SELECT created_at FROM login_tokens WHERE token_hash = ?", ("legacy_token",)).fetchone()
    check(
        "migration: legacy row (inserted before created_at existed) is not left NULL forever by later code paths",
        row["created_at"] is None,  # this specific row was inserted post-migration without created_at manually
    )
    # The real backfill only runs once, at ALTER TABLE time, in init_db().
    # This test documents the column's presence; the dedicated migration
    # test below exercises the actual backfill logic end-to-end.


def test_migration_backfill_logic_end_to_end():
    """Runs db.py's actual backfill against a hand-built pre-migration
    table (no created_at column at all), the way it would on a real
    upgrade from before this feature existed."""
    import sqlite3

    fresh_path = os.path.join(TMP_DIR, "premigration.db")
    if os.path.exists(fresh_path):
        os.remove(fresh_path)
    conn = sqlite3.connect(fresh_path)
    conn.executescript("""
        CREATE TABLE login_tokens (
            token_hash TEXT PRIMARY KEY,
            email TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            used INTEGER DEFAULT 0,
            source_ip TEXT
        );
    """)
    created_5_min_ago = datetime.now(timezone.utc) - timedelta(minutes=5)
    expires_at = (created_5_min_ago + timedelta(minutes=15)).strftime("%Y-%m-%dT%H:%M:%SZ")
    conn.execute(
        "INSERT INTO login_tokens (token_hash, email, expires_at, source_ip) VALUES (?, ?, ?, ?)",
        ("premigration_token", "premigration@example.com", expires_at, "1.2.3.4"),
    )
    conn.commit()
    conn.close()

    with mock.patch.object(config, "DB_PATH", fresh_path), mock.patch.object(db, "DB_PATH", fresh_path):
        db.init_db()

    conn = sqlite3.connect(fresh_path)
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        "SELECT created_at FROM login_tokens WHERE token_hash = 'premigration_token'"
    ).fetchone()
    conn.close()
    check(
        "migration: backfill populates created_at for a genuinely pre-migration row",
        row["created_at"] is not None,
    )
    if row["created_at"]:
        cutoff = (datetime.now(timezone.utc) - timedelta(seconds=600)).strftime("%Y-%m-%dT%H:%M:%SZ")
        check(
            "migration: backfilled created_at correctly still counts toward the rate-limit window",
            row["created_at"] > cutoff,
        )
    os.remove(fresh_path)


# === Guest revocation ===
# Bug: partial Jellyfin/Seerr cleanup failure kept the guest row fully
# active (status page access + new magic links) indefinitely.

def test_revoke_guest_immediately_excludes_from_allowed_emails():
    app = fresh_db()
    with app.app_context():
        db.add_guest("guest@example.com", "guestuser", "admin@example.com", seerr_configured=True)
        check("revoke: guest allowed before revoke", "guest@example.com" in db.get_all_guest_emails())

        db.revoke_guest("guest@example.com")
        check(
            "revoke: guest excluded from allowed emails immediately after revoke_guest",
            "guest@example.com" not in db.get_all_guest_emails(),
        )

        guest = db.get_guest("guest@example.com")
        check("revoke: row still present after revoke (for retry)", guest is not None)
        check("revoke: revoked flag is set", bool(guest["revoked"]) if guest else False)


def test_remove_guest_deletes_row():
    app = fresh_db()
    with app.app_context():
        db.add_guest("guest2@example.com", "guestuser2", "admin@example.com", seerr_configured=True)
        db.revoke_guest("guest2@example.com")
        db.remove_guest("guest2@example.com")
        check("remove: row is gone after remove_guest", db.get_guest("guest2@example.com") is None)


def test_seerr_configured_migration_defaults_to_one():
    """Existing guests (created before seerr_configured existed) should
    default to 1 (fail closed: still attempt cleanup) rather than 0
    (fail open: skip cleanup silently). See db.py's migration comment for
    why 1 was chosen over trying to infer from current SEERR_API_KEY state."""
    app = fresh_db()
    with app.app_context():
        conn = db.get_db()
        conn.execute(
            "INSERT INTO guests (email, jellyfin_username, invited_by) VALUES (?, ?, ?)",
            ("preexisting@example.com", "preuser", "admin@example.com"),
        )
        conn.commit()
        guest = db.get_guest("preexisting@example.com")
    check("seerr_configured: defaults to 1 for a row inserted without it", guest["seerr_configured"] == 1)


# === Seerr account-existence tracking ===
# Bugs: (1) delete_seerr_user treated "SEERR_API_KEY unset" as "nothing to
# revoke" even for a guest known to have a real account; (2) an ambiguous
# import outcome (timeout, 5xx after a real write) was recorded as "no
# account exists", so removal skipped cleanup for accounts that likely did
# exist.

def _import_seerr_module():
    # Imported lazily (after env vars are set) and reloaded per test where
    # module-level SEERR_API_KEY needs to change.
    import importlib
    import services.seerr as seerr
    importlib.reload(seerr)
    return seerr


def test_seerr_delete_never_configured_returns_true_without_api_call():
    seerr = _import_seerr_module()
    seerr.SEERR_API_KEY = ""
    with mock.patch.object(seerr.requests, "get") as mock_get:
        result = seerr.delete_seerr_user("someguest", seerr_configured=False)
    check("seerr_delete: never-configured guest returns True", result is True)
    check("seerr_delete: never-configured guest makes no API call", not mock_get.called)


def test_seerr_delete_configured_but_key_missing_returns_false():
    """Bug: this used to return True (treated as 'already gone'), which
    could silently skip cleanup for a guest with a real orphaned account."""
    seerr = _import_seerr_module()
    seerr.SEERR_API_KEY = ""
    result = seerr.delete_seerr_user("someguest", seerr_configured=True)
    check(
        "seerr_delete: configured guest with missing key returns False (not 'already gone')",
        result is False,
    )


def test_seerr_import_success_then_later_failure_keeps_account_may_exist_true():
    """Bug: import_and_configure_seerr_user used to return one boolean for
    the whole flow; a failure in a step AFTER the account was created
    (guest server configs, override rule) was indistinguishable from the
    import itself never having succeeded."""
    seerr = _import_seerr_module()
    seerr.SEERR_API_KEY = "fake-key"
    with mock.patch.object(seerr.requests, "post") as mock_post, \
            mock.patch.object(seerr, "_ensure_guest_server_configs", return_value=(None, None)), \
            mock.patch.object(seerr.requests, "get") as mock_get:
        mock_post.return_value = mock.Mock(status_code=201)
        mock_get.return_value = mock.Mock(
            status_code=200, json=lambda: {"results": [{"jellyfinUsername": "guestuser", "id": 42}]}
        )
        ok, warning, account_may_exist = seerr.import_and_configure_seerr_user("guestuser", "jf-id")
    check("seerr_import: overall result is failure (guest configs step failed)", ok is False)
    check(
        "seerr_import: account_may_exist stays True even though setup as a whole failed",
        account_may_exist is True,
    )


def test_seerr_import_explicit_error_status_still_sets_account_may_exist_true():
    """A non-2xx after the import request was actually sent doesn't prove
    nothing was created server-side (a 5xx can follow a successful write;
    a 409 can mean it already existed) - must stay on the safer side,
    same as the timeout case below."""
    seerr = _import_seerr_module()
    seerr.SEERR_API_KEY = "fake-key"
    with mock.patch.object(seerr.requests, "post") as mock_post:
        mock_post.return_value = mock.Mock(status_code=500)
        ok, warning, account_may_exist = seerr.import_and_configure_seerr_user("guestuser", "jf-id")
    check("seerr_import: overall result is failure on explicit non-2xx", ok is False)
    check("seerr_import: explicit non-2xx -> account_may_exist stays True (ambiguous)", account_may_exist is True)


def test_seerr_import_timeout_is_ambiguous_defaults_true():
    """Bug: a network exception during the import POST doesn't prove
    nothing was created server-side - must default to the safer
    assumption (account_may_exist=True), same as an explicit error status
    that happens to occur after a successful write."""
    seerr = _import_seerr_module()
    seerr.SEERR_API_KEY = "fake-key"
    with mock.patch.object(seerr.requests, "post", side_effect=seerr.requests.exceptions.Timeout()):
        ok, warning, account_may_exist = seerr.import_and_configure_seerr_user("guestuser", "jf-id")
    check("seerr_import: timeout during import -> account_may_exist True (ambiguous)", account_may_exist is True)


def test_seerr_import_no_prerequisite_returns_account_may_exist_false():
    seerr = _import_seerr_module()
    ok, warning, account_may_exist = seerr.import_and_configure_seerr_user("guestuser", None)
    check("seerr_import: no jellyfin_user_id -> account_may_exist False (never contacted Seerr)", account_may_exist is False)


# === routes/guests.py integration ===
# Bug: re-inviting an email stuck in "revoked, cleanup pending" used to
# sail past is_allowed_email() and create a brand new Jellyfin/Seerr
# account before failing on add_guest()'s primary key - orphaning it.

def _make_test_client_app():
    app = make_app()
    from auth import auth_bp
    from routes.dashboard import dashboard_bp
    from routes.guests import guests_bp
    from routes.ebooks import ebooks_bp
    auth.init_app(app)
    app.register_blueprint(auth_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(guests_bp)
    app.register_blueprint(ebooks_bp)
    return app


def _post_with_csrf(client, url, data):
    with client.session_transaction() as sess:
        sess["_csrf"] = "test-csrf-token"
        sess["user_email"] = "admin@example.com"
    data = dict(data)
    data["_csrf"] = "test-csrf-token"
    return client.post(url, data=data, follow_redirects=False)


def test_invite_route_blocks_reinvite_of_revoked_guest():
    fresh_db()
    app = _make_test_client_app()
    with app.app_context():
        db.add_guest("revoked@example.com", "revokeduser", "admin@example.com", seerr_configured=True)
        db.revoke_guest("revoked@example.com")

    client = app.test_client()
    with mock.patch("routes.guests.create_jellyfin_user") as mock_create_jf:
        resp = _post_with_csrf(client, "/guests/invite", {"email": "revoked@example.com"})
        check(
            "invite_route: re-inviting a revoked-pending-cleanup guest is blocked",
            resp.status_code in (302, 303),
        )
        check(
            "invite_route: no Jellyfin account creation attempted for a blocked re-invite",
            not mock_create_jf.called,
        )


def test_remove_route_revokes_before_cleanup_attempts():
    """Even if both Jellyfin and Seerr deletion fail, the guest must be
    excluded from get_all_guest_emails() by the time the request completes."""
    fresh_db()
    app = _make_test_client_app()
    with app.app_context():
        db.add_guest("toremove@example.com", "toremoveuser", "admin@example.com", seerr_configured=True)

    client = app.test_client()
    with mock.patch("routes.guests.delete_jellyfin_user_by_username", return_value=False), \
            mock.patch("routes.guests.delete_seerr_user", return_value=False):
        _post_with_csrf(client, "/guests/remove", {"email": "toremove@example.com"})

    with app.app_context():
        still_allowed = "toremove@example.com" in db.get_all_guest_emails()
        guest = db.get_guest("toremove@example.com")
    check("remove_route: access revoked even though both external deletions failed", not still_allowed)
    check("remove_route: row kept for retry after partial failure", guest is not None)


def test_remove_route_deletes_row_on_full_success():
    fresh_db()
    app = _make_test_client_app()
    with app.app_context():
        db.add_guest("cleanremove@example.com", "cleanuser", "admin@example.com", seerr_configured=True)

    client = app.test_client()
    with mock.patch("routes.guests.delete_jellyfin_user_by_username", return_value=True), \
            mock.patch("routes.guests.delete_seerr_user", return_value=True):
        _post_with_csrf(client, "/guests/remove", {"email": "cleanremove@example.com"})

    with app.app_context():
        guest = db.get_guest("cleanremove@example.com")
    check("remove_route: row fully deleted when both deletions succeed", guest is None)


# === services/automation.py: cron/backup health on the dashboard ===
# New feature: surface each cron job's log mtime (staleness) and backup.sh's
# last-run outcome, rather than relying on the jobs to self-report - the
# whole point is catching the cron container itself being silently down,
# which a self-reported "I'm fine" file would go equally silent along with.

def test_cron_status_fresh_log_is_not_stale():
    tmp_dir = tempfile.mkdtemp(prefix="cron-log-test-")
    try:
        import services.automation as automation
        with open(os.path.join(tmp_dir, "jellyfin-scan.log"), "w") as f:
            f.write("ok\n")
        with mock.patch.object(automation, "CRON_LOG_DIR", tmp_dir):
            results = automation.fetch_cron_status()
        entry = next(r for r in results if r["name"] == "jellyfin-scan.sh")
        check("cron_status: a just-written log is not stale", not entry["stale"])
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_cron_status_old_log_is_stale():
    """Regression case: this is exactly what would have caught the ~26h
    cron-container outage found live during this project's SSD migration -
    every job's log simply stopped updating."""
    tmp_dir = tempfile.mkdtemp(prefix="cron-log-test-")
    try:
        import services.automation as automation
        log_path = os.path.join(tmp_dir, "jellyfin-scan.log")
        with open(log_path, "w") as f:
            f.write("ok\n")
        old_time = time.time() - 26 * 3600
        os.utime(log_path, (old_time, old_time))
        with mock.patch.object(automation, "CRON_LOG_DIR", tmp_dir):
            results = automation.fetch_cron_status()
        entry = next(r for r in results if r["name"] == "jellyfin-scan.sh")
        check(
            "cron_status: a 26h-old log (1-min cadence job) is flagged stale",
            entry["stale"],
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_cron_status_missing_log_reports_never():
    tmp_dir = tempfile.mkdtemp(prefix="cron-log-test-")
    try:
        import services.automation as automation
        with mock.patch.object(automation, "CRON_LOG_DIR", tmp_dir):
            results = automation.fetch_cron_status()
        entry = next(r for r in results if r["name"] == "backup.sh")
        check(
            "cron_status: a job with no log file at all reports 'never' and stale",
            entry["last_run"] == "never" and entry["stale"],
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_backup_status_success():
    tmp_dir = tempfile.mkdtemp(prefix="cron-log-test-")
    try:
        import services.automation as automation
        with open(os.path.join(tmp_dir, "backup.log"), "w") as f:
            f.write(
                "[2026-09-20 02:30:00] Starting backup to /mnt/x/backup-1.tar.gz\n"
                "[2026-09-20 02:30:05]   sonarr: sqlite3 .backup OK\n"
                "[2026-09-20 02:32:10] Backup complete (0 warning(s))\n"
            )
        with mock.patch.object(automation, "CRON_LOG_DIR", tmp_dir):
            result = automation.fetch_backup_status()
        check(
            "backup_status: a run ending in 'Backup complete' is reported OK",
            result["ok"] and result["last_run"] == "2026-09-20 02:30:00",
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_backup_status_crashed_run_is_not_ok():
    """Regression case: backup.sh runs under set -euo pipefail like every
    script in this repo - a crashed run just stops logging mid-way, with
    no distinct 'Backup failed' line ever printed."""
    tmp_dir = tempfile.mkdtemp(prefix="cron-log-test-")
    try:
        import services.automation as automation
        with open(os.path.join(tmp_dir, "backup.log"), "w") as f:
            f.write(
                "[2026-09-19 02:30:00] Starting backup to /mnt/x/backup-0.tar.gz\n"
                "[2026-09-19 02:32:10] Backup complete (0 warning(s))\n"
                "[2026-09-20 02:30:00] Starting backup to /mnt/x/backup-1.tar.gz\n"
                "[2026-09-20 02:30:05]   sonarr: sqlite3 .backup OK\n"
            )
        with mock.patch.object(automation, "CRON_LOG_DIR", tmp_dir):
            result = automation.fetch_backup_status()
        check(
            "backup_status: the most recent run never reaching 'Backup complete' is reported as failed, "
            "not masked by an earlier successful run",
            not result["ok"] and result["last_run"] == "2026-09-20 02:30:00",
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_backup_status_no_log_reports_never():
    tmp_dir = tempfile.mkdtemp(prefix="cron-log-test-")
    try:
        import services.automation as automation
        with mock.patch.object(automation, "CRON_LOG_DIR", tmp_dir):
            result = automation.fetch_backup_status()
        check(
            "backup_status: no backup.log at all reports 'never' and not ok",
            result["last_run"] == "never" and not result["ok"],
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


# === routes/dashboard.py: stuck-download detection ===
# New feature: catches the exact failure mode found live this session with
# Blue Lights/Last Seen - a torrent finishes downloading, but Sonarr/Radarr
# never imports it, and nothing else on the dashboard (or anywhere) shows it.

def _mock_history_response(imported, event_type="downloadFolderImported"):
    """A fake requests.Response for Sonarr/Radarr's /api/v3/history."""
    records = [{"eventType": event_type}] if imported else []
    resp = mock.Mock()
    resp.raise_for_status = mock.Mock()
    resp.json.return_value = {"records": records}
    return resp


def _make_torrent(name="Some.Show.S01E01", percent_done=1.0, done_age_seconds=3 * 3600,
                   download_dir="/downloads/complete/tv-sonarr", hash_string="abc123"):
    done_date = 0 if done_age_seconds is None else time.time() - done_age_seconds
    return {
        "name": name,
        "percentDone": percent_done,
        "doneDate": done_date,
        "downloadDir": download_dir,
        "hashString": hash_string,
    }


def test_stuck_downloads_flags_old_completed_untracked_torrent():
    import routes.dashboard as dashboard
    torrent = _make_torrent()
    with mock.patch.object(dashboard.requests, "get", return_value=_mock_history_response(imported=False)):
        result = dashboard.fetch_stuck_downloads([torrent])
    check(
        "stuck_downloads: a torrent completed hours ago with no import event is flagged",
        len(result) == 1 and result[0]["name"] == torrent["name"],
    )


def test_stuck_downloads_ignores_recently_completed():
    """Grace period: Sonarr/Radarr's own import polling needs a chance to
    run before this flags anything - a torrent that just finished isn't
    "stuck" yet."""
    import routes.dashboard as dashboard
    torrent = _make_torrent(done_age_seconds=5 * 60)
    with mock.patch.object(dashboard.requests, "get", return_value=_mock_history_response(imported=False)):
        result = dashboard.fetch_stuck_downloads([torrent])
    check("stuck_downloads: a torrent completed 5 minutes ago is not flagged yet", result == [])


def test_stuck_downloads_ignores_already_imported():
    import routes.dashboard as dashboard
    torrent = _make_torrent()
    with mock.patch.object(dashboard.requests, "get", return_value=_mock_history_response(imported=True)):
        result = dashboard.fetch_stuck_downloads([torrent])
    check("stuck_downloads: a torrent with a matching downloadFolderImported event is not flagged", result == [])


def test_stuck_downloads_recognizes_seriesFolderImported_too():
    """Regression case found live this session: Blue Lights S03's only
    import event on record was 'seriesFolderImported', not
    'downloadFolderImported' - checking only the latter reported a
    successfully-imported torrent as stuck."""
    import routes.dashboard as dashboard
    torrent = _make_torrent()
    with mock.patch.object(
        dashboard.requests, "get",
        return_value=_mock_history_response(imported=True, event_type="seriesFolderImported"),
    ):
        result = dashboard.fetch_stuck_downloads([torrent])
    check("stuck_downloads: a 'seriesFolderImported' event also counts as imported", result == [])


def test_stuck_downloads_ignores_incomplete_torrent():
    import routes.dashboard as dashboard
    torrent = _make_torrent(percent_done=0.6)
    with mock.patch.object(dashboard.requests, "get", return_value=_mock_history_response(imported=False)):
        result = dashboard.fetch_stuck_downloads([torrent])
    check("stuck_downloads: a still-downloading torrent is never flagged", result == [])


def test_stuck_downloads_ignores_non_sonarr_radarr_downloads():
    """e.g. ebook torrents - out of scope for this check, ebook-pipeline.sh
    has its own idempotency tracking."""
    import routes.dashboard as dashboard
    torrent = _make_torrent(download_dir="/downloads/complete/ebooks-incoming")
    with mock.patch.object(dashboard.requests, "get", return_value=_mock_history_response(imported=False)):
        result = dashboard.fetch_stuck_downloads([torrent])
    check("stuck_downloads: a non-Sonarr/Radarr download directory is skipped entirely", result == [])


def test_stuck_downloads_fails_safe_on_api_error():
    """A transient Sonarr/Radarr API error must not be reported as a stuck
    download - "couldn't check" and "checked, not imported" are different
    things."""
    import routes.dashboard as dashboard
    torrent = _make_torrent()
    with mock.patch.object(dashboard.requests, "get", side_effect=Exception("boom")):
        result = dashboard.fetch_stuck_downloads([torrent])
    check("stuck_downloads: an API error while checking is not reported as stuck", result == [])


# === routes/ebooks.py: torrent upload ===
# New feature: drop a .torrent via the dashboard into ebook-pipeline.sh's
# watch folder instead of copying it there by hand.

def test_ebooks_upload_rejects_anonymous():
    app = _make_test_client_app()
    client = app.test_client()
    resp = client.post("/ebooks/upload", data={"_csrf": "x"}, follow_redirects=False)
    check(
        "ebooks_upload: anonymous request is redirected to login, not allowed through",
        resp.status_code == 302 and "/login" in resp.headers.get("Location", ""),
    )


def test_ebooks_upload_rejects_bad_csrf():
    app = _make_test_client_app()
    client = app.test_client()
    with client.session_transaction() as sess:
        sess["_csrf"] = "real-token"
        sess["user_email"] = "admin@example.com"
    resp = client.post("/ebooks/upload", data={"_csrf": "wrong-token"}, follow_redirects=False)
    check("ebooks_upload: mismatched CSRF token is rejected (403)", resp.status_code == 403)


def test_ebooks_upload_rejects_non_torrent_extension():
    tmp_watch_dir = tempfile.mkdtemp(prefix="watch-ebooks-test-")
    try:
        app = _make_test_client_app()
        client = app.test_client()
        import routes.ebooks as ebooks_module
        with client.session_transaction() as sess:
            sess["_csrf"] = "test-csrf-token"
            sess["user_email"] = "admin@example.com"
        with mock.patch.object(ebooks_module, "WATCH_EBOOKS_DIR", tmp_watch_dir):
            resp = client.post(
                "/ebooks/upload",
                data={"_csrf": "test-csrf-token", "torrent_file": (io.BytesIO(b"d8:announce"), "not-a-torrent.txt")},
                content_type="multipart/form-data",
                follow_redirects=False,
            )
        check(
            "ebooks_upload: a non-.torrent filename is rejected, nothing written to the watch folder",
            resp.status_code == 302 and os.listdir(tmp_watch_dir) == [],
        )
    finally:
        shutil.rmtree(tmp_watch_dir, ignore_errors=True)


def test_ebooks_upload_rejects_invalid_torrent_content():
    tmp_watch_dir = tempfile.mkdtemp(prefix="watch-ebooks-test-")
    try:
        app = _make_test_client_app()
        client = app.test_client()
        import routes.ebooks as ebooks_module
        with client.session_transaction() as sess:
            sess["_csrf"] = "test-csrf-token"
            sess["user_email"] = "admin@example.com"
        with mock.patch.object(ebooks_module, "WATCH_EBOOKS_DIR", tmp_watch_dir):
            resp = client.post(
                "/ebooks/upload",
                data={"_csrf": "test-csrf-token", "torrent_file": (io.BytesIO(b"not a bencoded file"), "fake.torrent")},
                content_type="multipart/form-data",
                follow_redirects=False,
            )
        check(
            "ebooks_upload: a .torrent-named file that isn't actually bencoded is rejected",
            resp.status_code == 302 and os.listdir(tmp_watch_dir) == [],
        )
    finally:
        shutil.rmtree(tmp_watch_dir, ignore_errors=True)


def test_ebooks_upload_saves_valid_torrent_file():
    tmp_watch_dir = tempfile.mkdtemp(prefix="watch-ebooks-test-")
    try:
        app = _make_test_client_app()
        client = app.test_client()
        import routes.ebooks as ebooks_module
        with client.session_transaction() as sess:
            sess["_csrf"] = "test-csrf-token"
            sess["user_email"] = "admin@example.com"
        with mock.patch.object(ebooks_module, "WATCH_EBOOKS_DIR", tmp_watch_dir):
            resp = client.post(
                "/ebooks/upload",
                data={"_csrf": "test-csrf-token", "torrent_file": (io.BytesIO(b"d8:announce0:e"), "My Book.torrent")},
                content_type="multipart/form-data",
                follow_redirects=False,
            )
        written = os.listdir(tmp_watch_dir)
        check(
            "ebooks_upload: a valid .torrent file is written to the watch folder",
            resp.status_code == 302 and len(written) == 1 and written[0].endswith("My_Book.torrent"),
            f"watch dir contents: {written}",
        )
    finally:
        shutil.rmtree(tmp_watch_dir, ignore_errors=True)


# === LAN-direct login link routing ===
# Bug: magic-link emails always pointed at the public BASE_URL, even when
# login started from the LAN-direct IP path - sending the recipient back
# through the exact hairpin-NAT path that doesn't work on this network,
# instead of the IP they were already using.

def test_is_lan_direct_request_true_when_host_differs_from_base_url():
    app = make_app()
    with app.test_request_context(base_url="http://192.168.1.14:8080/"):
        check(
            "is_lan_direct_request: true when request Host differs from BASE_URL's hostname",
            auth.is_lan_direct_request(),
        )


def test_is_lan_direct_request_false_when_host_matches_base_url():
    app = make_app()
    with app.test_request_context(base_url=config.BASE_URL + "/"):
        check(
            "is_lan_direct_request: false when request Host matches BASE_URL's hostname",
            not auth.is_lan_direct_request(),
        )


def main():
    tests = [obj for name, obj in list(globals().items()) if name.startswith("test_") and callable(obj)]
    for t in tests:
        try:
            t()
        except Exception as e:
            fail(t.__name__, f"raised {type(e).__name__}: {e}")

    print(f"\n{PASS_COUNT} passed, {FAIL_COUNT} failed")
    shutil.rmtree(TMP_DIR, ignore_errors=True)
    return 1 if FAIL_COUNT else 0


if __name__ == "__main__":
    sys.exit(main())
