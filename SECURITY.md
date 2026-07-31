## Security Policy

### Reporting Vulnerabilities

If you discover a security vulnerability, please report it privately:

1. **Do not open a public issue**
2. Use [GitHub Security Advisories](../../security/advisories/new) to report privately
3. Or email the maintainer directly

### Supported Versions

Only the latest commit on `master` is actively maintained.

### Scope

This is a personal homelab media server. The security model assumes:

- A single trusted operator
- Internet exposure only through Caddy reverse proxy (port 443)
- GeoIP filtering on all public endpoints
- Magic-link email authentication with Cloudflare Turnstile

### What Not to Disclose Publicly

- This specific deployment's real domains, IPs, and credentials (the repo and wiki use `$VARIABLE` placeholders throughout for exactly this reason)
- Anything from `.env` or any other secret value

The wiki's [Security Model](../../wiki/Security-Model) page *does* document this project's actual rate-limiting thresholds, token expiry windows, firewall rule structure, and backup encryption approach in detail -- that's a deliberate choice ("honest about what is hardened and what assumes trust," per that page), not an oversight. None of those specifics are exploitable secrets on their own: knowing the login rate limit is 3 attempts per 10 minutes doesn't help bypass it, and knowing backups use AES-256-CBC keyed by `BACKUP_ENCRYPTION_KEY` doesn't reveal the key itself. Security by architecture transparency, not obscurity.
