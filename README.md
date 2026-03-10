# Media Server

A self-hosted media server stack using Docker Compose. Add movies and TV shows to your Trakt watchlist, and they'll automatically download and appear in Plex. Watched content is cleaned up after 30 days.

## Architecture

```
Trakt Watchlist ──► Sonarr/Radarr ──► Prowlarr ──► Indexers
  │    ▲                 │                            │
  │    │                 ▼                            ▼
  │  Seerr UI       Transmission ◄──────── Torrent Search
  │ (requests)           │
  │                      ▼
  │                 Plex Libraries
  │                      │
  │                      ▼
  │                 Tautulli (watch tracking)
  │                      │
  │                      ▼
  │                 Prunarr (cleanup after 30 days)
  │
  ▼ Remove from watchlist or delete from Plex
trakt-sync.sh / plex-cleanup.sh ──► auto-delete from Sonarr/Radarr + Plex
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

- [Setup](../../wiki/Setup) - Initial setup guide
- [Trakt Integration](../../wiki/Trakt-Integration) - Watchlist automation
- [Notifications](../../wiki/Notifications) - Email notification setup
- [Maintenance](../../wiki/Maintenance) - Cron jobs and cleanup
