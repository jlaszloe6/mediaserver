import os
import sqlite3

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
            source_ip TEXT
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
            seerr_configured INTEGER DEFAULT 1
        );
    """)
    # Idempotent migration: add source_ip if missing
    try:
        conn.execute("SELECT source_ip FROM login_tokens LIMIT 0")
    except sqlite3.OperationalError:
        conn.execute("ALTER TABLE login_tokens ADD COLUMN source_ip TEXT")
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
                seerr_configured INTEGER DEFAULT 1
            )
        """)
    # Idempotent migration: add seerr_configured if missing. Defaults existing
    # rows to 1 (assume configured) rather than 0 - we don't know their real
    # invite-time outcome, and the safer failure mode is still attempting a
    # Seerr lookup/delete (which itself already handles "not actually there"
    # gracefully) rather than silently skipping a cleanup that may be needed.
    try:
        conn.execute("SELECT seerr_configured FROM guests LIMIT 0")
    except sqlite3.OperationalError:
        conn.execute("ALTER TABLE guests ADD COLUMN seerr_configured INTEGER DEFAULT 1")
    conn.commit()
    conn.close()


def get_all_guest_emails():
    db = get_db()
    rows = db.execute("SELECT email FROM guests").fetchall()
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


def remove_guest(email):
    db = get_db()
    db.execute("DELETE FROM guests WHERE email = ?", (email.lower(),))
    db.commit()


def get_guest(email):
    db = get_db()
    row = db.execute(
        "SELECT email, jellyfin_username, invited_by, created_at, seerr_configured FROM guests WHERE email = ?",
        (email.lower(),),
    ).fetchone()
    return dict(row) if row else None


def get_guests():
    db = get_db()
    rows = db.execute(
        "SELECT email, jellyfin_username, invited_by, created_at, seerr_configured FROM guests ORDER BY created_at DESC"
    ).fetchall()
    return [dict(row) for row in rows]
