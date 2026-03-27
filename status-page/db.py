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
            used INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_email TEXT NOT NULL,
            timestamp TEXT DEFAULT (datetime('now')),
            data_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS guests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL,
            trakt_username TEXT NOT NULL,
            invited_at TEXT DEFAULT (datetime('now')),
            active INTEGER DEFAULT 0,
            onboard_token TEXT,
            onboard_token_created_at TEXT,
            status TEXT DEFAULT 'pending_approval',
            jellyfin_user_id TEXT,
            trakt_device_data TEXT
        );
    """)
    # Migrate existing rows: add new columns if missing (idempotent)
    for col, typ, default in [
        ("onboard_token", "TEXT", None),
        ("onboard_token_created_at", "TEXT", None),
        ("status", "TEXT", "'complete'"),
        ("jellyfin_user_id", "TEXT", None),
        ("trakt_device_data", "TEXT", None),
    ]:
        try:
            default_clause = f" DEFAULT {default}" if default else ""
            conn.execute(f"ALTER TABLE guests ADD COLUMN {col} {typ}{default_clause}")
        except sqlite3.OperationalError:
            pass
    conn.commit()
    conn.close()
