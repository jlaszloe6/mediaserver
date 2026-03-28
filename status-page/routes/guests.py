import re
import secrets

from flask import Blueprint, abort, flash, redirect, request, session, url_for

from auth import admin_required, check_csrf, is_allowed_email
from db import add_guest, remove_guest
from services.email import send_welcome_email
from services.jellyfin import create_jellyfin_user

guests_bp = Blueprint("guests_bp", __name__)


def _username_from_email(email):
    local = email.split("@")[0]
    clean = re.sub(r"[^a-zA-Z0-9]", "", local)
    return clean or "guest"


@guests_bp.route("/guests/invite", methods=["POST"])
@admin_required
def invite():
    if not check_csrf():
        abort(403)

    email = request.form.get("email", "").strip().lower()
    if not email or "@" not in email:
        flash("Please enter a valid email address.", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    if is_allowed_email(email):
        flash("This email already has access.", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    username = _username_from_email(email)
    password = secrets.token_urlsafe(12)

    ok, warning = create_jellyfin_user(username, password)
    if not ok:
        flash(f"Failed to create Jellyfin user: {warning}", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    invited_by = session["user_email"]
    if not add_guest(email, username, invited_by):
        flash("Guest already exists in database.", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    try:
        send_welcome_email(email, username, password)
        if warning:
            flash(f"Invited {email} — {warning}.", "error")
        else:
            flash(f"Invited {email} — welcome email sent.", "info")
    except Exception:
        flash(f"Invited {email} — Jellyfin account created but email failed to send.", "error")

    return redirect(url_for("dashboard_bp.dashboard"))


@guests_bp.route("/guests/remove", methods=["POST"])
@admin_required
def remove():
    if not check_csrf():
        abort(403)

    email = request.form.get("email", "").strip().lower()
    if not email:
        abort(400)

    remove_guest(email)
    flash(f"Removed {email} from guests.", "info")
    return redirect(url_for("dashboard_bp.dashboard"))
