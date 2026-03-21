import smtplib
from email.mime.text import MIMEText

from config import (
    BASE_URL, GUEST_QUOTA_GB, SMTP_FROM, SMTP_PASSWORD, SMTP_PORT,
    SMTP_SERVER, SMTP_USER,
)


def send_email(to, subject, html):
    msg = MIMEText(html, "html")
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM
    msg["To"] = to
    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as server:
        server.starttls()
        server.login(SMTP_USER, SMTP_PASSWORD)
        server.send_message(msg)


def send_magic_link(email, token):
    link = f"{BASE_URL}/auth/{token}"
    msg = MIMEText(
        f"Click to log in to the Media Server Status Page:\n\n{link}\n\nThis link expires in 15 minutes.",
        "plain",
    )
    msg["Subject"] = "Status Page Login"
    msg["From"] = SMTP_FROM
    msg["To"] = email
    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as server:
        server.starttls()
        server.login(SMTP_USER, SMTP_PASSWORD)
        server.send_message(msg)


def send_user_guide(email):
    html = """\
<html>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;">
<h1 style="color: #1a1a2e; border-bottom: 2px solid #e94560; padding-bottom: 10px;">Media Server Quick Actions</h1>

<h2 style="color: #16213e;">Adding Movies &amp; TV Shows</h2>
<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
<tr style="background: #f5f5f5;"><td style="padding: 10px; border: 1px solid #ddd;"><strong>Trakt Watchlist</strong> (recommended)</td><td style="padding: 10px; border: 1px solid #ddd;">Go to <a href="https://trakt.tv">trakt.tv</a> &rarr; search &rarr; click bookmark icon. Picked up within 1 hour.</td></tr>
<tr><td style="padding: 10px; border: 1px solid #ddd;"><strong>Seerr</strong></td><td style="padding: 10px; border: 1px solid #ddd;">Browse and request via the Seerr app. Sign in with your Plex account.</td></tr>
</table>

<h2 style="color: #16213e;">Removing Content</h2>
<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
<tr style="background: #f5f5f5;"><td style="padding: 10px; border: 1px solid #ddd;"><strong>Remove from Trakt</strong></td><td style="padding: 10px; border: 1px solid #ddd;">Remove from watchlist &rarr; auto-deleted within ~2 hours</td></tr>
<tr><td style="padding: 10px; border: 1px solid #ddd;"><strong>Delete from Plex</strong></td><td style="padding: 10px; border: 1px solid #ddd;">Three dots (&hellip;) &rarr; Delete. Cleaned up within 30 minutes.</td></tr>
</table>

<h2 style="color: #16213e;">Watching</h2>
<ul style="line-height: 1.8;">
<li><strong>Plex apps</strong> &mdash; Install on phone, TV, streaming device, or game console. Sign in with your Plex account.</li>
<li><strong>Web browser</strong> &mdash; Use the Plex web URL (ask your admin).</li>
<li><strong>Quality</strong> &mdash; Set the Plex player to <strong>Original</strong> quality for best results. This avoids buffering.</li>
<li><strong>Subtitles</strong> &mdash; Most downloads include English subtitles. Toggle them in the Plex player.</li>
</ul>

<h2 style="color: #16213e;">Remote Access (VPN)</h2>
<ul style="line-height: 1.8;">
<li><strong>VPN required</strong> &mdash; Plex will not work remotely without an active VPN connection.</li>
<li>Install <strong>WireGuard</strong> on your device and import the .conf file you received during onboarding.</li>
<li>Toggle the VPN on before opening Plex when you're away from home.</li>
<li>On the home network, VPN is not needed.</li>
</ul>

<h2 style="color: #16213e;">Status Page</h2>
<ul style="line-height: 1.8;">
<li>Check what's downloading, library stats, and service health at the <strong>Status Page</strong>.</li>
<li>Log in with your email &mdash; you'll receive a magic link (no password needed).</li>
</ul>

<h2 style="color: #16213e;">Good to Know</h2>
<ul style="line-height: 1.8;">
<li>Watched content is <strong>automatically removed after 30 days</strong> to free space.</li>
<li>Want to rewatch? Just add it to your Trakt watchlist again.</li>
<li>New releases download once a digital version is available (not while in theaters).</li>
<li>TV series: all existing episodes download, and new ones download as they air.</li>
</ul>

<hr style="border: none; border-top: 1px solid #ddd; margin: 20px 0;">
<p style="color: #888; font-size: 12px;">Sent from Media Server Status Page</p>
</body>
</html>"""

    msg = MIMEText(html, "html")
    msg["Subject"] = "Media Server - Quick Actions Guide"
    msg["From"] = SMTP_FROM
    msg["To"] = email
    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as server:
        server.starttls()
        server.login(SMTP_USER, SMTP_PASSWORD)
        server.send_message(msg)


def send_guest_welcome(email, name, onboard_token):
    setup_url = f"{BASE_URL}/onboard/{onboard_token}"
    send_email(email, "Welcome to the Media Server!", f"""\
<html>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;">
<h1 style="color: #1a1a2e; border-bottom: 2px solid #e94560; padding-bottom: 10px;">Welcome to the Media Server, {name}!</h1>
<h2 style="color: #16213e;">1. Set Up VPN (required)</h2>
<p><strong>Plex will not work without the VPN.</strong> Visit your setup page to download the VPN config file and follow the instructions:</p>
<p style="margin: 15px 0;"><a href="{setup_url}" style="background: #e94560; color: #fff; padding: 10px 20px; border-radius: 6px; text-decoration: none; font-weight: 600;">Open Setup Page</a></p>
<p style="font-size: 13px; color: #888;">Bookmark this link &mdash; you can always come back to download your VPN config or review the setup instructions.</p>
<h2 style="color: #16213e;">2. Install Plex</h2>
<p>Download the <strong>Plex</strong> app on your phone, TV, or streaming device. <strong>Enable the VPN first</strong>, then sign in with your Plex account. You'll see two libraries: <strong>Guest TV</strong> and <strong>Guest Movies</strong>.</p>
<h2 style="color: #16213e;">3. Add Content via Trakt</h2>
<p>Your Trakt watchlist is connected. To add movies or TV shows:</p>
<ol style="line-height: 1.8;">
<li>Go to <a href="https://trakt.tv">trakt.tv</a></li>
<li>Search for what you want to watch</li>
<li>Click the bookmark icon to add to your watchlist</li>
<li>It will appear in Plex within 1&ndash;2 hours</li>
</ol>
<h2 style="color: #16213e;">Good to Know</h2>
<ul style="line-height: 1.8;">
<li>Storage: <strong>{GUEST_QUOTA_GB} GB shared</strong> across all guests.</li>
<li>Watched content is <strong>automatically removed after 30 days</strong> to free space.</li>
<li>Want to rewatch something? Just add it to your Trakt watchlist again.</li>
<li>New releases download once a digital version is available (not while in theaters).</li>
<li>TV series: all existing episodes download, and new ones arrive as they air.</li>
</ul>
<hr style="border: none; border-top: 1px solid #ddd; margin: 20px 0;">
<p style="color: #888; font-size: 12px;">Sent from Media Server Status Page</p>
</body>
</html>""")
