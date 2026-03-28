import os

from flask import Flask, render_template

import db
import auth
from auth import auth_bp
from routes.dashboard import dashboard_bp
from routes.guests import guests_bp

app = Flask(__name__)
app.secret_key = os.environ["SECRET_KEY"]
app.config.update(
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
)

# Initialize modules
db.init_app(app)
auth.init_app(app)

# Register blueprints (no url_prefix to keep existing url_for names working in templates)
app.register_blueprint(auth_bp)
app.register_blueprint(dashboard_bp)
app.register_blueprint(guests_bp)

# Error pages
ERROR_PAGES = {
    400: ("Bad Request", "The server could not understand this request."),
    403: ("Access Denied", "You don't have permission to access this page."),
    404: ("Not Found", "The page you're looking for doesn't exist or has expired."),
    500: ("Server Error", "Something went wrong on our end. Try again later."),
}

for code, (title, message) in ERROR_PAGES.items():
    app.register_error_handler(code, lambda e, c=code, t=title, m=message: (
        render_template("error.html", code=c, title=t, message=m), c
    ))

# Initialize database
with app.app_context():
    db.init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
