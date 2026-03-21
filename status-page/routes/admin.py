from datetime import datetime, timezone

import requests
from flask import Blueprint, abort, current_app, flash, redirect, render_template, url_for

from auth import admin_required, check_csrf
from config import (
    ADMIN_EMAILS, API_TIMEOUT, BASE_URL, GUEST_QUOTA_GB,
    RADARR_GUEST_KEY, RADARR_GUEST_URL, SONARR_GUEST_KEY, SONARR_GUEST_URL,
)
from db import get_db
from services.email import send_email
from services.plex import revoke_plex_share
from services.wireguard import delete_wg_client

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
        send_email(guest["email"], "You're approved! Continue your setup", f"""\
<html><body style="font-family: sans-serif; color: #333; max-width: 500px; margin: 0 auto; padding: 20px;">
<h2>You're Approved!</h2>
<p>Hi {guest['name']}, your request to join the Media Server has been approved.</p>
<p>Continue your setup here:</p>
<p><a href="{BASE_URL}/onboard/{guest['onboard_token']}" style="display:inline-block;padding:12px 24px;background:#e94560;color:#fff;text-decoration:none;border-radius:8px;font-weight:600;">Continue Setup</a></p>
</body></html>""")
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
        send_email(guest["email"], "Media Server access update", f"""\
<html><body style="font-family: sans-serif; color: #333; max-width: 500px; margin: 0 auto; padding: 20px;">
<p>Hi {guest['name']}, your request to join the Media Server was not approved at this time. Contact the admin if you have questions.</p>
</body></html>""")
    except Exception:
        pass

    flash(f"Guest '{guest['name']}' rejected.", "info")
    return redirect(url_for("admin_bp.admin_invite"))


@admin_bp.route("/admin/invite/plex-shared/<int:guest_id>", methods=["POST"])
@admin_required
def admin_invite_plex_shared(guest_id):
    if not check_csrf():
        abort(403)
    db = get_db()
    db.execute("UPDATE guests SET plex_shared = 1 WHERE id = ?", (guest_id,))
    db.commit()
    flash("Marked Plex libraries as shared.", "info")
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
            current_app.logger.error(f"Failed to remove import list from {service}: {e}")

    # Revoke Plex library share
    if guest["plex_shared"]:
        try:
            revoke_plex_share(guest["email"])
        except Exception as e:
            current_app.logger.error(f"Failed to revoke Plex share for {guest['email']}: {e}")

    # Delete WireGuard VPN client
    if guest["wg_client_id"]:
        try:
            delete_wg_client(guest["wg_client_id"])
            current_app.logger.info(f"Deleted WireGuard client {guest['wg_client_id']} for {guest['name']}")
        except Exception as e:
            current_app.logger.error(f"Failed to delete WireGuard client for {guest['name']}: {e}")

    db.execute("UPDATE guests SET active = 0, status = 'rejected', plex_shared = 0, wg_client_id = NULL WHERE id = ?", (guest_id,))
    db.commit()

    flash(f"Guest '{trakt_username}' removed — import lists, Plex share, and VPN deleted.", "info")
    return redirect(url_for("admin_bp.admin_invite"))
