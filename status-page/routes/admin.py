from datetime import datetime, timezone

import requests
from flask import Blueprint, abort, current_app, flash, redirect, render_template, url_for

from auth import admin_required, check_csrf
from config import (
    ADMIN_EMAILS, API_TIMEOUT, BASE_URL, GUEST_QUOTA_GB,
    RADARR_KEY, RADARR_URL, SONARR_KEY, SONARR_URL,
)
from db import get_db
from services.email import send_styled_email, _button
from services.jellyfin import delete_jellyfin_user

admin_bp = Blueprint("admin_bp", __name__)


@admin_bp.route("/admin/invite")
@admin_required
def admin_invite():
    db = get_db()
    pending = db.execute("SELECT * FROM guests WHERE status = 'pending_approval' ORDER BY invited_at DESC").fetchall()
    active = db.execute("SELECT * FROM guests WHERE status NOT IN ('pending_approval', 'rejected') ORDER BY active DESC, invited_at DESC").fetchall()
    return render_template("invite.html", pending=pending, guests=active, quota_gb=GUEST_QUOTA_GB, onboard_url=f"{BASE_URL}/onboard")


@admin_bp.route("/admin/invite/approve/<int:guest_id>", methods=["POST"])
@admin_required
def admin_invite_approve(guest_id):
    if not check_csrf():
        abort(403)
    db = get_db()
    guest = db.execute("SELECT * FROM guests WHERE id = ?", (guest_id,)).fetchone()
    if not guest:
        flash("Guest not found.", "error")
        return redirect(url_for("admin_bp.admin_invite"))

    now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    db.execute("UPDATE guests SET status = 'approved', onboard_token_created_at = ? WHERE id = ?", (now_utc, guest_id))
    db.commit()

    try:
        send_styled_email(guest["email"], "You're approved! Continue your setup", f"""\
<p style="font-size:17px;color:#fff;">You're Approved!</p>
<p>Hi {guest['name']}, your request to join the Media Server has been approved.</p>
<p>Continue your setup here:</p>
<p style="text-align:center;margin:16px 0;">{_button(f"{BASE_URL}/onboard/{guest['onboard_token']}", "Continue Setup")}</p>""")
    except Exception as e:
        current_app.logger.error(f"Failed to send approval email: {e}")
        flash("Approved, but failed to send email.", "error")

    flash(f"Guest '{guest['name']}' approved.", "info")
    return redirect(url_for("admin_bp.admin_invite"))


@admin_bp.route("/admin/invite/reject/<int:guest_id>", methods=["POST"])
@admin_required
def admin_invite_reject(guest_id):
    if not check_csrf():
        abort(403)
    db = get_db()
    guest = db.execute("SELECT * FROM guests WHERE id = ?", (guest_id,)).fetchone()
    if not guest:
        flash("Guest not found.", "error")
        return redirect(url_for("admin_bp.admin_invite"))

    db.execute("UPDATE guests SET status = 'rejected' WHERE id = ?", (guest_id,))
    db.commit()

    try:
        send_styled_email(guest["email"], "Media Server access update",
            f"<p>Hi {guest['name']}, your request to join the Media Server was not approved at this time. Contact the admin if you have questions.</p>")
    except Exception:
        pass

    flash(f"Guest '{guest['name']}' rejected.", "info")
    return redirect(url_for("admin_bp.admin_invite"))


@admin_bp.route("/admin/invite/remove/<int:guest_id>", methods=["POST"])
@admin_required
def admin_invite_remove(guest_id):
    if not check_csrf():
        abort(403)

    db = get_db()
    guest = db.execute("SELECT * FROM guests WHERE id = ?", (guest_id,)).fetchone()
    if not guest:
        flash("Guest not found.", "error")
        return redirect(url_for("admin_bp.admin_invite"))

    trakt_username = guest["trakt_username"]
    list_name = f"Trakt - {trakt_username}"

    for service, base_url, api_key in [
        ("Sonarr", SONARR_URL, SONARR_KEY),
        ("Radarr", RADARR_URL, RADARR_KEY),
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
            current_app.logger.error(f"Failed to remove import list from {service}: {e}")

    # Delete Jellyfin user
    if guest["jellyfin_user_id"]:
        try:
            delete_jellyfin_user(guest["jellyfin_user_id"])
            current_app.logger.info(f"Deleted Jellyfin user {guest['jellyfin_user_id']} for {guest['name']}")
        except Exception as e:
            current_app.logger.error(f"Failed to delete Jellyfin user for {guest['name']}: {e}")

    db.execute("UPDATE guests SET active = 0, status = 'rejected', jellyfin_user_id = NULL WHERE id = ?", (guest_id,))
    db.commit()

    flash(f"Guest '{trakt_username}' removed — import lists and Jellyfin user deleted.", "info")
    return redirect(url_for("admin_bp.admin_invite"))
