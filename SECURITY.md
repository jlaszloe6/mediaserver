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

- Specific deployment details (domains, IPs, credentials)
- Exact rate-limiting thresholds or token expiry windows
- Firewall rule details
- Backup locations or encryption details
