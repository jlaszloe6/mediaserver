# Media Server v2.0

`SERVER_NAME` env var controls the display name used in emails, status page, and notifications (default: "Media Server").

Docker Compose stack running on the server (`$SERVER_IP`). Runtime directory: `/opt/mediaserver` (owned by dedicated `mediaserver` system user). Code repo on development machine, deployed via GitHub Actions self-hosted runner.

## Stack

Services: Jellyfin, Transmission, Sonarr, Radarr, Prowlarr, Seerr, Caddy, DuckDNS, Cron, Statuspage

### Networking
- Custom bridge network `mediaserver` for all services
- All inter-container communication via Docker service names: `jellyfin`, `sonarr`, `radarr`, `prowlarr`, `transmission`, `seerr`, `caddy`, `statuspage`
- Only published ports: Caddy 443 (HTTPS), Jellyfin 8096 (LAN), Transmission 51413 (torrent peers)
- LAN clients access Jellyfin directly via `http://SERVER_IP:8096`, remote access via DuckDNS domain through Caddy

### Storage & Boot
- Media on NFS (NAS) — inotify doesn't work over NFS
- Docker depends on `remote-fs.target` via drop-in `/etc/systemd/system/docker.service.d/wait-for-nfs.conf`
- Volume mappings: Sonarr/Radarr → `/data`, Transmission → `/downloads`, Jellyfin → `/tv` + `/movies`

## Runtime Separation
- Runtime directory: `/opt/mediaserver` (NOT developer home directory)
- Dedicated `mediaserver` system user (no login shell, in docker group) owns the runtime
- Developer user (`janoslaszlo`) keeps code repo at `~/Documents/mediaserver`
- PUID/PGID env vars in `.env` match the `mediaserver` user's UID/GID
- Container file ownership aligns with the service user, not the developer
- Seerr runs as UID 1000 internally (not PUID/PGID), config dir must be owned by 1000:1000

## CI/CD
- GitHub Actions self-hosted runner on the server, working directory `/opt/mediaserver`
- Deploy workflow detects changed custom-build services (statuspage, cron, caddy) and rebuilds only those
- `docker-compose.yml` changes trigger `docker compose up -d --no-build --no-recreate` for new services
- Master branch is protected — all changes go through PRs

## Caddy Reverse Proxy
- Custom build with duckdns DNS plugin + maxmind GeoIP plugin
- Caddyfile uses env vars: `$CADDY_DOMAIN_JELLYFIN`, `$CADDY_DOMAIN_SEERR`, `$CADDY_DOMAIN_STATUS`
- Reverse proxies to Docker service names on bridge network (jellyfin:8096, seerr:5055, statuspage:8080)
- GeoIP country filter via MaxMind GeoLite2-Country (allowed countries configurable), LAN IPs pass through
- TLS via Let's Encrypt DNS-01 challenge (auto-renewal)
- Build requires `network: host` in compose (IPv6 unreachable in default bridge)
- Only container with port 443 published

## Jellyfin
- Image: `lscr.io/linuxserver/jellyfin:latest` (supports PUID/PGID)
- Libraries: TV Shows `/tv`, Movies `/movies`
- V4L2 hardware transcoding available on ARM, Intel QuickSync on x86

## Prowlarr Indexers
- Indexers: EZTV, YTS, The Pirate Bay, LimeTorrents, Knaben
- Prowlarr syncs to Sonarr + Radarr via `ApplicationIndexerSync` (fullSync)
- Transmission download client: ratio 2.0, idle 30 min

## Quality & Language Preferences
- Profile "HD-1080p Max" (id=1): prefers Bluray-1080p, 4K as fallback only
- Custom format scores configured for preferred language + original audio
- 4K only works via direct play on hardware that cannot software transcode it

## Cron Jobs
| Schedule | Command | Description |
|----------|---------|-------------|
| `*/30 * * * *` | `jellyfin-cleanup.sh` | Detect Jellyfin deletions, remove from Sonarr/Radarr |
| `*/30 * * * *` | `queue-cleanup.sh` | Auto-fix stuck imports, reject suspicious files |
| `0 3 * * *` | `jellyfin-watched-cleanup.sh` | Remove media watched 30+ days ago |
| `*/15 * * * *` | `jellyfin-scan.sh` | Trigger Jellyfin library scan (covers manual additions) |
| `30 2 * * *` | `backup.sh` | Config backup to NAS |
| `0 2 * * 0` | `geodb-update.sh` | Weekly GeoIP DB refresh |

`transmission-cleanup.sh` runs at end of jellyfin-cleanup.sh (no separate cron entry).

## Transmission Orphan Cleanup
- Tracker-aware H&R policy: public → remove immediately, nCore → seed 72h minimum
- `HNR_TRACKERS` array in script: `ncore.pro:72`, `ncore.sh:72`
- Orphan detection: cross-references torrent hashes against Sonarr/Radarr download history
- Does NOT touch manually added torrents or active downloads

## Jellyfin Cleanup Script
- `jellyfin-cleanup.sh` detects library deletions via state file diff
- Triggers RescanMovie/RescanSeries, compares hasFile/sizeOnDisk
- Adds import exclusion on deletion (prevents re-import)

## Jellyfin Watched Cleanup
- `jellyfin-watched-cleanup.sh` replaces Prunarr
- Queries Jellyfin API for played items per user
- Removes from Sonarr/Radarr if watched 30+ days ago (with import exclusion)
- Matches by TMDB ID (movies) and TVDB ID (series)

## Status Page
- Flask + SQLite, bridge network (port 8080), magic link auth
- Modular structure: `app.py` (init) → `config.py`, `db.py`, `auth.py`, `services/*`, `routes/*`
- Blueprints: `auth_bp`, `dashboard_bp`, `guests_bp` — all `url_for` calls use blueprint prefix
- Cloudflare Turnstile captcha on login form
- Session cookies: Secure, HttpOnly, SameSite=Lax
- Dashboard: service health, library stats, active downloads, recent activity (local time, readable labels)
- Custom error pages (400, 403, 404, 500) with dark theme
- Favicon logo on all pages (login, dashboard, errors)
- All emails use dark theme template with logo, sender name from `SERVER_NAME` env var
- Guest onboarding: admin invites via dashboard, auto-creates Jellyfin user, sends welcome email with credentials
- Admin = first `ALLOWED_EMAILS` entry or explicit `ADMIN_EMAIL` env var
- Guests stored in SQLite `guests` table (supplement `ALLOWED_EMAILS` env var)
- Guest library isolation: separate Jellyfin libraries (Guest Movies `/movies-guests`, Guest TV Shows `/tv-guests`)
- Guest Jellyfin users auto-restricted to guest libraries via `EnableAllFolders=false` + `EnabledFolders`
- Sonarr/Radarr have guest root folders (`/data/media/movies-guests`, `/data/media/tv-guests`)
- Seerr guest setup automated: invite flow imports user into Seerr and sets guest root folders

## Email Notifications
- Sonarr/Radarr: onImportComplete, onUpgrade, onHealthIssue (onGrab disabled — low value noise)
- Status page: login links, user guide
- queue-cleanup.sh: owner alerts for suspicious files and stuck downloads
- Seerr: per-user request status updates
- `disable-ongrab.sh`: one-time utility, run via `docker exec cron /scripts/disable-ongrab.sh`

## Seerr
- Image: `ghcr.io/seerr-team/seerr` (not Overseerr)
- Config path: `./config/overseerr` (kept original path for migration, don't rename)
- Bridge network, connects to Jellyfin

## Backup & Restore
- Daily at 2:30 AM via `scripts/backup.sh` (runs in cron container)
- Backups stored on NAS at `$BACKUP_DIR` (default: `$MEDIA_ROOT/backups`)
- Retention: `$BACKUP_RETENTION_DAYS` (default: 14)
- SQLite safe snapshots via `sqlite3 .backup` on mounted config files (no Docker socket needed)
- Services backed up: Sonarr, Radarr, Prowlarr, Jellyfin, Statuspage
- Jellyfin transcodes/cache excluded (regenerable)
- `.env` file included in every backup
- Manifest file tracks which services were backed up and any warnings
- Restore: `scripts/restore.sh` (runs on host) — `--list`, `--dry-run`, latest or specific backup
- Restore stops containers, extracts configs, restores SQLite backups, cleans WAL/SHM journals, restarts

## Reboot Resilience
- All containers use `restart: unless-stopped` — auto-start after reboot
- Docker waits for NFS via systemd `remote-fs.target` drop-in
- `scripts/reboot-test.sh` verifies post-reboot health: NFS, containers, docker health status, SQLite, cron, TLS, backups

## Disaster Recovery
- `scripts/server-setup.sh` provisions a fresh Ubuntu server (user, NFS, firewall, PAM, systemd)
- Backup includes: all service configs, .env, SSH deploy keys, SQLite snapshots
- Full recovery procedure: fresh Ubuntu → `server-setup.sh` → clone repo → `restore.sh` → `init-setup.sh` → Jellyfin setup wizard (browser)
- Jellyfin setup wizard and Seerr configuration require browser interaction (cannot be fully automated)

## Host Security
- Only port 443 exposed to internet (via Caddy with GeoIP filter)
- UFW: SSH from LAN only, DNS from LAN only, 443/tcp, deny all else
- No Docker socket mounted in any container
- No host-networked containers
- All other services isolated in bridge network
