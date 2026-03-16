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

import requests
from flask import (
    Flask,
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

# Config
ALLOWED_EMAILS = [e.strip().lower() for e in os.environ.get("ALLOWED_EMAILS", "").split(",") if e.strip()]
BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080")
DB_PATH = os.environ.get("DB_PATH", "/app/data/statuspage.db")
TRAKT_LOG = os.environ.get("TRAKT_LOG", "/tmp/trakt-sync.log")

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
    """)
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
                    "fields": ["name", "percentDone", "rateDownload", "rateUpload", "eta", "status"],
                },
            },
            timeout=API_TIMEOUT,
        )
        data = r.json()
        return data.get("arguments", {}).get("torrents", [])
    except Exception:
        return None


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
        email = request.form.get("email", "").strip().lower()
        if not email:
            flash("Please enter your email.", "error")
            return render_template("login.html")

        if email not in ALLOWED_EMAILS:
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


@app.route("/logout")
def logout():
    session.clear()
    flash("Logged out.", "info")
    return redirect(url_for("login"))


@app.route("/")
@login_required
def dashboard():
    email = session["user_email"]

    # Fetch all data in parallel
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

    # Library stats
    series = results.get("series") or []
    movies = results.get("movies") or []
    total_episodes = sum(s.get("statistics", {}).get("episodeFileCount", 0) for s in series)

    # Build and save snapshot
    snapshot = build_snapshot(series, movies)
    prev_snapshot, prev_timestamp = get_previous_snapshot(email)
    diff = compute_diff(prev_snapshot, snapshot)
    save_snapshot(email, snapshot)

    # Merge and sort history
    activity = []
    for item in (results.get("sonarr_history") or []):
        series_title = item.get("series", {}).get("title", "Unknown")
        ep = item.get("episode", {})
        ep_label = f"S{ep.get('seasonNumber', 0):02d}E{ep.get('episodeNumber', 0):02d}" if ep else ""
        activity.append({
            "time": item.get("date", ""),
            "type": "tv",
            "title": f"{series_title} {ep_label}".strip(),
            "event": item.get("eventType", ""),
        })
    for item in (results.get("radarr_history") or []):
        activity.append({
            "time": item.get("date", ""),
            "type": "movie",
            "title": item.get("movie", {}).get("title", item.get("sourceTitle", "Unknown")),
            "event": item.get("eventType", ""),
        })
    activity.sort(key=lambda x: x["time"], reverse=True)

    # Format torrents
    torrents = []
    for t in (results.get("torrents") or []):
        status_map = {0: "Stopped", 1: "Queued", 2: "Verifying", 3: "Queued", 4: "Downloading", 5: "Queued", 6: "Seeding"}
        eta = t.get("eta", -1)
        if eta > 0:
            eta_str = str(timedelta(seconds=eta))
        elif eta == 0:
            eta_str = "Done"
        else:
            eta_str = "-"
        torrents.append({
            "name": t.get("name", "Unknown"),
            "percent": round(t.get("percentDone", 0) * 100, 1),
            "down": _format_speed(t.get("rateDownload", 0)),
            "up": _format_speed(t.get("rateUpload", 0)),
            "eta": eta_str,
            "status": status_map.get(t.get("status"), "Unknown"),
        })

    return render_template(
        "dashboard.html",
        health=results.get("health") or [],
        movie_count=len(movies),
        series_count=len(series),
        episode_count=total_episodes,
        torrents=torrents,
        activity=activity[:20],
        diff=diff,
        prev_timestamp=prev_timestamp,
        trakt_log=results.get("trakt_log"),
    )


def _format_speed(bps):
    if bps == 0:
        return "-"
    kbps = bps / 1024
    if kbps > 1024:
        return f"{kbps/1024:.1f} MB/s"
    return f"{kbps:.0f} KB/s"


# --- Startup ---

with app.app_context():
    init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)
