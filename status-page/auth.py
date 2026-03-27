import hashlib
import secrets
import time
from datetime import datetime, timedelta, timezone
from functools import wraps

from flask import Blueprint, abort, flash, redirect, render_template, request, session, url_for

from config import (
    ALLOWED_EMAILS, RATE_LIMIT_MAX, RATE_LIMIT_WINDOW,
    TURNSTILE_SECRET_KEY, TURNSTILE_SITE_KEY,
)
from db import get_db
from services.email import send_magic_link, send_user_guide

import requests

auth_bp = Blueprint("auth_bp", __name__)


# --- Helpers (importable by other modules) ---

def hash_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def is_rate_limited(email):
    db = get_db()
    cutoff = (datetime.now(timezone.utc) - timedelta(seconds=RATE_LIMIT_WINDOW)).strftime("%Y-%m-%dT%H:%M:%SZ")
    row = db.execute(
        "SELECT COUNT(*) as cnt FROM login_tokens WHERE email = ? AND expires_at > ?",
        (email.lower(), cutoff),
    ).fetchone()
    return (row["cnt"] if row else 0) >= RATE_LIMIT_MAX


def cleanup_expired_tokens():
    db = get_db()
    db.execute("DELETE FROM login_tokens WHERE used = 1 OR expires_at < datetime('now')")
    db.commit()


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


def generate_csrf():
    if "_csrf" not in session:
        session["_csrf"] = secrets.token_hex(16)
    return session["_csrf"]


def check_csrf():
    token = request.form.get("_csrf", "")
    return token and token == session.get("_csrf")


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user_email" not in session:
            return redirect(url_for("auth_bp.login"))
        return f(*args, **kwargs)
    return decorated


def init_app(app):
    """Register context processor and Jinja globals."""
    @app.context_processor
    def inject_turnstile():
        return {"turnstile_site_key": TURNSTILE_SITE_KEY}

    app.jinja_env.globals["csrf_token"] = generate_csrf


# --- Routes ---

@auth_bp.route("/login", methods=["GET", "POST"])
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

        if email not in ALLOWED_EMAILS:
            # Don't reveal whether email is valid
            flash("If that email is registered, a login link has been sent.", "info")
            return redirect(url_for("auth_bp.login"))

        if is_rate_limited(email):
            flash("Too many attempts. Please wait a few minutes.", "error")
            return redirect(url_for("auth_bp.login"))

        # Clean up expired/used tokens periodically
        cleanup_expired_tokens()

        token = secrets.token_urlsafe(32)
        token_h = hash_token(token)
        expires = (datetime.now(timezone.utc) + timedelta(minutes=15)).strftime("%Y-%m-%dT%H:%M:%SZ")

        db = get_db()
        db.execute("INSERT INTO login_tokens (token_hash, email, expires_at) VALUES (?, ?, ?)", (token_h, email, expires))
        db.commit()

        try:
            send_magic_link(email, token)
        except Exception as e:
            from flask import current_app
            current_app.logger.error(f"Failed to send email: {e}")
            flash("Failed to send email. Please try again later.", "error")
            return redirect(url_for("auth_bp.login"))

        flash("If that email is registered, a login link has been sent.", "info")
        return redirect(url_for("auth_bp.login"))

    return render_template("login.html")


@auth_bp.route("/auth/<token>")
def auth(token):
    token_h = hash_token(token)
    db = get_db()
    row = db.execute("SELECT * FROM login_tokens WHERE token_hash = ?", (token_h,)).fetchone()

    if not row or row["used"]:
        flash("Invalid or expired link.", "error")
        return redirect(url_for("auth_bp.login"))

    expires = datetime.strptime(row["expires_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    if datetime.now(timezone.utc) > expires:
        flash("Link has expired. Please request a new one.", "error")
        return redirect(url_for("auth_bp.login"))

    # Mark token as used
    db.execute("UPDATE login_tokens SET used = 1 WHERE token_hash = ?", (token_h,))

    # Upsert user
    db.execute(
        "INSERT INTO users (email, last_login) VALUES (?, datetime('now')) ON CONFLICT(email) DO UPDATE SET last_login = datetime('now')",
        (row["email"],),
    )
    db.commit()

    session.permanent = True
    from flask import current_app
    current_app.permanent_session_lifetime = timedelta(days=30)
    session["user_email"] = row["email"]
    # Regenerate CSRF on login
    session.pop("_csrf", None)

    return redirect(url_for("dashboard_bp.dashboard"))


@auth_bp.route("/send-guide", methods=["POST"])
@login_required
def send_guide():
    if not check_csrf():
        abort(403)
    email = session["user_email"]
    try:
        send_user_guide(email)
        flash("Quick Actions guide sent to your email.", "info")
    except Exception as e:
        from flask import current_app
        current_app.logger.error(f"Failed to send guide: {e}")
        flash("Failed to send guide. Please try again later.", "error")
    return redirect(url_for("dashboard_bp.dashboard"))


@auth_bp.route("/logout")
def logout():
    session.clear()
    flash("Logged out.", "info")
    return redirect(url_for("auth_bp.login"))
