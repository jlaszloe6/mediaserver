# Media Server

A self-hosted media server stack using Docker Compose. Request movies and TV shows via Seerr, and they'll automatically download and appear in Jellyfin. Watched content is cleaned up after 30 days.

Music is managed by Lidarr and served by Navidrome (Subsonic/OpenSubsonic API). Audiobooks are served by Audiobookshelf. See [Music & Audiobooks](#music--audiobooks) below.

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

| Service | Description | LAN Port |
|---------|-------------|----------|
| Jellyfin | Media server (TV + Movies) | 8096 |
| Sonarr | TV show automation | — (internal) |
| Radarr | Movie automation | — (internal) |
| Bazarr | Subtitle automation | — (internal) |
| Prowlarr | Indexer aggregator | — (internal) |
| Transmission | Torrent client | — (internal) |
| Lidarr | Music acquisition automation | 8686 |
| Navidrome | Music server (Subsonic/OpenSubsonic API) | 4533 |
| Audiobookshelf | Audiobook server | 13378 |
| Seerr | Media request UI | — (internal) |
| Caddy | Reverse proxy + TLS | 443 |
| DuckDNS | Dynamic DNS | — (internal) |
| Cron | Scheduled tasks | — (internal) |
| Statuspage | Dashboard + health monitoring | — (internal) |

LAN ports are bound to `$SERVER_IP` only (same pattern as Jellyfin), so they're reachable from your local network but not exposed to the internet. Everything else is internal-only, reachable via Docker service name on the `mediaserver` bridge network, and (for Jellyfin, Seerr, Statuspage, Navidrome, Audiobookshelf) additionally proxied through Caddy for remote HTTPS access.

Lidarr/Sonarr/Radarr/Prowlarr are deliberately NOT proxied through Caddy — they stay LAN-only (VPN back to the LAN if you need remote admin access). Lidarr in particular has no built-in login enabled by default, so exposing it publicly would give unauthenticated internet access to its admin UI.

## Music & Audiobooks

```
Music:      Lidarr ──► Prowlarr ──► Indexers ──► Transmission ──► /media/music ──► Navidrome ──► Tempo/Tempus (Android)
Audiobooks: Transmission (manual grab, "audiobooks" category) ──► scripts/audiobook-import.sh ──► /media/audiobooks ──► Audiobookshelf ──► Audiobookshelf app (Android)
```

There's no Lidarr/Sonarr-equivalent acquisition app for audiobooks (Readarr is discontinued) — search Prowlarr manually, add the torrent to Transmission under the `audiobooks` category, then run `./scripts/audiobook-import.sh` to copy it into `/media/audiobooks` and trigger an Audiobookshelf scan. It copies rather than moves, so nCore's 72h seeding requirement is unaffected, and it's idempotent — safe to re-run.

### Folder structure

```
$MEDIA_ROOT/
├── media/
│   ├── tv/, movies/, tv-guests/, movies-guests/   (existing)
│   ├── music/          # Lidarr writes here, Navidrome reads here (read-only)
│   └── audiobooks/      # Audiobook files (add manually or via Audiobookshelf)
├── torrents/            # Transmission downloads (shared with Lidarr, same as Sonarr/Radarr)
└── watch/
```

`config/lidarr/`, `config/navidrome/`, and `config/audiobookshelf/{config,metadata}/` hold each service's persistent state, following the same `./config/<service>` convention as the rest of the stack.

### First-run setup

1. `mkdir -p "$MEDIA_ROOT"/media/{music,audiobooks}` (Lidarr/Navidrome/Audiobookshelf don't auto-create these the way `init-setup.sh` does for guest libraries — create them before `docker compose up -d`, owned by the `mediaserver` user).
2. `mkdir -p config/navidrome config/audiobookshelf/config config/audiobookshelf/metadata && chown -R "$PUID:$PGID" config/navidrome config/audiobookshelf`. **This step is required, not optional**: unlike the linuxserver-based services in this stack, Navidrome and Audiobookshelf's official images run directly as the `user:` UID/GID with no startup step that fixes ownership. If Docker is left to auto-create these folders on first `up`, it creates them as `root:root`, and both containers will crash-loop on a database-open failure since they can't write as a non-root user. Sonarr/Radarr/Bazarr/Lidarr are unaffected — they're linuxserver images that self-correct ownership via PUID/PGID.
3. `docker compose up -d` — brings up `lidarr`, `navidrome`, `audiobookshelf` alongside the rest of the stack.
4. **Lidarr** (`http://$SERVER_IP:8686`): complete the setup wizard, add `/data/media/music` as a root folder, add Transmission as a download client (same host/port/credentials as in Sonarr/Radarr), and add Lidarr as an application in **Prowlarr → Settings → Apps** so indexers sync automatically (mirrors the existing Sonarr/Radarr sync). Copy the API key into `.env` as `LIDARR_API_KEY`.
5. **Navidrome** (`http://$SERVER_IP:4533`): create the admin account on first visit; it auto-scans `/music` on startup and picks up new albums as Lidarr downloads them.
6. **Audiobookshelf** (`http://$SERVER_IP:13378`): create the admin account, then add an Audiobooks library pointed at `/audiobooks`. Create an API key (Settings → Users → API Keys — must be created with **Active** checked, the API defaults new keys to inactive) and copy it into `.env` as `AUDIOBOOKSHELF_API_KEY` for `scripts/audiobook-import.sh` to use.
7. Note: `init-setup.sh` and `backup.sh` do not yet automate these three services (unlike Sonarr/Radarr/Prowlarr) — steps above are manual for now, and their configs won't be included in the nightly backup until those scripts are extended.

### Recommended Android apps

| App | Use case | Notes |
|-----|----------|-------|
| [Tempo](https://github.com/CappielloAntonio/tempo) or Tempus | Music playback from Navidrome | FOSS, Subsonic/OpenSubsonic client. Prefer the GitHub/F-Droid build over the Play Store build if Android Auto support differs between them. |
| Audiobookshelf app (official) | Audiobooks, server-synced playback progress | FOSS, syncs position across devices via the server. |

### Android Auto

- **Tempo/Tempus**: exposes a standard media-browser interface to Android Auto for artist/album/playlist browsing, same as any Subsonic client — no extra config needed beyond pairing the app with Navidrome.
- **Audiobookshelf app**: supports Android Auto for browsing and playback controls.
- Both are reachable away from home (e.g. driving) via Caddy + DuckDNS, same pattern as Jellyfin/Seerr: `$CADDY_DOMAIN_NAVIDROME` and `$CADDY_DOMAIN_AUDIOBOOKSHELF`. Point the mobile apps at those HTTPS URLs instead of the LAN IP if you want them to work off-network. GeoIP filtering (see [Security Model](../../wiki/Security-Model)) applies the same as it does for Jellyfin/Seerr — only LAN IPs and the allowed country pass through.

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
