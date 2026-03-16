# Media Server

A self-hosted media server stack using Docker Compose. Add movies and TV shows to your Trakt watchlist, and they'll automatically download and appear in Plex. Watched content is cleaned up after 30 days.

## Architecture

```
                         ┌─────────────────────────────────────┐
                         │           DOWNLOAD FLOW             │
                         └─────────────────────────────────────┘

Trakt Watchlist ◄─► Sonarr/Radarr ──► Prowlarr ──► Indexers
                      ▲    │                          │
              Seerr ──┘    ▼                          ▼
            (requests) Transmission ◄──────── Torrent Search
                            │
                            ▼
                       Plex Libraries

                         ┌─────────────────────────────────────┐
                         │           CLEANUP FLOWS             │
                         └─────────────────────────────────────┘

Watched 30+ days ago ──► Tautulli ──► Prunarr ──► delete from Sonarr/Radarr
Remove from Trakt   ──► trakt-sync.sh ──────────► delete from Sonarr/Radarr
Delete from Plex    ──► plex-cleanup.sh ─────────► delete from Sonarr/Radarr
```

## Quick Start

```bash
git clone <this-repo>
cd mediaserver
cp .env.example .env      # add PLEX_TOKEN and DuckDNS credentials
docker compose up -d
./scripts/init-setup.sh   # auto-configures Prowlarr, Sonarr, Radarr, Transmission, Tautulli
./scripts/init-setup.sh --trakt  # interactive Trakt watchlist setup
```

## Documentation

See the [Wiki](../../wiki) for full documentation:

- [User Guide](../../wiki/User-Guide) - How to request and watch media
- [User Journey](../../wiki/User-Journey) - What happens behind the scenes for every action
- [Requirements](../../wiki/Requirements) - Hardware, software, and network requirements
- [Setup](../../wiki/Setup) - Initial setup guide
- [Trakt Integration](../../wiki/Trakt-Integration) - Watchlist automation
- [Language Preferences](../../wiki/Language-Preferences) - Prioritize dual-audio releases in your preferred language
- [Notifications](../../wiki/Notifications) - Email notification setup
- [Remote Access](../../wiki/Remote-Access) - DuckDNS + Caddy HTTPS reverse proxy
- [Monitoring](../../wiki/Monitoring) - Uptime Kuma service monitoring and alerts
- [Status Page](../../wiki/Status-Page) - Dashboard with service health, library stats, and activity
- [Maintenance](../../wiki/Maintenance) - Cron jobs and cleanup
