import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import requests
from flask import Blueprint, render_template, session

from auth import is_admin, login_required
from config import (
    API_TIMEOUT, AUDIOBOOKSHELF_KEY, AUDIOBOOKSHELF_URL, BAZARR_URL,
    HNR_HOURS, JELLYFIN_API_KEY, JELLYFIN_URL, LIDARR_URL, NAVIDROME_URL,
    PROWLARR_KEY, PROWLARR_URL, RADARR_KEY, RADARR_URL, SEERR_API_KEY, SEERR_URL,
    SERVER_NAME, SONARR_KEY, SONARR_URL, TRANSMISSION_URL,
)
from db import get_db, get_guests
from services.automation import fetch_backup_status, fetch_cron_status

dashboard_bp = Blueprint("dashboard_bp", __name__)


# --- API clients ---

def ping_service(name, url, timeout=API_TIMEOUT):
    try:
        r = requests.get(url, timeout=timeout)
        return {"name": name, "ok": r.ok}
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
        ("Bazarr", f"{BAZARR_URL}/"),
        ("Lidarr", f"{LIDARR_URL}/ping"),
        ("Navidrome", f"{NAVIDROME_URL}/"),
        ("Audiobookshelf", f"{AUDIOBOOKSHELF_URL}/healthcheck"),
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
        payload = {
            "method": "torrent-get",
            "arguments": {
                "fields": ["name", "percentDone", "rateDownload", "rateUpload", "eta", "status", "doneDate", "uploadRatio", "downloadDir", "isPrivate", "trackers", "hashString"],
            },
        }
        # Transmission RPC requires a session ID obtained from a 409 response
        resp = requests.post(TRANSMISSION_URL, json=payload, timeout=API_TIMEOUT)
        if resp.status_code == 409:
            sid = resp.headers.get("X-Transmission-Session-Id", "")
            resp = requests.post(
                TRANSMISSION_URL,
                headers={"X-Transmission-Session-Id": sid},
                json=payload,
                timeout=API_TIMEOUT,
            )
        if resp.status_code != 200:
            return None
        data = resp.json()
        return data.get("arguments", {}).get("torrents", [])
    except Exception:
        return None


# --- Stuck downloads ---
# Catches the exact failure mode found live this session with Blue Lights/
# Last Seen: a torrent finishes downloading, but Sonarr/Radarr never
# imports it (Sonarr's own queue had already dropped it - nothing else on
# this dashboard, or any alert, surfaced that it was just sitting there).

STUCK_DOWNLOAD_AGE_SECONDS = 2 * 60 * 60  # give Sonarr/Radarr room to import before flagging


# Sonarr/Radarr's own successful-import event, by app - matches
# _EVENT_LABELS' "Downloaded" entries below. Confirmed live this session:
# checking only "downloadFolderImported" produced a false positive for a
# torrent whose matching import event was "seriesFolderImported" instead.
_IMPORT_EVENT_TYPES = {"downloadFolderImported", "seriesFolderImported", "movieImported"}


def _was_imported(base_url, api_key, download_id):
    """None means "couldn't check" (API error) - deliberately distinct from
    False ("checked, no import event found"), so a transient Sonarr/Radarr
    hiccup doesn't get reported as a stuck download.

    pageSize is explicit and generous: without it, Sonarr/Radarr's default
    page size can return only the newest few "grabbed" events for a
    re-grabbed release, silently paging past an older but still-real
    "imported" event further back in that same downloadId's history -
    confirmed live this session (Blue Lights S03, re-grabbed twice after
    the SSD migration wiped its files; the only import event on record was
    from weeks earlier, past the default page).
    """
    try:
        r = requests.get(
            f"{base_url}/api/v3/history",
            params={"downloadId": download_id, "pageSize": 250},
            headers={"X-Api-Key": api_key},
            timeout=API_TIMEOUT,
        )
        r.raise_for_status()
        records = r.json().get("records", [])
        return any(rec.get("eventType") in _IMPORT_EVENT_TYPES for rec in records)
    except Exception:
        return None


def _format_age(seconds):
    minutes = int(seconds // 60)
    if minutes < 60:
        return f"{minutes}m"
    hours = minutes // 60
    if hours < 48:
        return f"{hours}h"
    return f"{hours // 24}d"


def fetch_stuck_downloads(torrents):
    if not torrents:
        return []
    now = time.time()
    stuck = []
    for t in torrents:
        if t.get("percentDone") != 1.0:
            continue
        done = t.get("doneDate") or 0
        if done <= 0 or (now - done) < STUCK_DOWNLOAD_AGE_SECONDS:
            continue
        download_dir = t.get("downloadDir", "")
        download_id = (t.get("hashString") or "").upper()
        if not download_id:
            continue
        if "tv-sonarr" in download_dir:
            imported = _was_imported(SONARR_URL, SONARR_KEY, download_id)
        elif "radarr" in download_dir:
            imported = _was_imported(RADARR_URL, RADARR_KEY, download_id)
        else:
            continue  # not a Sonarr/Radarr download (e.g. ebooks) - out of scope
        if imported is False:
            stuck.append({"name": t.get("name", "Unknown"), "age": _format_age(now - done)})
    return stuck


# --- Disk space ---

def fetch_disk_space():
    """Reads free/total space for MEDIA_ROOT via Sonarr's own diskspace API,
    rather than statuspage needing its own filesystem mount into the media
    root just to call statvfs() - Sonarr already reports this (it needs it
    for its own UI), and this app already talks to Sonarr's API for
    everything else, so no new mount/blast-radius is needed for one number.
    """
    try:
        r = requests.get(f"{SONARR_URL}/api/v3/diskspace", headers={"X-Api-Key": SONARR_KEY}, timeout=API_TIMEOUT)
        r.raise_for_status()
        for entry in r.json():
            # "/data" is Sonarr/Radarr/Lidarr/Bazarr's shared ${MEDIA_ROOT}:/data
            # mount - the one this whole stack's media actually lives on.
            if entry.get("path") == "/data":
                free = entry.get("freeSpace", 0)
                total = entry.get("totalSpace", 0)
                return {
                    "free_gb": round(free / 1024**3, 1),
                    "total_gb": round(total / 1024**3, 1),
                    "percent_used": round((1 - free / total) * 100) if total else 0,
                }
        return None
    except Exception:
        return None


# --- Prowlarr indexer health ---

def fetch_disabled_indexers():
    """Only Prowlarr's automatic-disable state (indexerstatus, keyed by a
    disabledTill timestamp - e.g. repeated Cloudflare/timeout failures),
    never a deliberately/manually disabled indexer (plain enable=false on
    /api/v1/indexer, e.g. this project's own EZTV/1337x, dead for unrelated
    reasons - see CLAUDE.md). Mirrors pipeline-monitor.sh's own check,
    which already draws this exact distinction. None means "couldn't
    check", distinct from [] ("checked, nothing auto-disabled")."""
    try:
        status_r = requests.get(f"{PROWLARR_URL}/api/v1/indexerstatus", headers={"X-Api-Key": PROWLARR_KEY}, timeout=API_TIMEOUT)
        status_r.raise_for_status()
        statuses = status_r.json()
        if not statuses:
            return []
        indexers_r = requests.get(f"{PROWLARR_URL}/api/v1/indexer", headers={"X-Api-Key": PROWLARR_KEY}, timeout=API_TIMEOUT)
        indexers_r.raise_for_status()
        id_to_name = {i["id"]: i["name"] for i in indexers_r.json()}
        return [id_to_name.get(s["indexerId"], f"indexer {s['indexerId']}") for s in statuses]
    except Exception:
        return None


# --- Upcoming releases / missing counts ---

def fetch_upcoming(days=7):
    """Next `days` of monitored episodes/movies, from Sonarr/Radarr's own
    calendar - both apps already search for these automatically once
    available; this is visibility, not a trigger for anything."""
    now = datetime.now(timezone.utc)
    start = now.strftime("%Y-%m-%d")
    end = (now + timedelta(days=days)).strftime("%Y-%m-%d")
    items = []

    try:
        r = requests.get(
            f"{SONARR_URL}/api/v3/calendar",
            params={"start": start, "end": end, "includeSeries": "true"},
            headers={"X-Api-Key": SONARR_KEY},
            timeout=API_TIMEOUT,
        )
        r.raise_for_status()
        for e in r.json():
            series_title = e.get("series", {}).get("title", "Unknown")
            items.append({
                "date": (e.get("airDateUtc") or "")[:10],
                "title": f"{series_title} S{e.get('seasonNumber', 0):02d}E{e.get('episodeNumber', 0):02d}",
            })
    except Exception:
        pass

    try:
        r = requests.get(
            f"{RADARR_URL}/api/v3/calendar",
            params={"start": start, "end": end},
            headers={"X-Api-Key": RADARR_KEY},
            timeout=API_TIMEOUT,
        )
        r.raise_for_status()
        for m in r.json():
            date = m.get("digitalRelease") or m.get("physicalRelease") or m.get("inCinemas") or ""
            items.append({"date": date[:10], "title": m.get("title", "Unknown")})
    except Exception:
        pass

    items.sort(key=lambda x: x["date"])
    return items


def fetch_missing_counts():
    """Total monitored-but-fileless episodes/movies, via each app's own
    wanted/missing totalRecords - both apps already search for these on
    their normal schedule; this is visibility, not a trigger for anything."""
    counts = {"series": None, "movies": None}
    try:
        r = requests.get(
            f"{SONARR_URL}/api/v3/wanted/missing",
            params={"pageSize": 1},
            headers={"X-Api-Key": SONARR_KEY},
            timeout=API_TIMEOUT,
        )
        r.raise_for_status()
        counts["series"] = r.json().get("totalRecords")
    except Exception:
        pass
    try:
        r = requests.get(
            f"{RADARR_URL}/api/v3/wanted/missing",
            params={"pageSize": 1},
            headers={"X-Api-Key": RADARR_KEY},
            timeout=API_TIMEOUT,
        )
        r.raise_for_status()
        counts["movies"] = r.json().get("totalRecords")
    except Exception:
        pass
    return counts


# --- Audiobookshelf library stats ---

def fetch_audiobookshelf_stats():
    """Item counts per Audiobookshelf library (Audiobooks/Ebooks/Podcasts),
    via limit=0 item listing calls - Audiobookshelf returns the real total
    in the `total` field even with limit=0, so this never actually pulls
    the item list itself. None means "couldn't reach Audiobookshelf at
    all" (the /api/libraries call itself failed); a library that fails its
    own count call is just skipped, same partial-failure tolerance as
    fetch_missing_counts."""
    try:
        r = requests.get(
            f"{AUDIOBOOKSHELF_URL}/api/libraries",
            headers={"Authorization": f"Bearer {AUDIOBOOKSHELF_KEY}"},
            timeout=API_TIMEOUT,
        )
        r.raise_for_status()
        libraries = r.json().get("libraries", [])
    except Exception:
        return None

    stats = {}
    for lib in libraries:
        try:
            r = requests.get(
                f"{AUDIOBOOKSHELF_URL}/api/libraries/{lib['id']}/items",
                params={"limit": 0},
                headers={"Authorization": f"Bearer {AUDIOBOOKSHELF_KEY}"},
                timeout=API_TIMEOUT,
            )
            r.raise_for_status()
            stats[lib.get("name", lib["id"])] = r.json().get("total")
        except Exception:
            continue
    return stats


# --- Jellyfin active playback ---

def fetch_active_playback():
    """Currently-playing Jellyfin sessions, via /Sessions - the same data
    Jellyfin's own dashboard shows. None means "couldn't check" (API
    error), distinct from [] ("checked, nobody is watching anything right
    now")."""
    try:
        r = requests.get(
            f"{JELLYFIN_URL}/Sessions",
            headers={"X-Emby-Token": JELLYFIN_API_KEY},
            timeout=API_TIMEOUT,
        )
        r.raise_for_status()
        sessions = r.json()
    except Exception:
        return None

    playing = []
    for s in sessions:
        item = s.get("NowPlayingItem")
        if not item:
            continue
        series_name = item.get("SeriesName")
        title = f"{series_name} - {item.get('Name', 'Unknown')}" if series_name else item.get("Name", "Unknown")
        playing.append({
            "user": s.get("UserName", "Unknown"),
            "title": title,
            "paused": s.get("PlayState", {}).get("IsPaused", False),
        })
    return playing


# --- Seerr pending requests ---

def fetch_seerr_pending():
    """Total pending Seerr requests, via take=1 (only the count is needed,
    not the request list itself). None means "couldn't check"."""
    try:
        r = requests.get(
            f"{SEERR_URL}/api/v1/request",
            params={"filter": "pending", "take": 1},
            headers={"X-Api-Key": SEERR_API_KEY},
            timeout=API_TIMEOUT,
        )
        r.raise_for_status()
        return r.json().get("pageInfo", {}).get("results")
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
            ex.submit(fetch_disk_space): "disk_space",
            ex.submit(fetch_disabled_indexers): "disabled_indexers",
            ex.submit(fetch_upcoming): "upcoming",
            ex.submit(fetch_missing_counts): "missing_counts",
            ex.submit(fetch_audiobookshelf_stats): "audiobookshelf_stats",
            ex.submit(fetch_active_playback): "active_playback",
            ex.submit(fetch_seerr_pending): "seerr_pending",
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
    stuck_downloads = fetch_stuck_downloads(results.get("torrents"))

    snapshot = build_snapshot(series, movies)
    prev_snapshot, prev_timestamp = get_previous_snapshot(email)
    diff = compute_diff(prev_snapshot, snapshot)
    save_snapshot(email, snapshot)

    guests = get_guests() if is_admin() else []

    return render_template(
        "dashboard.html",
        health=results.get("health") or [],
        movie_count=len(movies),
        series_count=len(series),
        episode_count=total_episodes,
        torrents=_format_torrents(results.get("torrents")),
        stuck_downloads=stuck_downloads,
        activity=_format_activity(results.get("sonarr_history"), results.get("radarr_history"))[:20],
        diff=diff,
        prev_timestamp=prev_timestamp,
        server_name=SERVER_NAME,
        guests=guests,
        cron_jobs=fetch_cron_status(),
        backup=fetch_backup_status(),
        disk_space=results.get("disk_space"),
        disabled_indexers=results.get("disabled_indexers"),
        upcoming=(results.get("upcoming") or [])[:10],
        missing_counts=results.get("missing_counts") or {},
        audiobookshelf_stats=results.get("audiobookshelf_stats"),
        active_playback=results.get("active_playback"),
        seerr_pending=results.get("seerr_pending"),
    )
