# Shared Context (Hobby Projects)

Copy this file as `CLAUDE-SHARED.md` into any hobby project repo.

## User

- GitHub: `jlaszloe6`
- Prefers direct execution — do the task, don't explain steps
- Manages personal infrastructure and hobby projects

## Preferences

### Execute, don't explain
Default to programmatic execution via API/CLI. Only fall back to manual instructions when API access is not available. When user says "yes" or "do it", execute immediately. Suggest cost optimizations and simplifications proactively. Fewer services is better — suggest removal when something isn't needed.

### Never hardcode secrets in tracked files
All secrets, API keys, tokens, domains, and URLs go in `.env` (gitignored), with placeholders in `.env.example`. Use env var substitution in config files (`${VAR}` in compose, `{$VAR}` in Caddy). Before committing, grep tracked files for real domains, IPs, and tokens.

### Wiki pages: no H1 title
GitHub wiki auto-displays the page title from the filename. Do not start wiki pages with `# Page Title` — it creates a duplicate heading. Start with content or `##` subheading.

## Project Separation

Business projects (hosted on Forgejo) and hobby projects (hosted on GitHub) are completely isolated. Never mix content, memories, or context between them.
