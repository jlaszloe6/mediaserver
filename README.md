# Media Server

A self-hosted media server stack using Docker Compose. Request movies and TV shows via Seerr, and they'll automatically download and appear in Jellyfin. Watched content is cleaned up after 30 days.

## Architecture

```
                         ┌─────────────────────────────────────┐
                         │           DOWNLOAD FLOW             │
                         └─────────────────────────────────────┘

              Seerr ──► Sonarr/Radarr ──► Prowlarr ──► Indexers
            (requests)    ▲    │                          │
                          │    ▼                          ▼
                          │  Transmission ◄──────── Torrent Search
                          │       │
                          │       ▼
                          └── Jellyfin Libraries

                         ┌─────────────────────────────────────┐
                         │           CLEANUP FLOWS             │
                         └─────────────────────────────────────┘

Watched 30+ days ago ──► jellyfin-watched-cleanup.sh ──► delete from Sonarr/Radarr
Delete from Jellyfin ──► jellyfin-cleanup.sh ──────────► delete from Sonarr/Radarr
```

## Services

| Service | Description |
|---------|-------------|
| Jellyfin | Media server (TV + Movies) |
| Sonarr | TV show automation |
| Radarr | Movie automation |
| Prowlarr | Indexer aggregator |
| Transmission | Torrent client |
| Seerr | Media request UI |
| Caddy | Reverse proxy + TLS |
| DuckDNS | Dynamic DNS |
| dnsmasq | LAN DNS override |
| Cron | Scheduled tasks |
| Statuspage | Dashboard + health monitoring |

## Quick Start

```bash
git clone <this-repo>
cd mediaserver
cp .env.example .env      # configure DuckDNS, SMTP, MaxMind credentials
docker compose up -d
# Complete Jellyfin setup wizard in browser
./scripts/init-setup.sh   # auto-configures Prowlarr, Sonarr, Radarr, Transmission
# Configure Seerr → Jellyfin in Seerr web UI
```

## Documentation

See the [Wiki](../../wiki) for full documentation:

- [User Guide](../../wiki/User-Guide) — How to request and watch media
- [User Journey](../../wiki/User-Journey) — What happens behind the scenes
- [Requirements](../../wiki/Requirements) — Hardware, software, and accounts
- [Setup](../../wiki/Setup) — Initial setup guide
- [Architecture](../../wiki/Architecture) — System design and media lifecycle
- [Language Preferences](../../wiki/Language-Preferences) — Quality profiles and scoring
- [Notifications](../../wiki/Notifications) — Email notification setup
- [Remote Access](../../wiki/Remote-Access) — DuckDNS + Caddy HTTPS
- [Security Model](../../wiki/Security-Model) — Network isolation and access control
- [Status Page](../../wiki/Status-Page) — Dashboard with health, stats, and activity
- [Maintenance](../../wiki/Maintenance) — Cron jobs and cleanup scripts
- [Backup](../../wiki/Backup) — Automated backup and disaster recovery
- [Troubleshooting](../../wiki/Troubleshooting) — Common issues and fixes
