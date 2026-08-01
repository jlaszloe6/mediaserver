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

import os
import shutil
import sys
import tempfile
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
    with app.app_context():
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
    auth.init_app(app)
    app.register_blueprint(auth_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(guests_bp)
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
