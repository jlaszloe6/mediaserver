import os

from flask import Flask

import db
import auth
from auth import auth_bp
from routes.dashboard import dashboard_bp
from routes.admin import admin_bp
from routes.onboard import onboard_bp

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
app.register_blueprint(admin_bp)
app.register_blueprint(onboard_bp)

# Initialize database
with app.app_context():
    db.init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)
