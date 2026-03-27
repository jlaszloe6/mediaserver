import os

# General
ALLOWED_EMAILS = [e.strip().lower() for e in os.environ.get("ALLOWED_EMAILS", "").split(",") if e.strip()]
BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080")
DB_PATH = os.environ.get("DB_PATH", "/app/data/statuspage.db")
SERVER_NAME = os.environ.get("SERVER_NAME", "Media Server")

# API endpoints (Docker service names for bridge network)
SONARR_URL = "http://sonarr:8989"
SONARR_KEY = os.environ.get("SONARR_API_KEY", "")
RADARR_URL = "http://radarr:7878"
RADARR_KEY = os.environ.get("RADARR_API_KEY", "")
JELLYFIN_URL = "http://jellyfin:8096"
JELLYFIN_EXTERNAL_URL = os.environ.get("JELLYFIN_EXTERNAL_URL", "")
TRANSMISSION_URL = "http://transmission:9091/transmission/rpc"
PROWLARR_URL = "http://prowlarr:9696"
PROWLARR_KEY = os.environ.get("PROWLARR_API_KEY", "")
SEERR_URL = "http://seerr:5055"

# Cloudflare Turnstile
TURNSTILE_SITE_KEY = os.environ.get("TURNSTILE_SITE_KEY", "")
TURNSTILE_SECRET_KEY = os.environ.get("TURNSTILE_SECRET_KEY", "")

# SMTP
SMTP_SERVER = os.environ.get("SMTP_SERVER", "smtp-relay.brevo.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD", "")
SMTP_FROM = os.environ.get("SMTP_FROM", "")

# Rate limiting: {email: [(timestamp, ...), ...]}
_rate_limits = {}
RATE_LIMIT_MAX = 3
RATE_LIMIT_WINDOW = 600  # 10 minutes

API_TIMEOUT = 3
HNR_HOURS = 72  # nCore H&R policy
