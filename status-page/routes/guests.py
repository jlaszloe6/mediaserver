import re
import secrets

from flask import Blueprint, abort, flash, redirect, request, session, url_for

from auth import admin_required, check_csrf, is_allowed_email
from db import add_guest, get_guest, remove_guest, revoke_guest
from services.email import send_welcome_email
from services.jellyfin import create_jellyfin_user, delete_jellyfin_user_by_username
from services.seerr import delete_seerr_user, import_and_configure_seerr_user

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

    # Check for an existing row (any status) before is_allowed_email, which
    # excludes revoked guests by design (see get_all_guest_emails). Without
    # this, re-inviting an email stuck in "revoked, cleanup pending" would
    # sail past the is_allowed_email check below, create a brand new
    # Jellyfin/Seerr account, and only then fail on add_guest()'s primary
    # key - leaving that new account orphaned with nothing tracking it.
    existing_guest = get_guest(email)
    if existing_guest and existing_guest["revoked"]:
        flash(
            f"{email} is pending removal (Jellyfin/Seerr cleanup incomplete) — "
            f"resolve that from the guest list before re-inviting.",
            "error",
        )
        return redirect(url_for("dashboard_bp.dashboard"))

    if is_allowed_email(email):
        flash("This email already has access.", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    username = _username_from_email(email)
    password = secrets.token_urlsafe(12)

    ok, warning, jf_user_id = create_jellyfin_user(username, password)
    if not ok:
        flash(f"Failed to create Jellyfin user: {warning}", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    # Import into Seerr and set guest root folders
    seerr_ok, seerr_warn, seerr_account_may_exist = import_and_configure_seerr_user(username, jf_user_id)
    if not seerr_ok and warning:
        warning = f"{warning}; Seerr: {seerr_warn}"
    elif not seerr_ok:
        warning = f"Seerr setup failed: {seerr_warn}"

    invited_by = session["user_email"]
    if not add_guest(email, username, invited_by, seerr_configured=seerr_account_may_exist):
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

    guest = get_guest(email)
    if not guest:
        flash(f"{email} is not a guest.", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    # Revoke status page access FIRST, before attempting the external
    # Jellyfin/Seerr cleanup below - is_allowed_email() checks this flag, so
    # an already-open session is cut off on its very next request and no new
    # magic link can be issued, regardless of whether the cleanup below
    # succeeds. Previously the guest row (and therefore status page access)
    # was left fully intact for as long as a partial cleanup kept it from
    # being deleted - sometimes indefinitely, if the underlying issue was
    # never revisited.
    revoke_guest(email)

    username = guest["jellyfin_username"]
    jf_ok = delete_jellyfin_user_by_username(username)
    seerr_ok = delete_seerr_user(username, seerr_configured=bool(guest["seerr_configured"]))

    if jf_ok and seerr_ok:
        remove_guest(email)
        flash(f"Removed {email} — Jellyfin and Seerr access revoked.", "info")
    else:
        # Keep the guest record on a partial/failed revoke: it's the only
        # place jellyfin_username is stored, and dropping it here would
        # leave no way to retry once the underlying issue (API down, bad
        # key, etc.) is fixed. Status page access is already cut off above
        # regardless.
        failed = [name for name, ok in (("Jellyfin", jf_ok), ("Seerr", seerr_ok)) if not ok]
        flash(
            f"Status page access for {email} revoked immediately. Could not fully revoke "
            f"in: {', '.join(failed)} — record kept, fix the issue and remove again to retry.",
            "error",
        )
    return redirect(url_for("dashboard_bp.dashboard"))
