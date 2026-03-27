import json
import secrets
import time
from datetime import datetime, timedelta, timezone

import requests
from flask import Blueprint, abort, current_app, flash, redirect, render_template, request, url_for

from auth import check_csrf, is_rate_limited, record_attempt, verify_turnstile
from config import (
    ADMIN_EMAILS, BASE_URL, GUEST_QUOTA_GB, ONBOARD_TOKEN_TTL_DAYS,
    RADARR_TRAKT_CLIENT_ID, SONARR_TRAKT_CLIENT_ID, TRAKT_API_BASE,
)
from db import get_db
from services.email import send_styled_email, send_guest_welcome, _button
from services.jellyfin import create_jellyfin_user, get_guest_library_ids
from services.trakt import create_radarr_import_list, create_sonarr_import_list

onboard_bp = Blueprint("onboard_bp", __name__)


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


def _finalize_onboard(guest):
    """Jellyfin user creation + welcome email + admin notification after both Trakt auths complete."""
    jellyfin_ok = False
    try:
        library_ids = get_guest_library_ids()
        jellyfin_user_id = create_jellyfin_user(guest["name"], library_ids)
        jellyfin_ok = True
        db = get_db()
        db.execute("UPDATE guests SET jellyfin_user_id = ? WHERE id = ?", (jellyfin_user_id, guest["id"]))
        db.commit()
    except Exception as e:
        current_app.logger.error(f"Jellyfin user creation failed for {guest['name']}: {e}")

    try:
        send_guest_welcome(guest["email"], guest["name"], guest["onboard_token"])
    except Exception as e:
        current_app.logger.error(f"Welcome email failed for {guest['email']}: {e}")

    jellyfin_note = "Jellyfin user created automatically with guest library access." if jellyfin_ok else "<strong>ACTION NEEDED:</strong> Create a Jellyfin user for this guest and restrict access to Guest TV &amp; Guest Movies libraries."
    try:
        for admin_email in ADMIN_EMAILS:
            send_styled_email(admin_email, f"Guest onboarding complete: {guest['name']}", f"""\
<p style="font-size:17px;color:#fff;">Guest Onboarding Complete</p>
<p><strong>{guest['name']}</strong> ({guest['email']}) has completed Trakt authorization.</p>
<p>{jellyfin_note}</p>
<p style="margin:16px 0;">{_button(f"{BASE_URL}/admin/invite", "Manage Guests")}</p>""")
    except Exception as e:
        current_app.logger.error(f"Failed to notify admins: {e}")


@onboard_bp.route("/onboard", methods=["GET", "POST"])
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
            return redirect(url_for("onboard_bp.onboard_status", token=existing["onboard_token"]))

        token = secrets.token_urlsafe(32)
        now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        db.execute(
            "INSERT INTO guests (name, email, trakt_username, onboard_token, onboard_token_created_at, status, active) VALUES (?, ?, ?, ?, ?, 'pending_approval', 0)",
            (name, email, trakt_username, token, now_utc),
        )
        db.commit()

        try:
            for admin_email in ADMIN_EMAILS:
                send_styled_email(admin_email, f"New guest request: {name}", f"""\
<p style="font-size:17px;color:#fff;">New Guest Request</p>
<p><strong>Name:</strong> {name}<br><strong>Email:</strong> {email}<br><strong>Trakt:</strong> {trakt_username}</p>
<p style="margin:16px 0;">{_button(f"{BASE_URL}/admin/invite", "Review and Approve")}</p>""")
        except Exception as e:
            current_app.logger.error(f"Failed to notify admins: {e}")

        return redirect(url_for("onboard_bp.onboard_status", token=token))

    return render_template("onboard.html")


@onboard_bp.route("/onboard/<token>")
def onboard_status(token):
    guest = _get_guest_by_token(token)
    if not guest:
        abort(404)
    device_data = json.loads(guest["trakt_device_data"]) if guest["trakt_device_data"] else None
    return render_template("onboard_status.html", guest=guest, device_data=device_data, quota_gb=GUEST_QUOTA_GB)


@onboard_bp.route("/onboard/<token>/start-trakt", methods=["POST"])
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
        return redirect(url_for("onboard_bp.onboard_status", token=token))

    db = get_db()
    db.execute(
        "UPDATE guests SET status = 'trakt_tv_auth', trakt_device_data = ? WHERE id = ?",
        (json.dumps({"device_code": dd["device_code"], "user_code": dd["user_code"],
                      "interval": dd.get("interval", 5), "expires_in": dd.get("expires_in", 600),
                      "started_at": time.time()}), guest["id"]),
    )
    db.commit()
    return redirect(url_for("onboard_bp.onboard_status", token=token))


@onboard_bp.route("/onboard/<token>/poll", methods=["POST"])
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
            try:
                create_sonarr_import_list(guest["trakt_username"], access_token, refresh_token, expires_iso)
            except Exception as e:
                current_app.logger.error(f"Sonarr import list failed: {e}")

            try:
                resp2 = requests.post(
                    f"{TRAKT_API_BASE}/oauth/device/code",
                    json={"client_id": RADARR_TRAKT_CLIENT_ID}, timeout=10,
                )
                resp2.raise_for_status()
                dd2 = resp2.json()
            except Exception as e:
                current_app.logger.error(f"Radarr device code failed: {e}")
                db.execute("UPDATE guests SET status = 'complete', active = 1, trakt_device_data = NULL WHERE id = ?", (guest["id"],))
                db.commit()
                _finalize_onboard(_get_guest_by_token(token))
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
            try:
                create_radarr_import_list(guest["trakt_username"], access_token, refresh_token, expires_iso)
            except Exception as e:
                current_app.logger.error(f"Radarr import list failed: {e}")

            db.execute("UPDATE guests SET status = 'complete', active = 1, trakt_device_data = NULL WHERE id = ?", (guest["id"],))
            db.commit()
            _finalize_onboard(_get_guest_by_token(token))
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
