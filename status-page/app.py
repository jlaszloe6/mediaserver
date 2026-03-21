import hashlib
import json
import os
import secrets
import smtplib
import sqlite3
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from email.mime.text import MIMEText
from functools import wraps

import xml.etree.ElementTree as ET

import requests
from flask import (
    Flask,
    Response,
    abort,
    flash,
    g,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

app = Flask(__name__)
app.secret_key = os.environ["SECRET_KEY"]
app.config.update(
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
)

# Config
ALLOWED_EMAILS = [e.strip().lower() for e in os.environ.get("ALLOWED_EMAILS", "").split(",") if e.strip()]
ADMIN_EMAILS = [e.strip().lower() for e in os.environ.get("ADMIN_EMAILS", "").split(",") if e.strip()]
BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080")
DB_PATH = os.environ.get("DB_PATH", "/app/data/statuspage.db")
TRAKT_LOG = os.environ.get("TRAKT_LOG", "/tmp/trakt-sync.log")
GUEST_QUOTA_GB = int(os.environ.get("GUEST_QUOTA_GB", "100"))
ONBOARD_TOKEN_TTL_DAYS = int(os.environ.get("ONBOARD_TOKEN_TTL_DAYS", "7"))

# API endpoints (all on localhost since we're on host network)
SONARR_URL = "http://localhost:8989"
SONARR_KEY = os.environ.get("SONARR_API_KEY", "")
RADARR_URL = "http://localhost:7878"
RADARR_KEY = os.environ.get("RADARR_API_KEY", "")
PLEX_URL = "http://localhost:32400"
PLEX_TOKEN = os.environ.get("PLEX_TOKEN", "")
TRANSMISSION_URL = "http://localhost:9091/transmission/rpc"
PROWLARR_URL = "http://localhost:9696"
PROWLARR_KEY = os.environ.get("PROWLARR_API_KEY", "")
TAUTULLI_URL = "http://localhost:8181"
TAUTULLI_KEY = os.environ.get("TAUTULLI_API_KEY", "")
SEERR_URL = "http://localhost:5055"
UPTIME_KUMA_URL = "http://localhost:3001"

# Guest pipeline
SONARR_GUEST_URL = "http://localhost:8990"
SONARR_GUEST_KEY = os.environ.get("SONARR_GUEST_API_KEY", "")
RADARR_GUEST_URL = "http://localhost:7879"
RADARR_GUEST_KEY = os.environ.get("RADARR_GUEST_API_KEY", "")
SONARR_TRAKT_CLIENT_ID = os.environ.get("SONARR_TRAKT_CLIENT_ID", "")
RADARR_TRAKT_CLIENT_ID = os.environ.get("RADARR_TRAKT_CLIENT_ID", "")

# WireGuard (wg-easy API)
WG_EASY_URL = "http://localhost:51821"
WG_PASSWORD = os.environ.get("WG_PASSWORD", "")

# Cloudflare Turnstile
TURNSTILE_SITE_KEY = os.environ.get("TURNSTILE_SITE_KEY", "")
TURNSTILE_SECRET_KEY = os.environ.get("TURNSTILE_SECRET_KEY", "")

# SMTP
SMTP_SERVER = os.environ.get("SMTP_SERVER", "smtp-relay.brevo.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD", "")
SMTP_FROM = os.environ.get("SMTP_FROM", "")

# Rate limiting: {email: [(timestamp, ...), ...]}
_rate_limits = {}
RATE_LIMIT_MAX = 3
RATE_LIMIT_WINDOW = 600  # 10 minutes


def verify_turnstile(token):
    """Verify Cloudflare Turnstile response. Returns True if valid or if Turnstile is not configured."""
    if not TURNSTILE_SECRET_KEY:
        return True
    try:
        r = requests.post("https://challenges.cloudflare.com/turnstile/v0/siteverify",
                          data={"secret": TURNSTILE_SECRET_KEY, "response": token}, timeout=5)
        return r.json().get("success", False)
    except Exception:
        return False


@app.context_processor
def inject_turnstile():
    return {"turnstile_site_key": TURNSTILE_SITE_KEY}

API_TIMEOUT = 3


# --- Database ---

def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
    return g.db


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
            plex_shared INTEGER DEFAULT 0,
            trakt_device_data TEXT,
            wg_client_id TEXT
        );
    """)
    # Migrate existing rows: add new columns if missing (idempotent)
    for col, typ, default in [
        ("onboard_token", "TEXT", None),
        ("status", "TEXT", "'complete'"),
        ("plex_shared", "INTEGER", "1"),
        ("trakt_device_data", "TEXT", None),
        ("wg_client_id", "TEXT", None),
        ("onboard_token_created_at", "TEXT", None),
    ]:
        try:
            default_clause = f" DEFAULT {default}" if default else ""
            conn.execute(f"ALTER TABLE guests ADD COLUMN {col} {typ}{default_clause}")
        except sqlite3.OperationalError:
            pass
    conn.commit()
    conn.close()


# --- Auth helpers ---

def hash_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def is_rate_limited(email):
    now = time.time()
    key = email.lower()
    attempts = _rate_limits.get(key, [])
    attempts = [t for t in attempts if now - t < RATE_LIMIT_WINDOW]
    _rate_limits[key] = attempts
    return len(attempts) >= RATE_LIMIT_MAX


def record_attempt(email):
    key = email.lower()
    _rate_limits.setdefault(key, []).append(time.time())


def send_magic_link(email, token):
    link = f"{BASE_URL}/auth/{token}"
    msg = MIMEText(
        f"Click to log in to the Media Server Status Page:\n\n{link}\n\nThis link expires in 15 minutes.",
        "plain",
    )
    msg["Subject"] = "Status Page Login"
    msg["From"] = SMTP_FROM
    msg["To"] = email
    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as server:
        server.starttls()
        server.login(SMTP_USER, SMTP_PASSWORD)
        server.send_message(msg)


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user_email" not in session:
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


def generate_csrf():
    if "_csrf" not in session:
        session["_csrf"] = secrets.token_hex(16)
    return session["_csrf"]


def check_csrf():
    token = request.form.get("_csrf", "")
    return token and token == session.get("_csrf")


def _is_active_guest_email(email):
    try:
        conn = sqlite3.connect(DB_PATH)
        row = conn.execute("SELECT id FROM guests WHERE email = ? AND active = 1", (email.lower(),)).fetchone()
        conn.close()
        return row is not None
    except Exception:
        return False


def is_guest():
    email = session.get("user_email", "").lower()
    return email and email not in ALLOWED_EMAILS and _is_active_guest_email(email)


app.jinja_env.globals["csrf_token"] = generate_csrf


# --- API clients ---

def ping_service(name, url, timeout=API_TIMEOUT):
    try:
        r = requests.get(url, timeout=timeout)
        return {"name": name, "ok": r.status_code < 500}
    except Exception:
        return {"name": name, "ok": False}


def fetch_service_health():
    checks = [
        ("Plex", f"{PLEX_URL}/identity"),
        ("Sonarr", f"{SONARR_URL}/ping"),
        ("Radarr", f"{RADARR_URL}/ping"),
        ("Transmission", "http://localhost:9091/transmission/web/"),
        ("Prowlarr", f"{PROWLARR_URL}/ping"),
        ("Tautulli", f"{TAUTULLI_URL}/status"),
        ("Seerr", f"{SEERR_URL}/api/v1/status"),
        ("Uptime Kuma", f"{UPTIME_KUMA_URL}/api/entry-page"),
    ]
    if SONARR_GUEST_KEY:
        checks.append(("Sonarr-Guest", f"{SONARR_GUEST_URL}/ping"))
    if RADARR_GUEST_KEY:
        checks.append(("Radarr-Guest", f"{RADARR_GUEST_URL}/ping"))
    if WG_PASSWORD:
        checks.append(("WireGuard", f"{WG_EASY_URL}/"))
    results = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(ping_service, name, url): name for name, url in checks}
        for fut in as_completed(futs):
            results.append(fut.result())
    return sorted(results, key=lambda x: x["name"])


def fetch_sonarr_series():
    try:
        r = requests.get(f"{SONARR_URL}/api/v3/series", headers={"X-Api-Key": SONARR_KEY}, timeout=API_TIMEOUT)
        return r.json()
    except Exception:
        return None


def fetch_radarr_movies():
    try:
        r = requests.get(f"{RADARR_URL}/api/v3/movie", headers={"X-Api-Key": RADARR_KEY}, timeout=API_TIMEOUT)
        return r.json()
    except Exception:
        return None


def fetch_sonarr_history():
    try:
        since = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
        r = requests.get(
            f"{SONARR_URL}/api/v3/history/since",
            params={"date": since, "includeSeries": "true", "includeEpisode": "true"},
            headers={"X-Api-Key": SONARR_KEY},
            timeout=API_TIMEOUT,
        )
        return r.json()
    except Exception:
        return None


def fetch_radarr_history():
    try:
        since = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
        r = requests.get(
            f"{RADARR_URL}/api/v3/history/since",
            params={"date": since, "includeMovie": "true"},
            headers={"X-Api-Key": RADARR_KEY},
            timeout=API_TIMEOUT,
        )
        return r.json()
    except Exception:
        return None


def fetch_transmission_torrents():
    try:
        # First request to get session ID
        try:
            requests.post(TRANSMISSION_URL, timeout=API_TIMEOUT)
        except requests.exceptions.HTTPError:
            pass
        except Exception as e:
            # Extract session ID from 409 response
            if hasattr(e, "response"):
                sid = e.response.headers.get("X-Transmission-Session-Id")
            else:
                raise

        # Try getting session id from a raw request
        resp = requests.post(TRANSMISSION_URL, timeout=API_TIMEOUT)
        sid = resp.headers.get("X-Transmission-Session-Id", "")

        r = requests.post(
            TRANSMISSION_URL,
            headers={"X-Transmission-Session-Id": sid},
            json={
                "method": "torrent-get",
                "arguments": {
                    "fields": ["name", "percentDone", "rateDownload", "rateUpload", "eta", "status", "doneDate", "uploadRatio", "downloadDir", "isPrivate", "trackers"],
                },
            },
            timeout=API_TIMEOUT,
        )
        data = r.json()
        return data.get("arguments", {}).get("torrents", [])
    except Exception:
        return None


def fetch_guest_series():
    try:
        r = requests.get(f"{SONARR_GUEST_URL}/api/v3/series", headers={"X-Api-Key": SONARR_GUEST_KEY}, timeout=API_TIMEOUT)
        return r.json()
    except Exception:
        return None


def fetch_guest_movies():
    try:
        r = requests.get(f"{RADARR_GUEST_URL}/api/v3/movie", headers={"X-Api-Key": RADARR_GUEST_KEY}, timeout=API_TIMEOUT)
        return r.json()
    except Exception:
        return None


def fetch_guest_sonarr_history():
    try:
        since = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
        r = requests.get(
            f"{SONARR_GUEST_URL}/api/v3/history/since",
            params={"date": since, "includeSeries": "true", "includeEpisode": "true"},
            headers={"X-Api-Key": SONARR_GUEST_KEY}, timeout=API_TIMEOUT,
        )
        return r.json()
    except Exception:
        return None


def fetch_guest_radarr_history():
    try:
        since = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
        r = requests.get(
            f"{RADARR_GUEST_URL}/api/v3/history/since",
            params={"date": since, "includeMovie": "true"},
            headers={"X-Api-Key": RADARR_GUEST_KEY}, timeout=API_TIMEOUT,
        )
        return r.json()
    except Exception:
        return None


def fetch_guest_quota_usage():
    """Return guest storage usage in bytes by querying guest Radarr/Sonarr."""
    total = 0
    try:
        r = requests.get(f"{RADARR_GUEST_URL}/api/v3/movie", headers={"X-Api-Key": RADARR_GUEST_KEY}, timeout=API_TIMEOUT)
        for m in r.json():
            total += m.get("sizeOnDisk", 0)
    except Exception:
        pass
    try:
        r = requests.get(f"{SONARR_GUEST_URL}/api/v3/series", headers={"X-Api-Key": SONARR_GUEST_KEY}, timeout=API_TIMEOUT)
        for s in r.json():
            total += s.get("statistics", {}).get("sizeOnDisk", 0)
    except Exception:
        pass
    return total


def fetch_trakt_log():
    try:
        if not os.path.exists(TRAKT_LOG):
            return None
        with open(TRAKT_LOG) as f:
            lines = f.readlines()
        # Return last 30 lines
        return "".join(lines[-30:])
    except Exception:
        return None


# --- Snapshot logic ---

def build_snapshot(series, movies):
    data = {"movies": [], "series": []}
    if movies:
        for m in movies:
            data["movies"].append({"id": m.get("id"), "title": m.get("title"), "tmdbId": m.get("tmdbId")})
    if series:
        for s in series:
            data["series"].append({"id": s.get("id"), "title": s.get("title"), "tvdbId": s.get("tvdbId")})
    return data


def save_snapshot(email, data):
    db = get_db()
    db.execute("INSERT INTO snapshots (user_email, data_json) VALUES (?, ?)", (email, json.dumps(data)))
    # Keep only last 10
    db.execute("""
        DELETE FROM snapshots WHERE user_email = ? AND id NOT IN (
            SELECT id FROM snapshots WHERE user_email = ? ORDER BY id DESC LIMIT 10
        )
    """, (email, email))
    db.commit()


def get_previous_snapshot(email):
    db = get_db()
    row = db.execute(
        "SELECT data_json, timestamp FROM snapshots WHERE user_email = ? ORDER BY id DESC LIMIT 1",
        (email,),
    ).fetchone()
    if row:
        return json.loads(row["data_json"]), row["timestamp"]
    return None, None


def compute_diff(old_data, new_data):
    diff = {"added_movies": [], "removed_movies": [], "added_series": [], "removed_series": []}
    if not old_data:
        return diff

    old_movie_ids = {m["id"] for m in old_data.get("movies", [])}
    new_movie_ids = {m["id"] for m in new_data.get("movies", [])}
    old_movie_map = {m["id"]: m["title"] for m in old_data.get("movies", [])}
    new_movie_map = {m["id"]: m["title"] for m in new_data.get("movies", [])}

    for mid in new_movie_ids - old_movie_ids:
        diff["added_movies"].append(new_movie_map.get(mid, "Unknown"))
    for mid in old_movie_ids - new_movie_ids:
        diff["removed_movies"].append(old_movie_map.get(mid, "Unknown"))

    old_series_ids = {s["id"] for s in old_data.get("series", [])}
    new_series_ids = {s["id"] for s in new_data.get("series", [])}
    old_series_map = {s["id"]: s["title"] for s in old_data.get("series", [])}
    new_series_map = {s["id"]: s["title"] for s in new_data.get("series", [])}

    for sid in new_series_ids - old_series_ids:
        diff["added_series"].append(new_series_map.get(sid, "Unknown"))
    for sid in old_series_ids - new_series_ids:
        diff["removed_series"].append(old_series_map.get(sid, "Unknown"))

    return diff


# --- Routes ---

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if not check_csrf():
            abort(403)
        if not verify_turnstile(request.form.get("cf-turnstile-response", "")):
            flash("Verification failed. Please try again.", "error")
            return render_template("login.html")
        email = request.form.get("email", "").strip().lower()
        if not email:
            flash("Please enter your email.", "error")
            return render_template("login.html")

        if email not in ALLOWED_EMAILS and not _is_active_guest_email(email):
            # Don't reveal whether email is valid
            flash("If that email is registered, a login link has been sent.", "info")
            return render_template("login.html")

        if is_rate_limited(email):
            flash("Too many attempts. Please wait a few minutes.", "error")
            return render_template("login.html")

        record_attempt(email)

        token = secrets.token_urlsafe(32)
        token_h = hash_token(token)
        expires = (datetime.now(timezone.utc) + timedelta(minutes=15)).strftime("%Y-%m-%dT%H:%M:%SZ")

        db = get_db()
        db.execute("INSERT INTO login_tokens (token_hash, email, expires_at) VALUES (?, ?, ?)", (token_h, email, expires))
        db.commit()

        try:
            send_magic_link(email, token)
        except Exception as e:
            app.logger.error(f"Failed to send email: {e}")
            flash("Failed to send email. Please try again later.", "error")
            return render_template("login.html")

        flash("If that email is registered, a login link has been sent.", "info")
        return render_template("login.html")

    return render_template("login.html")


@app.route("/auth/<token>")
def auth(token):
    token_h = hash_token(token)
    db = get_db()
    row = db.execute("SELECT * FROM login_tokens WHERE token_hash = ?", (token_h,)).fetchone()

    if not row or row["used"]:
        flash("Invalid or expired link.", "error")
        return redirect(url_for("login"))

    expires = datetime.strptime(row["expires_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    if datetime.now(timezone.utc) > expires:
        flash("Link has expired. Please request a new one.", "error")
        return redirect(url_for("login"))

    # Mark token as used
    db.execute("UPDATE login_tokens SET used = 1 WHERE token_hash = ?", (token_h,))

    # Upsert user
    db.execute(
        "INSERT INTO users (email, last_login) VALUES (?, datetime('now')) ON CONFLICT(email) DO UPDATE SET last_login = datetime('now')",
        (row["email"],),
    )
    db.commit()

    session.permanent = True
    app.permanent_session_lifetime = timedelta(days=30)
    session["user_email"] = row["email"]
    # Regenerate CSRF on login
    session.pop("_csrf", None)

    return redirect(url_for("dashboard"))


@app.route("/send-guide", methods=["POST"])
@login_required
def send_guide():
    if not check_csrf():
        abort(403)
    email = session["user_email"]
    try:
        send_user_guide(email)
        flash("Quick Actions guide sent to your email.", "info")
    except Exception as e:
        app.logger.error(f"Failed to send guide: {e}")
        flash("Failed to send guide. Please try again later.", "error")
    return redirect(url_for("dashboard"))


def send_user_guide(email):
    html = """\
<html>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;">
<h1 style="color: #1a1a2e; border-bottom: 2px solid #e94560; padding-bottom: 10px;">Media Server Quick Actions</h1>

<h2 style="color: #16213e;">Adding Movies &amp; TV Shows</h2>
<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
<tr style="background: #f5f5f5;"><td style="padding: 10px; border: 1px solid #ddd;"><strong>Trakt Watchlist</strong> (recommended)</td><td style="padding: 10px; border: 1px solid #ddd;">Go to <a href="https://trakt.tv">trakt.tv</a> &rarr; search &rarr; click bookmark icon. Picked up within 1 hour.</td></tr>
<tr><td style="padding: 10px; border: 1px solid #ddd;"><strong>Seerr</strong></td><td style="padding: 10px; border: 1px solid #ddd;">Browse and request via the Seerr app. Sign in with your Plex account.</td></tr>
</table>

<h2 style="color: #16213e;">Removing Content</h2>
<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
<tr style="background: #f5f5f5;"><td style="padding: 10px; border: 1px solid #ddd;"><strong>Remove from Trakt</strong></td><td style="padding: 10px; border: 1px solid #ddd;">Remove from watchlist &rarr; auto-deleted within ~2 hours</td></tr>
<tr><td style="padding: 10px; border: 1px solid #ddd;"><strong>Delete from Plex</strong></td><td style="padding: 10px; border: 1px solid #ddd;">Three dots (&hellip;) &rarr; Delete. Cleaned up within 30 minutes.</td></tr>
</table>

<h2 style="color: #16213e;">Watching</h2>
<ul style="line-height: 1.8;">
<li><strong>Plex apps</strong> &mdash; Install on phone, TV, streaming device, or game console. Sign in with your Plex account.</li>
<li><strong>Web browser</strong> &mdash; Use the Plex web URL (ask your admin).</li>
<li><strong>Quality</strong> &mdash; Set the Plex player to <strong>Original</strong> quality for best results. This avoids buffering.</li>
<li><strong>Subtitles</strong> &mdash; Most downloads include English subtitles. Toggle them in the Plex player.</li>
</ul>

<h2 style="color: #16213e;">Good to Know</h2>
<ul style="line-height: 1.8;">
<li>Watched content is <strong>automatically removed after 30 days</strong> to free space.</li>
<li>Want to rewatch? Just add it to your Trakt watchlist again.</li>
<li>New releases download once a digital version is available (not while in theaters).</li>
<li>TV series: all existing episodes download, and new ones download as they air.</li>
</ul>

<hr style="border: none; border-top: 1px solid #ddd; margin: 20px 0;">
<p style="color: #888; font-size: 12px;">Sent from Media Server Status Page</p>
</body>
</html>"""

    msg = MIMEText(html, "html")
    msg["Subject"] = "Media Server - Quick Actions Guide"
    msg["From"] = SMTP_FROM
    msg["To"] = email
    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as server:
        server.starttls()
        server.login(SMTP_USER, SMTP_PASSWORD)
        server.send_message(msg)


@app.route("/logout")
def logout():
    session.clear()
    flash("Logged out.", "info")
    return redirect(url_for("login"))


HNR_HOURS = 72  # nCore H&R policy


def _format_torrents(raw_torrents, guest_only=False):
    """Format Transmission torrent data for display. If guest_only, filter to guest categories."""
    torrents = []
    now_ts = time.time()
    for t in (raw_torrents or []):
        if guest_only:
            dl_dir = t.get("downloadDir", "")
            if "guest-sonarr" not in dl_dir and "guest-radarr" not in dl_dir:
                continue
        status_map = {0: "Stopped", 1: "Queued", 2: "Verifying", 3: "Queued", 4: "Downloading", 5: "Queued", 6: "Seeding"}
        status_code = t.get("status")
        eta = t.get("eta", -1)
        ratio = t.get("uploadRatio", 0)
        done_date = t.get("doneDate", 0)
        is_private = t.get("isPrivate", False)

        # ETA (download remaining)
        if status_code == 6:
            eta_str = "-"
        elif eta > 0:
            eta_str = str(timedelta(seconds=eta))
        elif eta == 0:
            eta_str = "Done"
        else:
            eta_str = "-"

        # H&R remaining (only for private trackers with completed downloads)
        hnr_str = "-"
        if is_private and done_date and done_date > 0:
            seeded_secs = int(now_ts - done_date)
            required_secs = HNR_HOURS * 3600
            remaining = required_secs - seeded_secs
            if remaining > 0:
                hnr_str = str(timedelta(seconds=remaining))
            else:
                hnr_str = "Done"

        torrents.append({
            "name": t.get("name", "Unknown"),
            "percent": round(t.get("percentDone", 0) * 100, 1),
            "down": _format_speed(t.get("rateDownload", 0)),
            "up": _format_speed(t.get("rateUpload", 0)),
            "eta": eta_str,
            "status": status_map.get(status_code, "Unknown"),
            "hnr": hnr_str,
            "ratio": f"{ratio:.2f}",
        })
    return torrents


def _format_activity(sonarr_history, radarr_history):
    """Format Sonarr/Radarr history into activity list."""
    activity = []
    for item in (sonarr_history or []):
        series_title = item.get("series", {}).get("title", "Unknown")
        ep = item.get("episode", {})
        ep_label = f"S{ep.get('seasonNumber', 0):02d}E{ep.get('episodeNumber', 0):02d}" if ep else ""
        activity.append({
            "time": item.get("date", ""),
            "type": "tv",
            "title": f"{series_title} {ep_label}".strip(),
            "event": item.get("eventType", ""),
        })
    for item in (radarr_history or []):
        activity.append({
            "time": item.get("date", ""),
            "type": "movie",
            "title": item.get("movie", {}).get("title", item.get("sourceTitle", "Unknown")),
            "event": item.get("eventType", ""),
        })
    activity.sort(key=lambda x: x["time"], reverse=True)
    return activity


@app.route("/")
@login_required
def dashboard():
    email = session["user_email"]
    guest_view = is_guest()

    if guest_view:
        return _guest_dashboard(email)
    return _owner_dashboard(email)


def _owner_dashboard(email):
    results = {}
    with ThreadPoolExecutor(max_workers=8) as ex:
        futures = {
            ex.submit(fetch_service_health): "health",
            ex.submit(fetch_sonarr_series): "series",
            ex.submit(fetch_radarr_movies): "movies",
            ex.submit(fetch_sonarr_history): "sonarr_history",
            ex.submit(fetch_radarr_history): "radarr_history",
            ex.submit(fetch_transmission_torrents): "torrents",
            ex.submit(fetch_trakt_log): "trakt_log",
        }
        for fut in as_completed(futures):
            key = futures[fut]
            try:
                results[key] = fut.result()
            except Exception:
                results[key] = None

    series = results.get("series") or []
    movies = results.get("movies") or []
    total_episodes = sum(s.get("statistics", {}).get("episodeFileCount", 0) for s in series)

    snapshot = build_snapshot(series, movies)
    prev_snapshot, prev_timestamp = get_previous_snapshot(email)
    diff = compute_diff(prev_snapshot, snapshot)
    save_snapshot(email, snapshot)

    return render_template(
        "dashboard.html",
        health=results.get("health") or [],
        movie_count=len(movies),
        series_count=len(series),
        episode_count=total_episodes,
        torrents=_format_torrents(results.get("torrents")),
        activity=_format_activity(results.get("sonarr_history"), results.get("radarr_history"))[:20],
        diff=diff,
        prev_timestamp=prev_timestamp,
        trakt_log=results.get("trakt_log"),
        is_admin=is_admin(),
        is_guest=False,
    )


def _guest_dashboard(email):
    results = {}
    with ThreadPoolExecutor(max_workers=8) as ex:
        futures = {
            ex.submit(fetch_service_health): "health",
            ex.submit(fetch_guest_series): "series",
            ex.submit(fetch_guest_movies): "movies",
            ex.submit(fetch_guest_sonarr_history): "sonarr_history",
            ex.submit(fetch_guest_radarr_history): "radarr_history",
            ex.submit(fetch_transmission_torrents): "torrents",
            ex.submit(fetch_guest_quota_usage): "quota_usage",
        }
        for fut in as_completed(futures):
            key = futures[fut]
            try:
                results[key] = fut.result()
            except Exception:
                results[key] = None

    series = results.get("series") or []
    movies = results.get("movies") or []
    total_episodes = sum(s.get("statistics", {}).get("episodeFileCount", 0) for s in series)

    snapshot = build_snapshot(series, movies)
    prev_snapshot, prev_timestamp = get_previous_snapshot(email)
    diff = compute_diff(prev_snapshot, snapshot)
    save_snapshot(email, snapshot)

    quota_usage = results.get("quota_usage") or 0
    quota_gb_used = round(quota_usage / 1073741824, 1)

    return render_template(
        "dashboard.html",
        health=results.get("health") or [],
        movie_count=len(movies),
        series_count=len(series),
        episode_count=total_episodes,
        torrents=_format_torrents(results.get("torrents"), guest_only=True),
        activity=_format_activity(results.get("sonarr_history"), results.get("radarr_history"))[:20],
        diff=diff,
        prev_timestamp=prev_timestamp,
        trakt_log=None,
        is_admin=is_admin(),
        is_guest=True,
        quota_gb_used=quota_gb_used,
        quota_gb_total=GUEST_QUOTA_GB,
    )


def is_admin():
    return session.get("user_email", "").lower() in ADMIN_EMAILS


def admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user_email" not in session:
            return redirect(url_for("login"))
        if not is_admin():
            abort(403)
        return f(*args, **kwargs)
    return decorated


def _format_speed(bps):
    if bps == 0:
        return "-"
    kbps = bps / 1024
    if kbps > 1024:
        return f"{kbps/1024:.1f} MB/s"
    return f"{kbps:.0f} KB/s"


# --- Guest Onboarding (self-service) ---

TRAKT_API_BASE = "https://api.trakt.tv"


def _send_email(to, subject, html):
    msg = MIMEText(html, "html")
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM
    msg["To"] = to
    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as server:
        server.starttls()
        server.login(SMTP_USER, SMTP_PASSWORD)
        server.send_message(msg)


def _get_guest_by_token(token):
    db = get_db()
    guest = db.execute("SELECT * FROM guests WHERE onboard_token = ?", (token,)).fetchone()
    if not guest:
        return None
    created_at = guest["onboard_token_created_at"]
    if created_at:
        token_time = datetime.fromisoformat(created_at).replace(tzinfo=timezone.utc)
        if datetime.now(timezone.utc) - token_time > timedelta(days=ONBOARD_TOKEN_TTL_DAYS):
            return None
    return guest


def _create_sonarr_import_list(trakt_username, access_token, refresh_token, expires_iso):
    payload = {
        "enableAutomaticAdd": True, "searchForMissingEpisodes": True,
        "shouldMonitor": "all", "monitorNewItems": "all",
        "rootFolderPath": "/data/media/guest-tv", "qualityProfileId": 1,
        "seriesType": "standard", "seasonFolder": True,
        "name": f"Trakt - {trakt_username}",
        "implementation": "TraktUserImport", "configContract": "TraktUserSettings", "listType": "trakt",
        "fields": [
            {"name": "accessToken", "value": access_token},
            {"name": "refreshToken", "value": refresh_token},
            {"name": "expires", "value": expires_iso},
            {"name": "authUser", "value": trakt_username},
            {"name": "traktListType", "value": 0},
            {"name": "username", "value": ""}, {"name": "limit", "value": 100},
        ], "tags": [],
    }
    r = requests.post(
        f"{SONARR_GUEST_URL}/api/v3/importlist?forceSave=true",
        headers={"X-Api-Key": SONARR_GUEST_KEY, "Content-Type": "application/json"},
        json=payload, timeout=10,
    )
    if r.status_code not in (200, 201):
        raise RuntimeError(f"Sonarr: HTTP {r.status_code}")


def _create_radarr_import_list(trakt_username, access_token, refresh_token, expires_iso):
    payload = {
        "enabled": True, "enableAuto": True, "monitor": "movieOnly",
        "rootFolderPath": "/data/media/guest-movies", "qualityProfileId": 1,
        "searchOnAdd": True, "minimumAvailability": "released",
        "name": f"Trakt - {trakt_username}",
        "implementation": "TraktUserImport", "configContract": "TraktUserSettings", "listType": "trakt",
        "fields": [
            {"name": "accessToken", "value": access_token},
            {"name": "refreshToken", "value": refresh_token},
            {"name": "expires", "value": expires_iso},
            {"name": "authUser", "value": trakt_username},
            {"name": "traktListType", "value": 0},
            {"name": "username", "value": ""}, {"name": "limit", "value": 100},
        ], "tags": [],
    }
    r = requests.post(
        f"{RADARR_GUEST_URL}/api/v3/importlist?forceSave=true",
        headers={"X-Api-Key": RADARR_GUEST_KEY, "Content-Type": "application/json"},
        json=payload, timeout=10,
    )
    if r.status_code not in (200, 201):
        raise RuntimeError(f"Radarr: HTTP {r.status_code}")


def share_plex_guest_libraries(guest_email):
    """Invite a Plex user and share only Guest TV / Guest Movies libraries via plex.tv API."""
    if not PLEX_TOKEN:
        raise RuntimeError("PLEX_TOKEN not configured")

    machine_id = ET.fromstring(
        requests.get(f"{PLEX_URL}/identity", params={"X-Plex-Token": PLEX_TOKEN}, timeout=API_TIMEOUT).text
    ).get("machineIdentifier")
    if not machine_id:
        raise RuntimeError("Could not get Plex machine identifier")

    # Get section IDs from plex.tv (different from local keys)
    server_root = ET.fromstring(
        requests.get(
            f"https://plex.tv/api/servers/{machine_id}",
            params={"X-Plex-Token": PLEX_TOKEN},
            headers={"X-Plex-Client-Identifier": "mediaserver-statuspage"},
            timeout=API_TIMEOUT,
        ).text
    )
    guest_section_ids = []
    for server in server_root.findall("Server"):
        for section in server.findall("Section"):
            if section.get("title") in ("Guest TV", "Guest Movies"):
                guest_section_ids.append(int(section.get("id")))
    if not guest_section_ids:
        raise RuntimeError("Guest TV / Guest Movies libraries not found on plex.tv")

    r = requests.post(
        f"https://plex.tv/api/servers/{machine_id}/shared_servers",
        params={"X-Plex-Token": PLEX_TOKEN},
        headers={"Content-Type": "application/json", "X-Plex-Client-Identifier": "mediaserver-statuspage"},
        json={
            "server_id": machine_id,
            "shared_server": {
                "library_section_ids": guest_section_ids,
                "invited_email": guest_email,
                "sharing_settings": {},
            },
        },
        timeout=15,
    )
    if r.status_code in (200, 201):
        app.logger.info(f"Shared Plex guest libraries with {guest_email}")
    elif "already" in r.text.lower():
        app.logger.info(f"Plex libraries already shared with {guest_email}")
    else:
        raise RuntimeError(f"Plex sharing API returned HTTP {r.status_code}: {r.text[:200]}")


def _wg_easy_session():
    """Get an authenticated session for wg-easy API."""
    s = requests.Session()
    r = s.post(f"{WG_EASY_URL}/api/session", json={"password": WG_PASSWORD}, timeout=5)
    r.raise_for_status()
    return s


def create_wg_client(guest_name):
    """Create a WireGuard client in wg-easy and return its ID."""
    if not WG_PASSWORD:
        raise RuntimeError("WG_PASSWORD not configured")
    s = _wg_easy_session()
    r = s.post(f"{WG_EASY_URL}/api/wireguard/client", json={"name": guest_name}, timeout=5)
    r.raise_for_status()
    # wg-easy API returns {"success": true} — fetch client list to get the ID
    r = s.get(f"{WG_EASY_URL}/api/wireguard/client", timeout=5)
    r.raise_for_status()
    clients = [c for c in r.json() if c["name"] == guest_name]
    if not clients:
        raise RuntimeError(f"Client '{guest_name}' not found after creation")
    return clients[-1]["id"]


def send_guest_welcome(email, name, onboard_token):
    setup_url = f"{BASE_URL}/onboard/{onboard_token}"
    _send_email(email, "Welcome to the Media Server!", f"""\
<html>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;">
<h1 style="color: #1a1a2e; border-bottom: 2px solid #e94560; padding-bottom: 10px;">Welcome to the Media Server, {name}!</h1>
<h2 style="color: #16213e;">1. Set Up VPN (required)</h2>
<p><strong>Plex will not work without the VPN.</strong> Visit your setup page to download the VPN config file and follow the instructions:</p>
<p style="margin: 15px 0;"><a href="{setup_url}" style="background: #e94560; color: #fff; padding: 10px 20px; border-radius: 6px; text-decoration: none; font-weight: 600;">Open Setup Page</a></p>
<p style="font-size: 13px; color: #888;">Bookmark this link &mdash; you can always come back to download your VPN config or review the setup instructions.</p>
<h2 style="color: #16213e;">2. Install Plex</h2>
<p>Download the <strong>Plex</strong> app on your phone, TV, or streaming device. <strong>Enable the VPN first</strong>, then sign in with your Plex account. You'll see two libraries: <strong>Guest TV</strong> and <strong>Guest Movies</strong>.</p>
<h2 style="color: #16213e;">3. Add Content via Trakt</h2>
<p>Your Trakt watchlist is connected. To add movies or TV shows:</p>
<ol style="line-height: 1.8;">
<li>Go to <a href="https://trakt.tv">trakt.tv</a></li>
<li>Search for what you want to watch</li>
<li>Click the bookmark icon to add to your watchlist</li>
<li>It will appear in Plex within 1&ndash;2 hours</li>
</ol>
<h2 style="color: #16213e;">Good to Know</h2>
<ul style="line-height: 1.8;">
<li>Storage: <strong>{GUEST_QUOTA_GB} GB shared</strong> across all guests.</li>
<li>Watched content is <strong>automatically removed after 30 days</strong> to free space.</li>
<li>Want to rewatch something? Just add it to your Trakt watchlist again.</li>
<li>New releases download once a digital version is available (not while in theaters).</li>
<li>TV series: all existing episodes download, and new ones arrive as they air.</li>
</ul>
<hr style="border: none; border-top: 1px solid #ddd; margin: 20px 0;">
<p style="color: #888; font-size: 12px;">Sent from Media Server Status Page</p>
</body>
</html>""")


# --- Public onboarding routes (no auth) ---

@app.route("/onboard", methods=["GET", "POST"])
def onboard():
    if request.method == "POST":
        if not check_csrf():
            abort(403)
        if not verify_turnstile(request.form.get("cf-turnstile-response", "")):
            flash("Verification failed. Please try again.", "error")
            return render_template("onboard.html")
        name = request.form.get("name", "").strip()
        email = request.form.get("email", "").strip().lower()
        trakt_username = request.form.get("trakt_username", "").strip()

        if not name or not email or not trakt_username:
            flash("All fields are required.", "error")
            return render_template("onboard.html")

        if is_rate_limited(email):
            flash("Too many attempts. Please wait a few minutes.", "error")
            return render_template("onboard.html")
        record_attempt(email)

        db = get_db()
        existing = db.execute(
            "SELECT id, onboard_token FROM guests WHERE email = ? AND status != 'rejected' AND active = 0",
            (email,),
        ).fetchone()
        if existing and existing["onboard_token"]:
            return redirect(url_for("onboard_status", token=existing["onboard_token"]))

        token = secrets.token_urlsafe(32)
        now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        db.execute(
            "INSERT INTO guests (name, email, trakt_username, onboard_token, onboard_token_created_at, status, active) VALUES (?, ?, ?, ?, ?, 'pending_approval', 0)",
            (name, email, trakt_username, token, now_utc),
        )
        db.commit()

        # Notify admins
        try:
            for admin_email in ADMIN_EMAILS:
                _send_email(admin_email, f"New guest request: {name}", f"""\
<html><body style="font-family: sans-serif; color: #333; max-width: 500px; margin: 0 auto; padding: 20px;">
<h2>New Guest Request</h2>
<p><strong>Name:</strong> {name}<br><strong>Email:</strong> {email}<br><strong>Trakt:</strong> {trakt_username}</p>
<p><a href="{BASE_URL}/admin/invite">Review and approve</a></p>
</body></html>""")
        except Exception as e:
            app.logger.error(f"Failed to notify admins: {e}")

        return redirect(url_for("onboard_status", token=token))

    return render_template("onboard.html")


@app.route("/onboard/<token>")
def onboard_status(token):
    guest = _get_guest_by_token(token)
    if not guest:
        abort(404)
    # Retry VPN client creation if it failed during onboarding
    if guest["status"] == "complete" and not guest["wg_client_id"]:
        try:
            wg_id = create_wg_client(guest["name"])
            db = get_db()
            db.execute("UPDATE guests SET wg_client_id = ? WHERE id = ?", (wg_id, guest["id"]))
            db.commit()
            guest = _get_guest_by_token(token)
        except Exception as e:
            app.logger.error(f"VPN client retry failed for {guest['name']}: {e}")
    device_data = json.loads(guest["trakt_device_data"]) if guest["trakt_device_data"] else None
    return render_template("onboard_status.html", guest=guest, device_data=device_data, quota_gb=GUEST_QUOTA_GB)


@app.route("/onboard/<token>/start-trakt", methods=["POST"])
def onboard_start_trakt(token):
    if not check_csrf():
        abort(403)
    guest = _get_guest_by_token(token)
    if not guest or guest["status"] != "approved":
        abort(400)

    try:
        resp = requests.post(
            f"{TRAKT_API_BASE}/oauth/device/code",
            json={"client_id": SONARR_TRAKT_CLIENT_ID}, timeout=10,
        )
        resp.raise_for_status()
        dd = resp.json()
    except Exception:
        flash("Failed to start Trakt authorization. Try again.", "error")
        return redirect(url_for("onboard_status", token=token))

    db = get_db()
    db.execute(
        "UPDATE guests SET status = 'trakt_tv_auth', trakt_device_data = ? WHERE id = ?",
        (json.dumps({"device_code": dd["device_code"], "user_code": dd["user_code"],
                      "interval": dd.get("interval", 5), "expires_in": dd.get("expires_in", 600),
                      "started_at": time.time()}), guest["id"]),
    )
    db.commit()
    return redirect(url_for("onboard_status", token=token))


@app.route("/onboard/<token>/poll", methods=["POST"])
def onboard_poll(token):
    guest = _get_guest_by_token(token)
    if not guest or guest["status"] not in ("trakt_tv_auth", "trakt_movie_auth"):
        return {"status": "error", "message": "Invalid state"}, 400

    dd = json.loads(guest["trakt_device_data"]) if guest["trakt_device_data"] else None
    if not dd:
        return {"status": "error", "message": "No device data"}, 400

    elapsed = time.time() - dd["started_at"]
    if elapsed > dd["expires_in"]:
        db = get_db()
        db.execute("UPDATE guests SET status = 'approved', trakt_device_data = NULL WHERE id = ?", (guest["id"],))
        db.commit()
        return {"status": "expired", "message": "Authorization timed out. Click Start to try again."}

    is_tv = guest["status"] == "trakt_tv_auth"
    client_id = SONARR_TRAKT_CLIENT_ID if is_tv else RADARR_TRAKT_CLIENT_ID

    try:
        resp = requests.post(
            f"{TRAKT_API_BASE}/oauth/device/token",
            json={"code": dd["device_code"], "client_id": client_id}, timeout=10,
        )
    except Exception:
        label = "TV Shows" if is_tv else "Movies"
        return {"status": "pending", "message": f"Waiting for authorization ({label})..."}

    if resp.status_code == 200:
        td = resp.json()
        access_token = td.get("access_token", "")
        refresh_token = td.get("refresh_token", "")
        expires_at = td.get("created_at", 0) + td.get("expires_in", 0)
        expires_iso = datetime.fromtimestamp(expires_at, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if expires_at else ""

        db = get_db()

        if is_tv:
            # Create Sonarr import list, then start Radarr phase
            try:
                _create_sonarr_import_list(guest["trakt_username"], access_token, refresh_token, expires_iso)
            except Exception as e:
                app.logger.error(f"Sonarr import list failed: {e}")

            try:
                resp2 = requests.post(
                    f"{TRAKT_API_BASE}/oauth/device/code",
                    json={"client_id": RADARR_TRAKT_CLIENT_ID}, timeout=10,
                )
                resp2.raise_for_status()
                dd2 = resp2.json()
            except Exception as e:
                app.logger.error(f"Radarr device code failed: {e}")
                # Skip to complete without Radarr
                db.execute("UPDATE guests SET status = 'complete', active = 1, trakt_device_data = NULL WHERE id = ?", (guest["id"],))
                db.commit()
                _finalize_onboard(guest)
                return {"status": "done", "message": "Setup complete (Movies auth skipped)."}

            db.execute(
                "UPDATE guests SET status = 'trakt_movie_auth', trakt_device_data = ? WHERE id = ?",
                (json.dumps({"device_code": dd2["device_code"], "user_code": dd2["user_code"],
                              "interval": dd2.get("interval", 5), "expires_in": dd2.get("expires_in", 600),
                              "started_at": time.time()}), guest["id"]),
            )
            db.commit()
            return {
                "status": "phase2",
                "message": "TV Shows authorized! Now authorize Movies.",
                "user_code": dd2["user_code"],
                "interval": dd2.get("interval", 5),
            }
        else:
            # Create Radarr import list, finalize
            try:
                _create_radarr_import_list(guest["trakt_username"], access_token, refresh_token, expires_iso)
            except Exception as e:
                app.logger.error(f"Radarr import list failed: {e}")

            db.execute("UPDATE guests SET status = 'complete', active = 1, trakt_device_data = NULL WHERE id = ?", (guest["id"],))
            db.commit()
            _finalize_onboard(guest)
            return {"status": "done", "message": "Setup complete!"}

    elif resp.status_code == 400:
        label = "TV Shows" if is_tv else "Movies"
        return {"status": "pending", "message": f"Waiting for authorization ({label})..."}
    elif resp.status_code in (404, 409, 410):
        db = get_db()
        db.execute("UPDATE guests SET status = 'approved', trakt_device_data = NULL WHERE id = ?", (guest["id"],))
        db.commit()
        return {"status": "expired", "message": "Authorization expired. Click Start to try again."}
    elif resp.status_code == 418:
        return {"status": "denied", "message": "Authorization was denied."}
    elif resp.status_code == 429:
        return {"status": "pending", "message": "Polling too fast, slowing down..."}
    else:
        return {"status": "pending", "message": f"Unexpected response ({resp.status_code}), retrying..."}


def _finalize_onboard(guest):
    """Plex sharing + VPN client + welcome email + admin notification after both Trakt auths complete."""
    plex_ok = False
    try:
        share_plex_guest_libraries(guest["email"])
        plex_ok = True
        db = get_db()
        db.execute("UPDATE guests SET plex_shared = 1 WHERE id = ?", (guest["id"],))
        db.commit()
    except Exception as e:
        app.logger.error(f"Plex sharing failed for {guest['email']}: {e}")

    # Create WireGuard VPN client
    try:
        wg_id = create_wg_client(guest["name"])
        db = get_db()
        db.execute("UPDATE guests SET wg_client_id = ? WHERE id = ?", (wg_id, guest["id"]))
        db.commit()
    except Exception as e:
        app.logger.error(f"WireGuard client creation failed for {guest['name']}: {e}")

    try:
        send_guest_welcome(guest["email"], guest["name"], guest["onboard_token"])
    except Exception as e:
        app.logger.error(f"Welcome email failed for {guest['email']}: {e}")

    # Notify admins
    plex_note = "Plex libraries shared automatically." if plex_ok else "<strong>ACTION NEEDED:</strong> Share Guest TV &amp; Guest Movies with this guest in Plex Settings &gt; Users &amp; Sharing."
    try:
        for admin_email in ADMIN_EMAILS:
            _send_email(admin_email, f"Guest onboarding complete: {guest['name']}", f"""\
<html><body style="font-family: sans-serif; color: #333; max-width: 500px; margin: 0 auto; padding: 20px;">
<h2>Guest Onboarding Complete</h2>
<p><strong>{guest['name']}</strong> ({guest['email']}) has completed Trakt authorization.</p>
<p>{plex_note}</p>
<p><a href="{BASE_URL}/admin/invite">Manage guests</a></p>
</body></html>""")
    except Exception as e:
        app.logger.error(f"Failed to notify admins: {e}")


@app.route("/onboard/<token>/vpn/qr")
def onboard_vpn_qr(token):
    guest = _get_guest_by_token(token)
    if not guest or guest["status"] != "complete" or not guest["wg_client_id"]:
        abort(404)
    try:
        s = _wg_easy_session()
        r = s.get(f"{WG_EASY_URL}/api/wireguard/client/{guest['wg_client_id']}/qrcode.svg", timeout=5)
        r.raise_for_status()
        return Response(r.content, mimetype="image/svg+xml")
    except Exception:
        abort(500)


@app.route("/onboard/<token>/vpn/config")
def onboard_vpn_config(token):
    guest = _get_guest_by_token(token)
    if not guest or guest["status"] != "complete" or not guest["wg_client_id"]:
        abort(404)
    try:
        s = _wg_easy_session()
        r = s.get(f"{WG_EASY_URL}/api/wireguard/client/{guest['wg_client_id']}/configuration", timeout=5)
        r.raise_for_status()
        return Response(
            r.content,
            mimetype="application/octet-stream",
            headers={"Content-Disposition": f"attachment; filename=MediaServer-{guest['name']}.conf"},
        )
    except Exception:
        abort(500)


# --- Admin guest management ---

@app.route("/admin/invite")
@admin_required
def admin_invite():
    db = get_db()
    pending = db.execute("SELECT * FROM guests WHERE status = 'pending_approval' ORDER BY invited_at DESC").fetchall()
    active = db.execute("SELECT * FROM guests WHERE status NOT IN ('pending_approval', 'rejected') ORDER BY active DESC, invited_at DESC").fetchall()
    return render_template("invite.html", pending=pending, guests=active, quota_gb=GUEST_QUOTA_GB, onboard_url=f"{BASE_URL}/onboard")


@app.route("/admin/invite/approve/<int:guest_id>", methods=["POST"])
@admin_required
def admin_invite_approve(guest_id):
    if not check_csrf():
        abort(403)
    db = get_db()
    guest = db.execute("SELECT * FROM guests WHERE id = ?", (guest_id,)).fetchone()
    if not guest:
        flash("Guest not found.", "error")
        return redirect(url_for("admin_invite"))

    now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    db.execute("UPDATE guests SET status = 'approved', onboard_token_created_at = ? WHERE id = ?", (now_utc, guest_id))
    db.commit()

    try:
        _send_email(guest["email"], "You're approved! Continue your setup", f"""\
<html><body style="font-family: sans-serif; color: #333; max-width: 500px; margin: 0 auto; padding: 20px;">
<h2>You're Approved!</h2>
<p>Hi {guest['name']}, your request to join the Media Server has been approved.</p>
<p>Continue your setup here:</p>
<p><a href="{BASE_URL}/onboard/{guest['onboard_token']}" style="display:inline-block;padding:12px 24px;background:#e94560;color:#fff;text-decoration:none;border-radius:8px;font-weight:600;">Continue Setup</a></p>
</body></html>""")
    except Exception as e:
        app.logger.error(f"Failed to send approval email: {e}")
        flash("Approved, but failed to send email.", "error")

    flash(f"Guest '{guest['name']}' approved.", "info")
    return redirect(url_for("admin_invite"))


@app.route("/admin/invite/reject/<int:guest_id>", methods=["POST"])
@admin_required
def admin_invite_reject(guest_id):
    if not check_csrf():
        abort(403)
    db = get_db()
    guest = db.execute("SELECT * FROM guests WHERE id = ?", (guest_id,)).fetchone()
    if not guest:
        flash("Guest not found.", "error")
        return redirect(url_for("admin_invite"))

    db.execute("UPDATE guests SET status = 'rejected' WHERE id = ?", (guest_id,))
    db.commit()

    try:
        _send_email(guest["email"], "Media Server access update", f"""\
<html><body style="font-family: sans-serif; color: #333; max-width: 500px; margin: 0 auto; padding: 20px;">
<p>Hi {guest['name']}, your request to join the Media Server was not approved at this time. Contact the admin if you have questions.</p>
</body></html>""")
    except Exception:
        pass

    flash(f"Guest '{guest['name']}' rejected.", "info")
    return redirect(url_for("admin_invite"))


@app.route("/admin/invite/plex-shared/<int:guest_id>", methods=["POST"])
@admin_required
def admin_invite_plex_shared(guest_id):
    if not check_csrf():
        abort(403)
    db = get_db()
    db.execute("UPDATE guests SET plex_shared = 1 WHERE id = ?", (guest_id,))
    db.commit()
    flash("Marked Plex libraries as shared.", "info")
    return redirect(url_for("admin_invite"))


@app.route("/admin/invite/remove/<int:guest_id>", methods=["POST"])
@admin_required
def admin_invite_remove(guest_id):
    if not check_csrf():
        abort(403)

    db = get_db()
    guest = db.execute("SELECT * FROM guests WHERE id = ?", (guest_id,)).fetchone()
    if not guest:
        flash("Guest not found.", "error")
        return redirect(url_for("admin_invite"))

    trakt_username = guest["trakt_username"]
    list_name = f"Trakt - {trakt_username}"

    for service, base_url, api_key in [
        ("Sonarr", SONARR_GUEST_URL, SONARR_GUEST_KEY),
        ("Radarr", RADARR_GUEST_URL, RADARR_GUEST_KEY),
    ]:
        if not api_key:
            continue
        try:
            r = requests.get(f"{base_url}/api/v3/importlist", headers={"X-Api-Key": api_key}, timeout=API_TIMEOUT)
            if r.status_code == 200:
                for lst in r.json():
                    if lst.get("name") == list_name:
                        requests.delete(f"{base_url}/api/v3/importlist/{lst['id']}", headers={"X-Api-Key": api_key}, timeout=API_TIMEOUT)
        except Exception as e:
            app.logger.error(f"Failed to remove import list from {service}: {e}")

    # Revoke Plex library share
    if guest["plex_shared"]:
        try:
            machine_id = ET.fromstring(
                requests.get(f"{PLEX_URL}/identity", params={"X-Plex-Token": PLEX_TOKEN}, timeout=API_TIMEOUT).text
            ).get("machineIdentifier")
            r = requests.get(
                f"https://plex.tv/api/servers/{machine_id}/shared_servers",
                params={"X-Plex-Token": PLEX_TOKEN},
                headers={"X-Plex-Client-Identifier": "mediaserver-statuspage"},
                timeout=API_TIMEOUT,
            )
            if r.status_code == 200:
                for ss in ET.fromstring(r.text).findall("SharedServer"):
                    if ss.get("email", "").lower() == guest["email"].lower():
                        share_id = ss.get("id")
                        requests.delete(
                            f"https://plex.tv/api/servers/{machine_id}/shared_servers/{share_id}",
                            params={"X-Plex-Token": PLEX_TOKEN},
                            headers={"X-Plex-Client-Identifier": "mediaserver-statuspage"},
                            timeout=API_TIMEOUT,
                        )
                        app.logger.info(f"Revoked Plex share for {guest['email']} (share {share_id})")
                        break
        except Exception as e:
            app.logger.error(f"Failed to revoke Plex share for {guest['email']}: {e}")

    # Delete WireGuard VPN client
    if guest["wg_client_id"]:
        try:
            s = _wg_easy_session()
            s.delete(f"{WG_EASY_URL}/api/wireguard/client/{guest['wg_client_id']}", timeout=5)
            app.logger.info(f"Deleted WireGuard client {guest['wg_client_id']} for {guest['name']}")
        except Exception as e:
            app.logger.error(f"Failed to delete WireGuard client for {guest['name']}: {e}")

    db.execute("UPDATE guests SET active = 0, status = 'rejected', plex_shared = 0, wg_client_id = NULL WHERE id = ?", (guest_id,))
    db.commit()

    flash(f"Guest '{trakt_username}' removed — import lists, Plex share, and VPN deleted.", "info")
    return redirect(url_for("admin_invite"))


# --- Startup ---

with app.app_context():
    init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)
