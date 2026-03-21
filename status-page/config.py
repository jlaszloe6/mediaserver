import os

# General
ALLOWED_EMAILS = [e.strip().lower() for e in os.environ.get("ALLOWED_EMAILS", "").split(",") if e.strip()]
ADMIN_EMAILS = [e.strip().lower() for e in os.environ.get("ADMIN_EMAILS", "").split(",") if e.strip()]
BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080")
DB_PATH = os.environ.get("DB_PATH", "/app/data/statuspage.db")
TRAKT_LOG = os.environ.get("TRAKT_LOG", "/tmp/trakt-sync.log")
GUEST_QUOTA_GB = int(os.environ.get("GUEST_QUOTA_GB", "100"))
ONBOARD_TOKEN_TTL_DAYS = int(os.environ.get("ONBOARD_TOKEN_TTL_DAYS", "7"))

# API endpoints (all on localhost since we're on host network)
SONARR_URL = "http://localhost:8989"
SONARR_KEY = os.environ.get("SONARR_API_KEY", "")
RADARR_URL = "http://localhost:7878"
RADARR_KEY = os.environ.get("RADARR_API_KEY", "")
PLEX_URL = "http://localhost:32400"
PLEX_TOKEN = os.environ.get("PLEX_TOKEN", "")
TRANSMISSION_URL = "http://localhost:9091/transmission/rpc"
PROWLARR_URL = "http://localhost:9696"
PROWLARR_KEY = os.environ.get("PROWLARR_API_KEY", "")
TAUTULLI_URL = "http://localhost:8181"
TAUTULLI_KEY = os.environ.get("TAUTULLI_API_KEY", "")
SEERR_URL = "http://localhost:5055"
UPTIME_KUMA_URL = "http://localhost:3001"

# Guest pipeline
SONARR_GUEST_URL = "http://localhost:8990"
SONARR_GUEST_KEY = os.environ.get("SONARR_GUEST_API_KEY", "")
RADARR_GUEST_URL = "http://localhost:7879"
RADARR_GUEST_KEY = os.environ.get("RADARR_GUEST_API_KEY", "")
SONARR_TRAKT_CLIENT_ID = os.environ.get("SONARR_TRAKT_CLIENT_ID", "")
RADARR_TRAKT_CLIENT_ID = os.environ.get("RADARR_TRAKT_CLIENT_ID", "")

# WireGuard (wg-easy API)
WG_EASY_URL = "http://localhost:51821"
WG_PASSWORD = os.environ.get("WG_PASSWORD", "")

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
TRAKT_API_BASE = "https://api.trakt.tv"
