import os
import sqlite3
from datetime import datetime, timedelta

from flask import g

from config import DB_PATH


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
    return g.db


def init_app(app):
    @app.teardown_appcontext
    def close_db(exc):
        db = g.pop("db", None)
        if db:
            db.close()


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            email TEXT PRIMARY KEY,
            last_login TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS login_tokens (
            token_hash TEXT PRIMARY KEY,
            email TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            used INTEGER DEFAULT 0,
            source_ip TEXT,
            created_at TEXT
        );
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_email TEXT NOT NULL,
            timestamp TEXT DEFAULT (datetime('now')),
            data_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS guests (
            email TEXT PRIMARY KEY,
            jellyfin_username TEXT NOT NULL,
            invited_by TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now')),
            seerr_configured INTEGER DEFAULT 1,
            revoked INTEGER DEFAULT 0
        );
    """)
    # Idempotent migration: add source_ip if missing
    try:
        conn.execute("SELECT source_ip FROM login_tokens LIMIT 0")
    except sqlite3.OperationalError:
        conn.execute("ALTER TABLE login_tokens ADD COLUMN source_ip TEXT")
    # Idempotent migration: add created_at if missing. No SQL-level DEFAULT
    # (unlike other tables' created_at columns) - it must be populated by the
    # application using the exact same "%Y-%m-%dT%H:%M:%SZ" format as
    # expires_at. Mixing that with SQLite's own datetime('now') format
    # (space-separated, no Z) reintroduces the lexicographic-comparison bug
    # already fixed once for cleanup_expired_tokens (see auth.py).
    try:
        conn.execute("SELECT created_at FROM login_tokens LIMIT 0")
    except sqlite3.OperationalError:
        conn.execute("ALTER TABLE login_tokens ADD COLUMN created_at TEXT")
        # Backfill existing rows (created_at otherwise NULL) from expires_at
        # minus the fixed 15-minute token lifetime, in the same format - a
        # NULL created_at would make is_rate_limited()'s new query silently
        # exclude every pre-migration token, letting anyone already at the
        # limit right before an upgrade get a free extra window right after.
        # Done in Python, not SQL: SQLite's own datetime() always returns its
        # own space-separated format regardless of input, which would
        # reintroduce the exact format mismatch this column exists to avoid.
        rows = conn.execute("SELECT token_hash, expires_at FROM login_tokens WHERE created_at IS NULL").fetchall()
        for token_hash, expires_at in rows:
            try:
                expires = datetime.strptime(expires_at, "%Y-%m-%dT%H:%M:%SZ")
            except ValueError:
                continue
            created = (expires - timedelta(minutes=15)).strftime("%Y-%m-%dT%H:%M:%SZ")
            conn.execute("UPDATE login_tokens SET created_at = ? WHERE token_hash = ?", (created, token_hash))
    # Idempotent migration: replace v1 guests table (had trakt/plex/wg columns)
    try:
        conn.execute("SELECT jellyfin_username FROM guests LIMIT 0")
    except sqlite3.OperationalError:
        conn.execute("DROP TABLE IF EXISTS guests")
        conn.execute("""
            CREATE TABLE guests (
                email TEXT PRIMARY KEY,
                jellyfin_username TEXT NOT NULL,
                invited_by TEXT NOT NULL,
                created_at TEXT DEFAULT (datetime('now')),
                seerr_configured INTEGER DEFAULT 1,
                revoked INTEGER DEFAULT 0
            )
        """)
    # Idempotent migration: add seerr_configured if missing. Existing rows
    # predate this tracking, so there's no real per-guest signal to use.
    # Tried inferring a default from whether SEERR_API_KEY happens to be
    # set *at migration time* - rejected, since that's a single, possibly
    # transient reading (a typo'd .env, a startup mid-troubleshooting) that
    # gets baked in permanently for every pre-existing row. Between the two
    # possible wrong defaults, this deployment's whole audit round has
    # consistently chosen to fail closed rather than fail open: defaulting
    # to 1 can block a legacy guest's removal until an admin investigates
    # (recoverable, and Jellyfin access is still correctly revoked either
    # way), where defaulting to 0 could silently leave a real orphaned
    # Seerr account while reporting "access revoked". See delete_seerr_user's
    # docstring for the seerr_configured=1 + no-key handling this relies on.
    try:
        conn.execute("SELECT seerr_configured FROM guests LIMIT 0")
    except sqlite3.OperationalError:
        conn.execute("ALTER TABLE guests ADD COLUMN seerr_configured INTEGER DEFAULT 1")
    # Idempotent migration: add revoked if missing. Existing rows default to
    # 0 (not revoked) - unlike seerr_configured, there's no ambiguity here:
    # a pre-existing guest simply hasn't been through the new revoke flow yet.
    try:
        conn.execute("SELECT revoked FROM guests LIMIT 0")
    except sqlite3.OperationalError:
        conn.execute("ALTER TABLE guests ADD COLUMN revoked INTEGER DEFAULT 0")
    conn.commit()
    conn.close()


def get_all_guest_emails():
    # Excludes revoked guests: a guest kept in the table after a partial
    # Jellyfin/Seerr cleanup failure (see revoke_guest/remove_guest below)
    # must not still count as "allowed" just because their row exists -
    # access is revoked immediately, independent of whether the external
    # cleanup has fully succeeded yet.
    db = get_db()
    rows = db.execute("SELECT email FROM guests WHERE revoked = 0").fetchall()
    return {row["email"] for row in rows}


def add_guest(email, jellyfin_username, invited_by, seerr_configured=True):
    db = get_db()
    try:
        db.execute(
            "INSERT INTO guests (email, jellyfin_username, invited_by, seerr_configured) VALUES (?, ?, ?, ?)",
            (email.lower(), jellyfin_username, invited_by, int(seerr_configured)),
        )
        db.commit()
        return True
    except sqlite3.IntegrityError:
        return False


def revoke_guest(email):
    """Mark a guest revoked without deleting their row. Cuts off status page
    access (see get_all_guest_emails) immediately, independent of whether
    the external Jellyfin/Seerr cleanup succeeds - call this before
    attempting that cleanup, not after, so access is never left active
    just because an external service was slow or down."""
    db = get_db()
    db.execute("UPDATE guests SET revoked = 1 WHERE email = ?", (email.lower(),))
    db.commit()


def remove_guest(email):
    db = get_db()
    db.execute("DELETE FROM guests WHERE email = ?", (email.lower(),))
    db.commit()


def get_guest(email):
    db = get_db()
    row = db.execute(
        "SELECT email, jellyfin_username, invited_by, created_at, seerr_configured, revoked FROM guests WHERE email = ?",
        (email.lower(),),
    ).fetchone()
    return dict(row) if row else None


def get_guests():
    db = get_db()
    rows = db.execute(
        "SELECT email, jellyfin_username, invited_by, created_at, seerr_configured, revoked FROM guests ORDER BY created_at DESC"
    ).fetchall()
    return [dict(row) for row in rows]
