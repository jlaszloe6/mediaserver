# Media Server

Docker Compose stack running on **freya-pc** (192.168.1.14). Code repo on development machine, deployed via GitHub Actions self-hosted runner.

## Stack

Services: Plex, Transmission, Sonarr, Radarr, Prowlarr, FlareSolverr, Tautulli, Prunarr, Seerr, Caddy, DuckDNS, Uptime Kuma, WG-Easy, Cron, Statuspage, dnsmasq
Guest instances: Sonarr-Guest, Radarr-Guest, Prunarr-Guest

### Networking
- Host network: Plex, Tautulli, Prunarr, Seerr, Caddy, Uptime Kuma, Statuspage, WG-Easy, Cron, dnsmasq
- Bridge network: Sonarr, Radarr, Prowlarr, Transmission, FlareSolverr, Sonarr-Guest, Radarr-Guest
- Bridge-to-host blocked by firewall; use host networking when container needs to reach Plex
- Docker service names for inter-container communication: `prowlarr`, `sonarr`, `radarr`, `transmission`, `flaresolverr`

### Storage & Boot
- Media on NFS (`192.168.1.76:/volume1/cluster-data/mediaserver`) — inotify doesn't work over NFS
- Docker depends on `remote-fs.target` via drop-in `/etc/systemd/system/docker.service.d/wait-for-nfs.conf`
- Volume mappings: Sonarr/Radarr → `/data`, Transmission → `/downloads`, Plex → `/tv` + `/movies`

## CI/CD
- GitHub Actions self-hosted runner on freya-pc
- Deploy workflow detects changed custom-build services (statuspage, cron, caddy, dnsmasq) and rebuilds only those
- `docker-compose.yml` changes trigger `docker compose up -d --no-build --no-recreate` for new services
- Master branch is protected — all changes go through PRs

## Caddy Reverse Proxy
- Custom build with duckdns DNS plugin + maxmind GeoIP plugin
- Caddyfile uses env vars: `$CADDY_DOMAIN_PLEX`, `$CADDY_DOMAIN_SEERR`, `$CADDY_DOMAIN_STATUS`
- GeoIP filter: only Hungarian IPs allowed (MaxMind GeoLite2-Country), LAN IPs pass through
- TLS via Let's Encrypt DNS-01 challenge (auto-renewal)
- Build requires `network: host` in compose (IPv6 unreachable in default bridge)

## Plex Library Scanning
- NFS prevents inotify, bridge firewall prevents Sonarr/Radarr→Plex notifications
- Periodic scan: every 15 min (`ScheduledLibraryUpdateInterval=900`), partial scan enabled
- Plex libraries: [1] TV Shows `/tv`, [2] Movies `/movies`, Guest TV `/guest-tv`, Guest Movies `/guest-movies`

## Prowlarr Indexers
- Indexers: 1337x, EZTV, YTS, The Pirate Bay, LimeTorrents, Knaben
- FlareSolverr (port 8191) as proxy for 1337x (Cloudflare challenges)
- Prowlarr syncs to Sonarr + Radarr via `ApplicationIndexerSync` (fullSync)
- Transmission download client: ratio 2.0, idle 30 min

## Quality & Language Preferences
- Profile "HD-1080p Max" (id=1): prefers Bluray-1080p, 4K as fallback only
- Custom format scores: Hungarian+Original +150, English SRT Subs +100, Hungarian Only -50, 4K -200
- i5-6500T cannot software transcode 4K, no Plex Pass for hardware transcoding
- 4K only works via direct play (client "Original" quality)

## Trakt Integration
- Hourly force-refresh via `scripts/trakt-sync.sh` (delete+recreate lists to bust 12h cache)
- `listSyncLevel: keepAndUnmonitor` — remove from Trakt → unmonitor → delete with files
- `forceSave=true` bypasses validation on list creation (needed for empty watchlists)
- Reverse-sync (Phase 3): pushes Sonarr/Radarr content to all users' Trakt watchlists

## Cron Jobs
| Schedule | Command | Description |
|----------|---------|-------------|
| `0 * * * *` | `trakt-sync.sh` | Trakt force-refresh + cleanup + reverse-sync |
| `*/30 * * * *` | `plex-cleanup.sh` | Detect Plex deletions, remove from Sonarr/Radarr |
| `*/30 * * * *` | `queue-cleanup.sh` | Auto-fix stuck imports, reject suspicious files |
| `*/15 * * * *` | `guest-quota.sh` | Enforce guest quota |
| `*/15 * * * *` | `guest-notify.sh` | Email guests on new content |
| `0 3 * * *` | Prunarr movies/series | Cleanup watched 30+ days ago |
| `0 4 * * *` | Prunarr-Guest movies/series | Guest watched cleanup |
| `0 2 * * 0` | GeoIP DB update | Weekly refresh + Caddy reload |

`transmission-cleanup.sh` runs at end of trakt-sync.sh and plex-cleanup.sh (no separate cron entry).

## Transmission Orphan Cleanup
- Tracker-aware H&R policy: public → remove immediately, nCore → seed 72h minimum
- `HNR_TRACKERS` array in script: `ncore.pro:72`, `ncore.sh:72`
- Orphan detection: cross-references torrent hashes against Sonarr/Radarr download history
- Does NOT touch manually added torrents or active downloads

## Plex Cleanup Script
- `plex-cleanup.sh` detects Plex UI deletions via state file diff
- Triggers RescanMovie/RescanSeries, compares hasFile/sizeOnDisk
- Adds import exclusion on deletion (prevents Trakt re-import)

## Status Page
- Flask + SQLite, host network (port 8080), magic link auth
- Cloudflare Turnstile captcha on login and onboard forms
- Dashboard: service health, library stats, active downloads, recent activity, Trakt sync log
- Guest view: filtered stats, quota bar, guest-only downloads
- Self-service onboarding at `/onboard` with VPN auto-creation

## Seerr
- Image: `ghcr.io/seerr-team/seerr` (not Overseerr)
- Config path: `./config/overseerr` (kept original path for migration, don't rename)
- Host network, port 5055

## Tautulli & Prunarr
- Tautulli connected to Plex at 127.0.0.1:32400 (both host network)
- Prunarr: sleep container (CLI tool), invoked via cron `docker exec`
- Cron container needs Docker socket (`/var/run/docker.sock`) for `docker exec`

## dnsmasq (LAN DNS)
- Custom Alpine build, host network, binds to `192.168.1.14:53` only
- Overrides DuckDNS domains to LAN IP (solves hairpin NAT)
- Forwards all other queries to router (`192.168.1.1`)

## WireGuard VPN (wg-easy)
- wg-easy API: create returns `{"success": true}`, must fetch client list for ID
- `WG_PASSWORD` env var used by onboarding to auto-create guest clients
- Split tunnel: `AllowedIPs: 192.168.1.0/24, 10.13.13.0/24`
- DNAT rules in WG_POST_UP for localhost-bound services
- Host requires `route_localnet=1` sysctl

## Guest System
- Separate Sonarr-Guest/Radarr-Guest/Prunarr-Guest pipeline
- Shared storage quota (`GUEST_QUOTA_GB`), enforced by `guest-quota.sh`
- Self-service onboarding: form → admin approval → Trakt auth (2x) → VPN auto-create → Plex auto-share
- `ADMIN_EMAILS` controls who gets onboarding notifications
