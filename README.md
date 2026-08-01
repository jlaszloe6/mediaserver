# Media Server

A self-hosted media stack running on Docker Compose. Request a movie or show through Seerr and it downloads, gets organized, and shows up in Jellyfin automatically — no manual searching, no manual filing. Music and audiobooks follow their own, lighter-weight pipelines. Everything is watched over by a small cron fleet that keeps storage clean and emails the owner when something needs attention.

Built for a single-operator homelab: one admin, a handful of trusted guests, internet exposure limited to a single reverse-proxied port.

## Architecture

```
                              ┌───────────────────────────────────┐
                              │            REQUEST FLOW            │
                              └───────────────────────────────────┘

     Seerr ──(request)──► Sonarr / Radarr ──(search)──► Prowlarr ──(query)──► Indexers
                                  ▲                                              │
                                  └────────────────(release list)────────────────┘
                                  │
                                  ├──(sends chosen release)──► Transmission (downloads)
                                  │
                                  └──(monitors, imports on completion)──► Jellyfin Libraries
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
| **Transmission** | Torrent client | Peer port (`:51413`, TCP+UDP) internet-facing — required for peer connectivity |
| **Lidarr** | Music acquisition | LAN (`:8686`) |
| **Navidrome** | Music server (Subsonic/OpenSubsonic API) | LAN (`:4533`) + Caddy |
| **Audiobookshelf** | Audiobook server | LAN (`:13378`) + Caddy |
| **Statuspage** | Health dashboard, guest onboarding, alerts | Internal only + Caddy |
| **Caddy** | Reverse proxy, TLS, GeoIP filter | **Public** (`:443`) |
| **DuckDNS** | Dynamic DNS updater | Internal only |
| **Cron** | Scheduled maintenance (see below) | Internal only |
| **Ebook Pipeline** | Automated torrent-to-Audiobookshelf ebook pipeline | Internal only |

Every LAN-bound port is bound to `$SERVER_IP` specifically, not `0.0.0.0` — reachable from the local network, not the internet. Everything else talks over the internal `mediaserver` bridge network by Docker service name. Caddy's `:443` and Transmission's `:51413` (TCP+UDP, deliberately `0.0.0.0` — torrent peer connectivity requires it) are the only ports published to the internet. Only Jellyfin, Seerr, Statuspage, Navidrome, and Audiobookshelf are proxied through Caddy for remote HTTPS access, behind GeoIP filtering.

Sonarr, Radarr, Prowlarr, and Lidarr are deliberately **not** proxied — their admin UIs stay LAN-only. Reach them remotely over a VPN back to the LAN if needed. (Lidarr in particular ships with no authentication enabled by default.)

Full write-up: [Security Model](../../wiki/Security-Model).

## Music & Audiobooks

```
Music:      Lidarr ──► Prowlarr ──► Indexers ──► Transmission ──► /media/music ──► Navidrome ──► Tempo/Tempus (Android)
Audiobooks: Transmission (manual grab) ──► audiobook-import.sh ──► /media/audiobooks ──► Audiobookshelf ──► app (Android)
Ebooks:     drop .torrent in /watch-ebooks ──► ebook-pipeline (RPC add) ──► Transmission ──► ebook-pipeline (convert+organize) ──► /media/ebooks ──► Audiobookshelf ──► app / Kindle
```

There's no Sonarr/Radarr-equivalent acquisition app for audiobooks (Readarr is discontinued): search Prowlarr manually, grab the torrent into Transmission under the `audiobooks` category, then run `./scripts/audiobook-import.sh` to copy it into place and trigger an Audiobookshelf scan. It copies rather than moves, so tracker seeding requirements are unaffected, and it's safe to re-run.

**First-run setup**, once, before `docker compose up -d`:

1. `mkdir -p "$MEDIA_ROOT"/media/{music,audiobooks,ebooks} "$MEDIA_ROOT"/watch-ebooks "$MEDIA_ROOT"/torrents/complete/ebooks-incoming`
2. `mkdir -p config/navidrome config/audiobookshelf/{config,metadata} && chown -R "$PUID:$PGID" config/navidrome config/audiobookshelf` — **required**. Unlike the linuxserver images in this stack, Navidrome and Audiobookshelf run directly as the configured `user:` UID/GID with no ownership-fixing entrypoint. Left to Docker's auto-create, these folders come up `root:root` and both containers crash-loop on a database-open failure.
3. Complete each service's setup wizard: Lidarr (`:8686`, add `/data/media/music` as root folder, wire up Transmission + Prowlarr same as Sonarr/Radarr), Navidrome (`:4533`, auto-scans on startup), Audiobookshelf (`:13378`, add an `/audiobooks` library and a separate `/ebooks` library, create an **active** API key for `audiobook-import.sh` and `ebook-pipeline.sh` — the same key works for both).

Ebooks have a fully automated pipeline: drop a `.torrent` file into `$MEDIA_ROOT/watch-ebooks` (**not** `$MEDIA_ROOT/watch` — that's Transmission's own native watch-dir, already used for general downloads) and the `ebook-pipeline` container adds it to Transmission over its RPC API instead (not Transmission's native watch-dir — that only supports one global download destination, which can't route ebook torrents to their own folder, and sharing the same folder would race this pipeline's 5-minute poll against Transmission's own few-second watch-dir scan), waits for it to finish, extracts title/author from the ebook file itself with Calibre's `ebook-meta`, converts to epub with `ebook-convert` if needed, and copies the result into `/media/ebooks/Author/Title/` before triggering an Audiobookshelf scan and emailing a report. Manually adding files to `/media/ebooks` directly and triggering a scan still works too, e.g. for a Calibre export that didn't come via torrent. **epub is the standard format for this library**: Audiobookshelf only tracks reading progress for epub, not mobi/azw3, and epub is the safest bet for Amazon's Send-to-Kindle (which doesn't officially support azw3 or the older prc/Mobipocket extension). Keep one book per `Author/Title/` folder (never mix a flat ebook file directly under an author folder alongside title subfolders) — Audiobookshelf's folder-as-item detection gets confused by the mix and misfiles the item.

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
| daily, 04:00 | `log-rotate.sh` | Caps `/var/log/cron/*.log` files at 10MB (also runs in `ebook-pipeline`'s own crontab) |

`transmission-cleanup.sh` (tracker-aware orphan/H&R cleanup) runs at the end of `jellyfin-cleanup.sh` rather than on its own schedule.

## Editing `.env` on a live server

Use `scripts/env-set.sh` to change a value in `.env`, not `sed -i` or a manual
temp-file-and-`mv`:

```bash
./scripts/env-set.sh KEY=VALUE
# or, to target a different file:
ENV_FILE=/path/to/.env ./scripts/env-set.sh KEY=VALUE
```

`sed -i` (and any edit that renames a temp file over `.env`'s path) gives the
file a **new inode**. Containers with `.env` already bind-mounted keep
referencing the old inode, so they silently keep serving the pre-edit content
— `cat .env` on the host looks correct, but nothing actually changed from the
container's point of view — until that container happens to be recreated for
an unrelated reason. `env-set.sh` avoids this by writing the new content into
the *existing* file in place (truncate + write) instead of swapping in a
different inode.

That said, inode preservation only fixes containers that re-read `.env` from
disk continuously (e.g. via `set -a; source .env` in a script that runs on
every cron tick). Services whose environment variables are loaded once at
container startup (anything under `environment:`/`env_file:` in
`docker-compose.yml`) only pick up the new value on their *next start* —
you still need `docker compose up -d --force-recreate <service>` for those,
same as before.

## Quick Start

```bash
git clone git@github.com:jlaszloe6/mediaserver.git
cd mediaserver
cp .env.example .env        # fill in DuckDNS, SMTP, MaxMind, backup key, etc.
docker compose up -d
# 1. Jellyfin (http://localhost:8096): complete the setup wizard, then create
#    an API key (Dashboard -> API Keys) and add it to .env as JELLYFIN_API_KEY -
#    needed below to create the guest libraries.
# 2. Seerr (http://localhost:5055): complete the setup wizard and connect
#    Jellyfin/Sonarr/Radarr BEFORE the next step, so it has a configured
#    instance for init-setup.sh to enable sync on. Then copy its API key
#    (config/overseerr/settings.json -> main.apiKey) into .env as
#    SEERR_API_KEY - without it, init-setup.sh skips the Seerr sync step
#    entirely (it only auto-configures Prowlarr/Sonarr/Radarr/Transmission).
docker exec cron /scripts/init-setup.sh
# init-setup.sh uses Docker service names (sonarr:8989, etc.) for all its API
# calls, so it must run inside a container already on the mediaserver bridge
# network - it will not resolve those hostnames run directly on the host.
# 3. init-setup.sh re-reads .env fresh on every run, so it already sees the
#    keys from steps 1-2 with no extra step needed. Statuspage, on the
#    other hand, gets these same keys baked in at container start via
#    docker-compose's `environment:` block - it needs an explicit recreate
#    to pick up ones added to .env after it was already running:
docker compose up -d --force-recreate statuspage
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
