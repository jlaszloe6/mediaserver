import json
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import requests
from flask import Blueprint, render_template, session

from auth import login_required
from config import (
    API_TIMEOUT, HNR_HOURS, JELLYFIN_URL,
    PROWLARR_KEY, PROWLARR_URL, RADARR_KEY, RADARR_URL, SEERR_URL,
    SONARR_KEY, SONARR_URL, TRANSMISSION_URL, TRAKT_LOG,
)
from db import get_db

dashboard_bp = Blueprint("dashboard_bp", __name__)


# --- API clients ---

def ping_service(name, url, timeout=API_TIMEOUT):
    try:
        r = requests.get(url, timeout=timeout)
        return {"name": name, "ok": r.status_code < 500}
    except Exception:
        return {"name": name, "ok": False}


def fetch_service_health():
    checks = [
        ("Jellyfin", f"{JELLYFIN_URL}/health"),
        ("Sonarr", f"{SONARR_URL}/ping"),
        ("Radarr", f"{RADARR_URL}/ping"),
        ("Transmission", f"{TRANSMISSION_URL.rsplit('/rpc', 1)[0]}/web/"),
        ("Prowlarr", f"{PROWLARR_URL}/ping"),
        ("Seerr", f"{SEERR_URL}/api/v1/status"),
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
        r.raise_for_status()
        data = r.json()
        return data if isinstance(data, list) else None
    except Exception:
        return None


def fetch_radarr_movies():
    try:
        r = requests.get(f"{RADARR_URL}/api/v3/movie", headers={"X-Api-Key": RADARR_KEY}, timeout=API_TIMEOUT)
        r.raise_for_status()
        data = r.json()
        return data if isinstance(data, list) else None
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
        r.raise_for_status()
        data = r.json()
        return data if isinstance(data, list) else None
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
        r.raise_for_status()
        data = r.json()
        return data if isinstance(data, list) else None
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


def fetch_trakt_log():
    try:
        if not os.path.exists(TRAKT_LOG):
            return None
        with open(TRAKT_LOG) as f:
            lines = f.readlines()
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


# --- Formatters ---

def _format_speed(bps):
    if bps == 0:
        return "-"
    kbps = bps / 1024
    if kbps > 1024:
        return f"{kbps/1024:.1f} MB/s"
    return f"{kbps:.0f} KB/s"


def _format_torrents(raw_torrents):
    """Format Transmission torrent data for display."""
    torrents = []
    now_ts = time.time()
    for t in (raw_torrents or []):
        status_map = {0: "Stopped", 1: "Queued", 2: "Verifying", 3: "Queued", 4: "Downloading", 5: "Queued", 6: "Seeding"}
        status_code = t.get("status")
        eta = t.get("eta", -1)
        ratio = t.get("uploadRatio", 0)
        done_date = t.get("doneDate", 0)
        is_private = t.get("isPrivate", False)

        if status_code == 6:
            eta_str = "-"
        elif eta > 0:
            eta_str = str(timedelta(seconds=eta))
        elif eta == 0:
            eta_str = "Done"
        else:
            eta_str = "-"

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


def _utc_to_local(iso_str):
    """Convert UTC ISO timestamp to Europe/Budapest local time string."""
    if not iso_str:
        return ""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        local_dt = dt.astimezone(ZoneInfo("Europe/Budapest"))
        return local_dt.strftime("%Y-%m-%dT%H:%M:%S")
    except Exception:
        return iso_str


_EVENT_LABELS = {
    "grabbed": "Searching",
    "downloadFolderImported": "Downloaded",
    "downloadFailed": "Failed",
    "episodeFileDeleted": "Deleted",
    "episodeFileRenamed": "Renamed",
    "movieFileDeleted": "Deleted",
    "movieFileRenamed": "Renamed",
    "movieImported": "Downloaded",
    "seriesFolderImported": "Downloaded",
}


def _format_activity(sonarr_history, radarr_history):
    """Format Sonarr/Radarr history into activity list."""
    activity = []
    for item in (sonarr_history or []):
        series_title = item.get("series", {}).get("title", "Unknown")
        ep = item.get("episode", {})
        ep_label = f"S{ep.get('seasonNumber', 0):02d}E{ep.get('episodeNumber', 0):02d}" if ep else ""
        raw_event = item.get("eventType", "")
        activity.append({
            "time": _utc_to_local(item.get("date", "")),
            "type": "tv",
            "title": f"{series_title} {ep_label}".strip(),
            "event": _EVENT_LABELS.get(raw_event, raw_event),
        })
    for item in (radarr_history or []):
        raw_event = item.get("eventType", "")
        activity.append({
            "time": _utc_to_local(item.get("date", "")),
            "type": "movie",
            "title": item.get("movie", {}).get("title", item.get("sourceTitle", "Unknown")),
            "event": _EVENT_LABELS.get(raw_event, raw_event),
        })
    activity.sort(key=lambda x: x["time"], reverse=True)
    return activity


# --- Route ---

@dashboard_bp.route("/")
@login_required
def dashboard():
    email = session["user_email"]

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
    )
