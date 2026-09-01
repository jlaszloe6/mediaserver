# Media Server v2.0

`SERVER_NAME` env var controls the display name used in emails, status page, and notifications (default: "Media Server").

Docker Compose stack running on the server (`$SERVER_IP`). Runtime directory: `/opt/mediaserver` (owned by dedicated `mediaserver` system user). Code repo on development machine, deployed via GitHub Actions self-hosted runner.

## Stack

Services: Jellyfin, Transmission, Sonarr, Radarr, Prowlarr, Bazarr, Seerr, Caddy, DuckDNS, Cron, Statuspage

### Networking
- Custom bridge network `mediaserver` for all services
- All inter-container communication via Docker service names: `jellyfin`, `sonarr`, `radarr`, `prowlarr`, `transmission`, `seerr`, `caddy`, `statuspage`
- Only published ports: Caddy 443 (HTTPS), Jellyfin 8096, Lidarr 8686, Navidrome 4533, Audiobookshelf 13378, Seerr 5055 (all LAN-only, bound to `$SERVER_IP`), Transmission 51413 TCP+UDP (torrent peers, deliberately internet-facing)
- LAN clients access Jellyfin directly via `http://SERVER_IP:8096`, remote access via DuckDNS domain through Caddy

### Storage & Boot
- Media on NFS (NAS) — inotify doesn't work over NFS
- Docker depends on `remote-fs.target` via drop-in `/etc/systemd/system/docker.service.d/wait-for-nfs.conf`
- Volume mappings: Sonarr/Radarr → `/data`, Transmission → `/downloads`, Jellyfin → `/tv` + `/movies`

## Runtime Separation
- Runtime directory: `/opt/mediaserver` (NOT developer home directory)
- Dedicated `mediaserver` system user (no login shell, in docker group) owns the runtime
- Developer user (`janoslaszlo`) keeps code repo at `~/Documents/projects/mediaserver`
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
- Caddyfile uses env vars: `$CADDY_DOMAIN_JELLYFIN`, `$CADDY_DOMAIN_SEERR`, `$CADDY_DOMAIN_STATUS`, `$CADDY_DOMAIN_NAVIDROME`, `$CADDY_DOMAIN_AUDIOBOOKSHELF`
- Reverse proxies to Docker service names on bridge network (jellyfin:8096, seerr:5055, statuspage:8080, navidrome:4533, audiobookshelf:13378)
- Lidarr/Sonarr/Radarr/Prowlarr are intentionally NOT proxied — admin UIs stay LAN-only (Lidarr in particular has no built-in auth enabled)
- GeoIP country filter via MaxMind GeoLite2-Country (allowed countries configurable), LAN IPs pass through — one deliberate exception: Audiobookshelf's `/feed/*` and `/audiobookshelf/feed/*` (public podcast RSS feed, canonical + compatibility form) bypass this on that same vhost, see Podcasts below
- TLS via Let's Encrypt DNS-01 challenge (auto-renewal)
- Build requires `network: host` in compose (IPv6 unreachable in default bridge)
- Only container with port 443 published

## Jellyfin
- Image: `lscr.io/linuxserver/jellyfin:latest` (supports PUID/PGID)
- Libraries: TV Shows `/tv`, Movies `/movies`
- V4L2 hardware transcoding available on ARM, Intel QuickSync on x86

## Prowlarr Indexers
- Active indexers: YTS, The Pirate Bay, LimeTorrents, Knaben, nCore
- EZTV and 1337x are configured but disabled — both now sit behind Cloudflare's bot challenge (`CloudFlareProtectionException`, needs FlareSolverr), failing since 2026-03 with a rolling ~24h auto-disable/retry cycle that never resolved. Deliberately not running FlareSolverr for two dead indexers when 5 others already cover movies+TV — would add an always-on component that itself needs re-fighting as Cloudflare's challenge evolves. `init-setup.sh` no longer provisions EZTV on fresh installs; 1337x was never in that script.
- Prowlarr syncs to Sonarr + Radarr via `ApplicationIndexerSync` (fullSync)
- Transmission download client: ratio 2.0, idle 30 min

## Bazarr Subtitles
- Image: `lscr.io/linuxserver/bazarr:latest` (PUID/PGID), internal-only (no published port)
- Volume `${MEDIA_ROOT}:/data` matches Sonarr/Radarr exactly so episode/movie paths map 1:1 (no Bazarr path mappings needed)
- Connects to `sonarr:8989` and `radarr:7878` via their API keys; pulls media lists and writes sidecar `.srt` next to each file
- Language profile: English only (matches [[user_language_preferences]] — English content → English subs)
- Providers: free no-account ones enabled by default (OpenSubtitles.com optional, needs account)
- Admin UI on port 6767 — reach via SSH tunnel: `ssh -L 6767:localhost:6767 freya-pc`
- Many older releases lack English sub tracks (esp. French "MULTI" releases that embed only French subs) — Bazarr backfills these
- Automatic audio-based sync (bundled ffsubsync, `subsync.use_subsync: true`) fires whenever Bazarr downloads a subtitle, but NOT when the underlying video file is later replaced (season-pack repack, quality upgrade, manual re-grab) — the existing subtitle stays on disk unchanged and can silently drift out of sync with the new file. `scripts/subtitle-sync-check.sh` (every 30 min) closes this gap: it watches Sonarr/Radarr history for `downloadFolderImported` events and re-triggers Bazarr's sync action (`PATCH /api/subtitles`, action=sync) on that episode/movie's existing external subtitles. State-tracked by history record id per service — first run seeds state without backfilling. Requires `BAZARR_API_KEY` in `.env` (from `config/bazarr/config/config.yaml` → `auth.apikey`)

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
| `* * * * *` | `jellyfin-scan.sh` | Trigger Jellyfin library scan (covers manual additions) |
| `*/30 * * * *` | `pipeline-monitor.sh` | Check pipeline health, email admin on issues |
| `*/30 * * * *` | `subtitle-sync-check.sh` | Resync existing subtitles after Sonarr/Radarr imports a new/upgraded video file |
| `30 2 * * *` | `backup.sh` | Config backup to NAS |
| `0 2 * * 0` | `geodb-update.sh` | Weekly GeoIP DB refresh |
| `0 4 * * *` | `log-rotate.sh` | Cap `/var/log/cron/*.log` files at 10MB (also runs in `ebook-pipeline`'s own crontab, for its own separate log volume) |

`transmission-cleanup.sh` runs at end of jellyfin-cleanup.sh (no separate cron entry).

`ebook-pipeline.sh` runs every 5 minutes but lives in its own `ebook-pipeline` container/crontab, not this shared cron fleet — see Ebook Pipeline below for why.

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

## Audiobook Import
- No acquisition app for audiobooks (Readarr is discontinued) — grabbed manually into Transmission under the `audiobooks` category
- `audiobook-import.sh` copies anything in `$MEDIA_ROOT/torrents/complete/audiobooks` into `$MEDIA_ROOT/media/audiobooks` (copy, not move — leaves the original for nCore's 72h H&R seeding requirement), then triggers an Audiobookshelf library scan
- Idempotent — skips items already present in the destination
- Not currently wired into the crontab; run manually (`./scripts/audiobook-import.sh` or `--dry-run`) after adding an audiobook torrent
- Requires `AUDIOBOOKSHELF_API_KEY` in `.env` — create via Settings → Users → API Keys in the Audiobookshelf UI (must have `isActive: true`, the API defaults new keys to inactive)

## Ebook Library
- Separate Audiobookshelf library ("Ebooks") from Audiobooks, mounted at its own `${MEDIA_ROOT}/media/ebooks:/ebooks` volume — must not be nested inside `/audiobooks` or under another library's folder, Audiobookshelf double-scans overlapping paths into duplicate items
- Automated acquisition pipeline available — see Ebook Pipeline below. Manually adding files to `media/ebooks` and triggering a scan still works as a fallback for non-torrent sources
- **epub is the standard/default format**: Audiobookshelf only tracks reading progress for epub (not mobi/azw3), and epub is the safest format for Amazon's Send-to-Kindle. Convert other formats with Calibre's `ebook-convert` (a throwaway `lscr.io/linuxserver/calibre` container works well for one-off manual conversions) before adding
- One book per `Author/Title/` folder — never mix a flat ebook file directly under an author folder alongside title subfolders, it confuses Audiobookshelf's folder-as-item detection and misfiles the item as "missing"
- Kindle send-to-device requires the sender address to be on Amazon's approved Personal Document E-mail List (Manage Your Content and Devices → Preferences). Amazon checks the actual SMTP sending address, not the friendly `From:` display address — Brevo relays through its own subdomain for SPF/DKIM alignment, so the address that needs approving is `janos.laszlo1@5162513.brevosend.com`, not `janos.laszlo1@gmail.com` (both are currently approved, along with `janoslaszlo@hotmail.com`)

## Ebook Pipeline
- Fully automated: drop a `.torrent` file into `$MEDIA_ROOT/watch-ebooks`, and `ebook-pipeline.sh` (running every 5 min in its own `ebook-pipeline` container) adds it to Transmission, waits for it to finish, converts it to epub, and imports it into Audiobookshelf's "Ebooks" library
- Own container/crontab, separate from the shared `cron` fleet — it needs Calibre (`ebook-convert`/`ebook-meta`), which requires glibc and is a poor fit for the Alpine-based `cron` image. No Docker socket is mounted anywhere in this stack, so conversion can't be delegated to a throwaway container spun up on demand either — Calibre is baked into the `ebook-pipeline` image itself (Debian-slim base, official Calibre installer, `xvfb` for headless operation)
- Uses Transmission's JSON-RPC API (`torrent-add` / `torrent-get`) rather than Transmission's native `watch-dir` or `script-torrent-done-filename` — both of those live only in the gitignored, runtime-only `config/transmission/settings.json` and would need a container restart; native `watch-dir` also only supports one global download destination, which can't route ebook torrents to their own folder the way RPC-based `torrent-add` (with an explicit `download-dir`) can
- **Deliberately uses a separate `watch-ebooks` folder, not `watch`** — `watch` is Transmission's own native watch-dir (`watch-dir-enabled: true` in the live `settings.json`, already used for general TV/movie torrents dropped there manually). Transmission's native watch-dir polls every few seconds, far faster than this pipeline's 5-minute cron, so sharing the same folder would mean Transmission's own watch-dir wins the race almost every time and routes ebook torrents to the wrong (default) destination instead of `ebooks-incoming`
- Downloads land in `$MEDIA_ROOT/torrents/complete/ebooks-incoming` (Transmission's own destination for this category) — copied (not moved) into `media/ebooks` once finished, same H&R-preserving reasoning as `audiobook-import.sh`
- Metadata (title/author) is read from the ebook file itself via Calibre's `ebook-meta`, not parsed from the filename — filenames from torrents are inconsistent and unreliable for this. Falls back to a cleaned filename + "Unknown Author" (flagged for manual review in the report email) if metadata extraction comes up empty
- Idempotency: `$MEDIA_ROOT/torrents/complete/ebooks-incoming/.imported.log` tracks already-processed torrent hashes (destination folder names depend on extracted metadata, not the source name, so simple destination-exists checks don't work here)
- Sends one report email per run, only when something actually happened (torrent added, book imported, or an error) — never on a quiet no-op tick
- `transmission-cleanup.sh` *does* clean these up correctly, via its generic fallback path rather than anything ebook-specific: ebook torrents have no Sonarr/Radarr history, so they fall to the filesystem hardlink check — since `ebook-pipeline.sh` copies (not hardlinks) into the library, the original always looks unlinked, which the fallback correctly treats as orphaned-but-still-subject-to-the-72h-H&R-wait for nCore. Verified live: completed ebook torrents show up as `Waiting (H&R 72h): ... (~71h remaining)` in `jellyfin-cleanup.sh`'s log, same as movies/TV
- Real remaining risk: if a completed torrent has no recognizable ebook file, or every file in it fails conversion, nothing gets copied into the library — the torrent is marked processed anyway (to avoid retrying forever) and flagged for manual review by email. If that email goes unnoticed for 72h, `transmission-cleanup.sh` will delete the untouched original with no other copy existing anywhere. The email is the only safety net here; there's no automated rescue of unconverted originals before H&R cleanup

## Podcasts
- Separate Audiobookshelf library ("Podcasts") from Audiobooks/Ebooks, mounted at its own `${MEDIA_ROOT}/media/podcasts:/podcasts` volume — same nesting caution as the Ebook library (own top-level folder, not nested under another library's mount, or Audiobookshelf double-scans it into duplicate items)
- Public hosting uses Audiobookshelf's native "Open RSS Feed" feature directly — no separate podcast app, container, or domain. **Canonical public feed URL**: `https://freya-audiobookshelf.duckdns.org/audiobookshelf/feed/<slug>` — this is the exact URL Audiobookshelf's own UI generates and shows, with every URL inside the feed (self-link, cover, episode enclosures) carrying the same `/audiobookshelf` prefix. Give this URL to podcast apps, not a manually-edited one
- `https://freya-audiobookshelf.duckdns.org/feed/<slug>` (no `/audiobookshelf` prefix) also works, as an additionally-permitted compatibility path — useful for scripts/API calls that build the URL directly, but not what a user copies from the UI
- Caddy: a single named matcher (`@public_abs_feed path /feed/* /audiobookshelf/feed/*`) bypasses `geoip_hungary` on the existing Audiobookshelf vhost — the UI, `/api/*`, `/login`, `/audiobookshelf/item/*`, `/share/*`, `/public/share/*`, and every other path on that host stay HU/LAN-only, exactly as before. No general `/audiobookshelf/*` exception exists
- Why both prefixes are needed: Audiobookshelf's `RouterBasePath` rewrite (`/audiobookshelf` by default) happens inside its own Express middleware, downstream of Caddy — Caddy has no `handle_path`/`strip_prefix`/`rewrite` directive anywhere, so it only ever sees the literal path a client requested. Request the bare `/feed/*` form and Audiobookshelf emits unprefixed URLs; request `/audiobookshelf/feed/*` (what its UI does) and everything in the response carries that prefix too. Missing either one 403s that variant for anyone outside HU/LAN while looking identical to the working one
- Verified against real generated feeds, both prefix forms (not assumed from docs): feed/cover/audio all return `200` with no redirects, and an HTTP Range request against the audio enclosure returns `206 Partial Content` (required for scrubbing/resuming in podcast apps) — confirmed live from a vantage point outside HU/LAN
- The feed's `<link>` elements point to the authenticated `/audiobookshelf/item/:id` web page, which stays behind the geo-block — expected, since podcast apps use `<enclosure>` for playback, not `<link>`
- Don't broaden the Caddy exception beyond these two exact prefixes without inspecting a real Audiobookshelf feed first — its served paths come from Audiobookshelf's own route definitions, not a documented/stable API contract
- A podcast's "Open RSS Feed" only closes via an explicit `POST /api/feeds/:id/close` call (the UI toggle) or by deleting the library item — there's no automatic expiration or scan-triggered closure. If a feed goes quiet, check whether the toggle got flipped off in the UI before assuming an infrastructure problem
- Don't add a new DuckDNS record or a dedicated podcast domain unless explicitly requested — this deliberately reuses the existing Audiobookshelf host

## Media Item Shares
- Separate Audiobookshelf feature from the Podcasts `/feed/*` exception above — a "Media Item Share" makes one specific book or podcast episode (`/api/share/mediaitem`, `mediaItemType` = `book` or `podcastEpisode`) viewable at `/share/<slug>`, backed by unauthenticated routes at `/public/share/<slug>*` (data, cover, audio track, download)
- **Intentionally left geo-restricted, unlike `/feed/*`** — no Caddy exception exists for `/share/*` or `/public/share/*`, so `geoip_hungary` still gates them on the Audiobookshelf vhost: reachable and fully login-free from HU/LAN, `403` from anywhere else
- Verified live with a temporary real share: from HU/LAN, the flow works exactly as designed — visiting `/public/share/<slug>` sets an httpOnly `share_session_id` cookie (30-day), and that cookie is required for the track/cover/download routes (they 404 with "Share session not set" without it, by design, not a bug). Audio track requests honor Range and return `206 Partial Content`; from outside HU/LAN, the same share URL returns `403`
- Don't add a Caddy exception for `/share/*` or `/public/share/*` unless explicitly requested — the current design is deliberate: Media Item Shares are for sharing with people already inside the allowed geo/LAN, not the general public

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
- `BACKUP_ENCRYPTION_KEY` lives only in `.env`, which is itself inside the encrypted backup — store a copy off-server (password manager, printed), or a lost server + lost key means the backup can never be decrypted
- Restore: `scripts/restore.sh` (runs on host) — `--list`, `--dry-run`, latest or specific backup
- Restore stops containers, extracts configs, restores SQLite backups, cleans WAL/SHM journals, restarts

## Network Resilience
- Host's primary path (default route, LAN/remote.it, client-facing streaming) is WiFi (`wlp1s0`) — this is a real failure mode, not just a theoretical one. A second, wired NIC (`enp0s31f6`) also exists but is *not* the default route — it's used only for the dedicated NAS route below, not general traffic
- Incident 2026-08-27/30: an AP band-roam triggered a WPA handshake failure (`reason=WRONG_KEY`, likely a transient AP-side glitch, not an actual bad password). NetworkManager entered `need-auth`, which waits indefinitely for a secrets-agent (GUI) prompt that never comes on a headless box — autoconnect never retried. Result: total, silent network loss (LAN port forwards AND remote.it, since remote.it is outbound-initiated and needs host network too) for ~3 days until a manual power-cycle. The host itself never crashed — Docker/containers stayed healthy the whole time, journal logged continuously — this was purely a network-layer outage
- `scripts/network-watchdog.sh` (host-level systemd timer, every 2 min, installed by `server-setup.sh` — runs as root, NOT in the Docker cron fleet, since it needs `nmcli`/`systemctl` access to the host's NetworkManager) pings 1.1.1.1/8.8.8.8; on failure, toggles `nmcli networking off/on` to force a fresh reconnect from stored secrets, escalating to `systemctl restart NetworkManager` if still down after 5 minutes
- State tracked in `/var/lib/network-watchdog/` (down-since timestamp, one-restart-per-outage flag); logs to journal under the `network-watchdog` unit
- Not yet installed via automated deploy on the existing live host (systemd units are host-level, outside the GitHub Actions/docker-compose pipeline) — installed manually via SSH, then codified in `server-setup.sh` for future fresh provisions
- If this ever recurs despite the watchdog, the next escalation to consider is a full auto-reboot after a longer timeout — deliberately not implemented yet, since an unattended reboot is a bigger action than was agreed
- Incident 2026-09-01: playing Furious S01E04 with a subtitle track selected froze for 11+ minutes (fine with subtitles off). Root cause: NFS reads to the NAS and Jellyfin's client-facing streaming both rode the same WiFi radio — a burst of retried transcode reads (from repeated user restarts while waiting) plus a concurrent subtitle-extraction ffmpeg process saturated that link, which cascaded into the per-minute `jellyfin-scan.sh` library-refresh task self-overlapping and hammering the SQLite connection. Not a subtitle file problem, not a chronic cron-cadence problem (the scan runs in <5s normally) — pure WiFi/NFS bandwidth contention
- Fix: NAS traffic (`192.168.1.76`) is now pinned to the wired NIC — installed live via SSH 2026-09-01, then codified in `server-setup.sh` (`WIRED_IFACE` env var, optional — skipped on hosts with no spare wired NIC) for future fresh provisions. WiFi keeps the default route for everything else, so client-facing streaming is unaffected
- `nas-route.service` (systemd oneshot, `/usr/local/sbin/nas-route-setup.sh`), not just a NetworkManager dispatcher script, applies the route. A dispatcher script alone has no ordering relationship with mount units: if WiFi reached `network-online.target` before the wired NIC came up, the mount could race ahead and bind to WiFi regardless of the dispatcher. What actually guarantees this service runs before the NFS mount on every boot is a systemd drop-in placed directly on the mount unit itself (`Requires=`/`After=nas-route.service`, keyed off the mount unit name via `systemd-escape --path --suffix=mount`) — `Before=remote-fs-pre.target` alone would NOT be enough, since that target is a passive ordering point nothing pulls into the boot transaction on its own. The dispatcher script (`/etc/NetworkManager/dispatcher.d/99-nas-via-wired.sh`) still runs after boot, to reapply the route if the cable is replugged and remove it (falling back to WiFi) if the link drops — without that removal, a stale `/32` route would blackhole NAS traffic against a dead interface instead of falling back
- `nas-route-setup.sh` also sets `ipv4.never-default`/a high route-metric on the wired connection profile — if that NIC ever gets a gateway from DHCP on the same LAN, NetworkManager would otherwise install it as a second default route (possibly lower-metric than WiFi's), letting general LAN traffic drift onto it despite the NAS-only design
- Checks real link state (`/sys/class/net/*/carrier` + a global IPv4 address), not `ip link show ... up` — that only reflects administrative state and stays true while unplugged or before DHCP finishes
- Applying the route while the NFS mount is still live and mid-I/O can disrupt in-flight transfers (observed: `transmission` needed a second SIGKILL to stop cleanly during the live fix). Do the route change with the stack stopped and the NFS mount already idle, then remount (`systemctl restart mnt-mediaserver.mount` or equivalent) so the new TCP connection actually rebinds to the wired interface — a route change alone does not move an already-established connection

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
- Only port 443 exposed to internet (via Caddy with GeoIP filter, except Audiobookshelf's `/feed/*` and `/audiobookshelf/feed/*` public podcast feed — see Podcasts)
- UFW: SSH from LAN only, DNS from LAN only, 443/tcp, deny all else
- No Docker socket mounted in any container
- No host-networked containers
- All other services isolated in bridge network
