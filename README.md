# Media Server

A self-hosted media stack running on Docker Compose. Request a movie or show through Seerr and it downloads, gets organized, and shows up in Jellyfin automatically — no manual searching, no manual filing. Music and audiobooks follow their own, lighter-weight pipelines. Everything is watched over by a small cron fleet that keeps storage clean and emails the owner when something needs attention.

Built for a single-operator homelab: one admin, a handful of trusted guests, internet exposure limited to a single reverse-proxied port.

## Architecture

```
                              ┌───────────────────────────────────┐
                              │            REQUEST FLOW            │
                              └───────────────────────────────────┘

                Seerr ──► Sonarr / Radarr ──► Prowlarr ──► Indexers
              (requests)      │      ▲                        │
                               │      │                        ▼
                               │      └──────────────── Transmission
                               ▼                               │
                        Jellyfin Libraries ◄────────────────────┘
                               ▲
                               │
                            Bazarr  (fetches missing English subtitles)

                              ┌───────────────────────────────────┐
                              │            CLEANUP FLOWS           │
                              └───────────────────────────────────┘

  Watched 30+ days ago ──► jellyfin-watched-cleanup.sh ──► remove from Sonarr/Radarr
  Deleted in Jellyfin  ──► jellyfin-cleanup.sh ──────────► remove from Sonarr/Radarr
  Stuck/bad imports    ──► queue-cleanup.sh ─────────────► fix or reject
  Orphaned torrents     ──► transmission-cleanup.sh ──────► remove (tracker-aware H&R)
  Pipeline health       ──► pipeline-monitor.sh ──────────► email the admin
```

Music and audiobooks are separate, simpler pipelines — see [Music & Audiobooks](#music--audiobooks).

## Services

| Service | Role | Exposure |
|---|---|---|
| **Jellyfin** | Media server — TV & movies | LAN (`:8096`) + Caddy |
| **Seerr** | Request UI for movies/shows | Internal only |
| **Sonarr** | TV show acquisition | Internal only |
| **Radarr** | Movie acquisition | Internal only |
| **Bazarr** | Subtitle automation for Sonarr/Radarr | Internal only |
| **Prowlarr** | Indexer aggregator, syncs to Sonarr/Radarr/Lidarr | Internal only |
| **Transmission** | Torrent client | LAN peer port (`:51413`) only |
| **Lidarr** | Music acquisition | LAN (`:8686`) |
| **Navidrome** | Music server (Subsonic/OpenSubsonic API) | LAN (`:4533`) + Caddy |
| **Audiobookshelf** | Audiobook server | LAN (`:13378`) + Caddy |
| **Statuspage** | Health dashboard, guest onboarding, alerts | Internal only + Caddy |
| **Caddy** | Reverse proxy, TLS, GeoIP filter | **Public** (`:443`) |
| **DuckDNS** | Dynamic DNS updater | Internal only |
| **Cron** | Scheduled maintenance (see below) | Internal only |

Every LAN-bound port is bound to `$SERVER_IP` specifically, not `0.0.0.0` — reachable from the local network, not the internet. Everything else talks over the internal `mediaserver` bridge network by Docker service name. Only Caddy's `:443` is published to the internet, and only Jellyfin, Seerr, Statuspage, Navidrome, and Audiobookshelf are proxied through it for remote HTTPS access, behind GeoIP filtering.

Sonarr, Radarr, Prowlarr, and Lidarr are deliberately **not** proxied — their admin UIs stay LAN-only. Reach them remotely over a VPN back to the LAN if needed. (Lidarr in particular ships with no authentication enabled by default.)

Full write-up: [Security Model](../../wiki/Security-Model).

## Music & Audiobooks

```
Music:      Lidarr ──► Prowlarr ──► Indexers ──► Transmission ──► /media/music ──► Navidrome ──► Tempo/Tempus (Android)
Audiobooks: Transmission (manual grab) ──► audiobook-import.sh ──► /media/audiobooks ──► Audiobookshelf ──► app (Android)
```

There's no Sonarr/Radarr-equivalent acquisition app for audiobooks (Readarr is discontinued): search Prowlarr manually, grab the torrent into Transmission under the `audiobooks` category, then run `./scripts/audiobook-import.sh` to copy it into place and trigger an Audiobookshelf scan. It copies rather than moves, so tracker seeding requirements are unaffected, and it's safe to re-run.

**First-run setup**, once, before `docker compose up -d`:

1. `mkdir -p "$MEDIA_ROOT"/media/{music,audiobooks}`
2. `mkdir -p config/navidrome config/audiobookshelf/{config,metadata} && chown -R "$PUID:$PGID" config/navidrome config/audiobookshelf` — **required**. Unlike the linuxserver images in this stack, Navidrome and Audiobookshelf run directly as the configured `user:` UID/GID with no ownership-fixing entrypoint. Left to Docker's auto-create, these folders come up `root:root` and both containers crash-loop on a database-open failure.
3. Complete each service's setup wizard: Lidarr (`:8686`, add `/data/media/music` as root folder, wire up Transmission + Prowlarr same as Sonarr/Radarr), Navidrome (`:4533`, auto-scans on startup), Audiobookshelf (`:13378`, add an `/audiobooks` library, create an **active** API key for `audiobook-import.sh`).

Recommended clients: [Tempo](https://github.com/CappielloAntonio/tempo)/Tempus for Navidrome, the official Audiobookshelf app — both support Android Auto and both work off-LAN through Caddy + DuckDNS.

## Maintenance

Cron runs the following on a schedule, all logged and most wired to email the admin on failure:

| Schedule | Script | What it does |
|---|---|---|
| every minute | `jellyfin-scan.sh` | Triggers a Jellyfin library scan |
| `*/30` | `jellyfin-cleanup.sh` | Detects Jellyfin-side deletions, removes from Sonarr/Radarr |
| `*/30` | `queue-cleanup.sh` | Fixes stuck imports, rejects suspicious downloads |
| `*/30` | `pipeline-monitor.sh` | Checks pipeline health, emails the admin on issues |
| daily, 02:30 | `backup.sh` | Encrypted config backup to NAS |
| daily, 03:00 | `jellyfin-watched-cleanup.sh` | Removes media watched 30+ days ago |
| weekly (Sun) | `geodb-update.sh` | Refreshes the GeoIP database |

`transmission-cleanup.sh` (tracker-aware orphan/H&R cleanup) runs at the end of `jellyfin-cleanup.sh` rather than on its own schedule.

## Quick Start

```bash
git clone git@github.com:jlaszloe6/mediaserver.git
cd mediaserver
cp .env.example .env        # fill in DuckDNS, SMTP, MaxMind, backup key, etc.
docker compose up -d
# complete the Jellyfin setup wizard in a browser
./scripts/init-setup.sh     # auto-configures Prowlarr, Sonarr, Radarr, Transmission
# point Seerr at Jellyfin in its web UI
```

For a fresh server (not just a fresh stack), start with `scripts/server-setup.sh` — see [Setup](../../wiki/Setup).

## Documentation

Deeper documentation lives in the [Wiki](../../wiki):

- [User Guide](../../wiki/User-Guide) — how to request and watch media
- [User Journey](../../wiki/User-Journey) — what happens behind the scenes
- [Requirements](../../wiki/Requirements) — hardware, software, accounts
- [Setup](../../wiki/Setup) — initial setup guide
- [Architecture](../../wiki/Architecture) — system design and media lifecycle
- [Language Preferences](../../wiki/Language-Preferences) — quality profiles and scoring
- [Notifications](../../wiki/Notifications) — email notification setup
- [Remote Access](../../wiki/Remote-Access) — DuckDNS + Caddy HTTPS
- [Security Model](../../wiki/Security-Model) — network isolation and access control
- [Status Page](../../wiki/Status-Page) — dashboard with health, stats, and activity
- [Maintenance](../../wiki/Maintenance) — cron jobs and cleanup scripts in detail
- [Backup](../../wiki/Backup) — automated backup and disaster recovery
- [Troubleshooting](../../wiki/Troubleshooting) — common issues and fixes

Security issues: see [SECURITY.md](SECURITY.md) rather than opening a public issue.
