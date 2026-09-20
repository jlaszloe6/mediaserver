import os
import time

from flask import Blueprint, abort, flash, redirect, request, url_for
from werkzeug.utils import secure_filename

from auth import admin_required, check_csrf
from config import WATCH_EBOOKS_DIR

ebooks_bp = Blueprint("ebooks_bp", __name__)

# Real .torrent files are a few KB; this is a generous ceiling, not a
# realistic expectation - just enough to reject someone uploading the wrong
# file entirely.
MAX_TORRENT_SIZE = 2 * 1024 * 1024


@ebooks_bp.route("/ebooks/upload", methods=["POST"])
@admin_required
def upload_torrent():
    if not check_csrf():
        abort(403)

    file = request.files.get("torrent_file")
    if not file or not file.filename:
        flash("No file selected.", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    filename = secure_filename(file.filename)
    if not filename.lower().endswith(".torrent"):
        flash("Only .torrent files are accepted.", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    header = file.read(1)
    file.seek(0, os.SEEK_END)
    size = file.tell()
    file.seek(0)
    # Bencoded torrent files always open with a dictionary, i.e. a literal
    # 'd' byte - a cheap sanity check against an obviously-wrong file, not a
    # full parse.
    if size == 0 or size > MAX_TORRENT_SIZE or header != b"d":
        flash("That doesn't look like a valid .torrent file.", "error")
        return redirect(url_for("dashboard_bp.dashboard"))

    os.makedirs(WATCH_EBOOKS_DIR, exist_ok=True)
    # Timestamp-prefixed: two uploads sharing a filename must not overwrite
    # each other while both are still waiting for ebook-pipeline.sh's next
    # run (every 5 min) to pick them up.
    dest_name = f"{int(time.time())}-{filename}"
    file.save(os.path.join(WATCH_EBOOKS_DIR, dest_name))

    flash(f"Uploaded '{filename}' - the ebook pipeline will pick it up within 5 minutes.", "info")
    return redirect(url_for("dashboard_bp.dashboard"))
