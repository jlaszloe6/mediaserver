# Media Server

A self-hosted media server stack using Docker Compose. Add movies and TV shows to your Trakt watchlist, and they'll automatically download and appear in Plex. Watched content is cleaned up after 30 days.

## Architecture

```
Trakt Watchlist ──► Sonarr/Radarr ──► Prowlarr ──► Indexers
       ▲                 │                            │
       │                 ▼                            ▼
   Seerr UI         Transmission ◄──────── Torrent Search
  (requests)             │
                         ▼
                    Plex Libraries
                         │
                         ▼
                    Tautulli (watch tracking)
                         │
                         ▼
                    Prunarr (cleanup after 30 days)
```

## Quick Start

```bash
git clone https://github.com/jlaszloe6/mediaserver.git
cd mediaserver
cp .env.example .env  # edit with your API keys
docker compose up -d
```

## Documentation

See the [Wiki](https://github.com/jlaszloe6/mediaserver/wiki) for full documentation:

- [Setup](https://github.com/jlaszloe6/mediaserver/wiki/Setup) - Initial setup guide
- [Trakt Integration](https://github.com/jlaszloe6/mediaserver/wiki/Trakt-Integration) - Watchlist automation
- [Notifications](https://github.com/jlaszloe6/mediaserver/wiki/Notifications) - Email notification setup
- [Maintenance](https://github.com/jlaszloe6/mediaserver/wiki/Maintenance) - Cron jobs and cleanup
