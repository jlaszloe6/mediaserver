import smtplib
from email.mime.text import MIMEText

from config import (
    BASE_URL, GUEST_QUOTA_GB, SMTP_FROM, SMTP_PASSWORD, SMTP_PORT,
    SMTP_SERVER, SMTP_USER,
)


def _wrap_html(body):
    """Wrap email body in the standard dark template matching the status page."""
    return f"""\
<html>
<body style="margin:0;padding:0;background:#0f0f1a;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#0f0f1a;padding:24px 0;">
<tr><td align="center">
<table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#16213e;border-radius:12px;overflow:hidden;">
<tr><td style="background:#1a1a2e;padding:20px 24px;border-bottom:2px solid #e94560;">
<span style="color:#fff;font-size:18px;font-weight:700;">Media Server</span>
</td></tr>
<tr><td style="padding:24px;color:#e0e0e0;font-size:15px;line-height:1.6;">
{body}
</td></tr>
<tr><td style="padding:16px 24px;border-top:1px solid #1a3a5c;color:#5a6a8a;font-size:12px;text-align:center;">
Sent from Media Server Status Page
</td></tr>
</table>
</td></tr>
</table>
</body>
</html>"""


def _button(url, text):
    """Render a styled CTA button."""
    return f'<a href="{url}" style="display:inline-block;padding:12px 24px;background:#e94560;color:#fff;text-decoration:none;border-radius:8px;font-weight:600;margin:8px 0;">{text}</a>'


def _heading(text):
    """Render a section heading."""
    return f'<h2 style="color:#fff;font-size:16px;margin:20px 0 8px 0;padding:0;">{text}</h2>'


def send_email(to, subject, html):
    msg = MIMEText(html, "html")
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM
    msg["To"] = to
    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as server:
        server.starttls()
        server.login(SMTP_USER, SMTP_PASSWORD)
        server.send_message(msg)


def send_styled_email(to, subject, body):
    """Send an email wrapped in the standard dark template."""
    send_email(to, subject, _wrap_html(body))


def send_magic_link(email, token):
    link = f"{BASE_URL}/auth/{token}"
    body = f"""\
<p style="color:#e0e0e0;">Click below to log in to the Media Server Status Page:</p>
<p style="text-align:center;margin:20px 0;">{_button(link, 'Log In')}</p>
<p style="color:#5a6a8a;font-size:13px;">This link expires in 15 minutes and can only be used once.</p>"""
    send_styled_email(email, "Status Page Login", body)


def send_user_guide(email):
    body = f"""\
{_heading('Adding Movies &amp; TV Shows')}
<table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:16px;">
<tr><td style="padding:10px 12px;border:1px solid #1a3a5c;background:#1a1a2e;border-radius:6px 6px 0 0;"><strong style="color:#e94560;">Trakt Watchlist</strong> (recommended)</td></tr>
<tr><td style="padding:10px 12px;border:1px solid #1a3a5c;border-top:0;">Go to <a href="https://trakt.tv" style="color:#8ab4f8;">trakt.tv</a> &rarr; search &rarr; click bookmark icon. Picked up within 1 hour.</td></tr>
<tr><td style="padding:10px 12px;border:1px solid #1a3a5c;border-top:0;background:#1a1a2e;"><strong style="color:#e94560;">Seerr</strong></td></tr>
<tr><td style="padding:10px 12px;border:1px solid #1a3a5c;border-top:0;">Browse and request via the Seerr app. Sign in with your Plex account.</td></tr>
</table>

{_heading('Removing Content')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li><strong>Remove from Trakt</strong> &mdash; remove from watchlist &rarr; auto-deleted within ~2 hours</li>
<li><strong>Delete from Plex</strong> &mdash; three dots (&hellip;) &rarr; Delete. Cleaned up within 30 minutes.</li>
</ul>

{_heading('Watching')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li><strong>Plex apps</strong> &mdash; Install on phone, TV, streaming device, or game console. Sign in with your Plex account.</li>
<li><strong>Web browser</strong> &mdash; Use the Plex web URL (ask your admin).</li>
<li><strong>Quality</strong> &mdash; Set the Plex player to <strong>Original</strong> quality for best results.</li>
<li><strong>Subtitles</strong> &mdash; Most downloads include English subtitles. Toggle them in the Plex player.</li>
</ul>

{_heading('Remote Access (VPN)')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li><strong>VPN required</strong> &mdash; Plex will not work remotely without an active VPN connection.</li>
<li>Install <strong>WireGuard</strong> on your device and import the .conf file you received during onboarding.</li>
<li>Toggle the VPN on before opening Plex when you're away from home.</li>
<li>On the home network, VPN is not needed.</li>
</ul>

{_heading('Status Page')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li>Check downloads, library stats, and service health at the <strong>Status Page</strong>.</li>
<li>Log in with your email &mdash; you'll receive a magic link (no password needed).</li>
</ul>

{_heading('Good to Know')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li>Watched content is <strong>automatically removed after 30 days</strong> to free space.</li>
<li>Want to rewatch? Just add it to your Trakt watchlist again.</li>
<li>New releases download once a digital version is available (not while in theaters).</li>
<li>TV series: all existing episodes download, and new ones download as they air.</li>
</ul>"""
    send_styled_email(email, "Media Server - Quick Actions Guide", body)


def send_guest_welcome(email, name, onboard_token):
    setup_url = f"{BASE_URL}/onboard/{onboard_token}"
    body = f"""\
<p style="font-size:17px;color:#fff;margin-bottom:16px;">Welcome, {name}!</p>

{_heading('1. Set Up VPN (required)')}
<p><strong style="color:#e94560;">Plex will not work without the VPN.</strong> Visit your setup page to download the VPN config file and follow the instructions:</p>
<p style="text-align:center;margin:16px 0;">{_button(setup_url, 'Open Setup Page')}</p>
<p style="color:#5a6a8a;font-size:13px;">Bookmark this link &mdash; you can always come back to download your VPN config.</p>

{_heading('2. Install Plex')}
<p>Download the <strong>Plex</strong> app on your phone, TV, or streaming device. <strong>Enable the VPN first</strong>, then sign in with your Plex account. You'll see two libraries: <strong>Guest TV</strong> and <strong>Guest Movies</strong>.</p>

{_heading('3. Add Content via Trakt')}
<p>Your Trakt watchlist is connected. To add movies or TV shows:</p>
<ol style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li>Go to <a href="https://trakt.tv" style="color:#8ab4f8;">trakt.tv</a></li>
<li>Search for what you want to watch</li>
<li>Click the bookmark icon to add to your watchlist</li>
<li>It will appear in Plex within 1&ndash;2 hours</li>
</ol>

{_heading('Good to Know')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li>Storage: <strong>{GUEST_QUOTA_GB} GB shared</strong> across all guests.</li>
<li>Watched content is <strong>automatically removed after 30 days</strong> to free space.</li>
<li>Want to rewatch something? Just add it to your Trakt watchlist again.</li>
<li>New releases download once a digital version is available (not while in theaters).</li>
<li>TV series: all existing episodes download, and new ones arrive as they air.</li>
</ul>"""
    send_styled_email(email, "Welcome to the Media Server!", body)
