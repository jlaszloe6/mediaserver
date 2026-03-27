import smtplib
from email.mime.text import MIMEText

from config import (
    BASE_URL, JELLYFIN_EXTERNAL_URL, SERVER_NAME, SMTP_FROM,
    SMTP_PASSWORD, SMTP_PORT, SMTP_SERVER, SMTP_USER,
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
<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAABmJLR0QA/wD/AP+gvaeTAAAE8ElEQVRogc2az29bRRDHP7PvOU7ixE6rtmnsJEUIUWilphVw6gWhVEHil9QGgUQvHOEfKLdKIC6FAxIXJARcqKhE2goqQCUcEBIHVIRK0oIqfgiRH7htmtqJncT2ezscUhvbjWO7OLa/J+/M7njGO/uded4nVEAsdvAg2OetZVREh0B2AU6l+Q2GD3pDVWaASWP8T+fmrv680UQpF8RiIw+q6ingua32sj7oeWOcE7Ozl38rlpYEMDBw4EkRzgCRpvpWO5aB4/PzU5/nBYUAYrGDT6nazyhKE8WgbgcqLmoMYJrjpiqoxdgc4mcQtFjrW6vPxOPTXxUCWE8bewkknJ9lnU6s29kch6vAeKsYP1MsSjqOfWRm5sofBkBV3ypxPtDdNs4DWLcL63YXiyLWmlMAEo2OHAL9qTC5jX75cpTthIr4h4yIjhckSNs6D+s7oVI4h6JqjhlrGc1L1Am2xrM6oCZQNJIjRoQ9+aEtUbYn1OkoHg4bYEd+JKZJNPk/oKVU3m8o4f27CnP7QUp8dNr/J6+ChgWwr7M1BNCwAE4PRjmxYwfdUp/JsZ4Qz4Z76DL3lr4NC8BFON4X5tzwIIe7u6svyK8TYdANcDQcZptTf7fe8DMQC7i8F93N27v7a3Lo4nKa37M5IsZwNNzLbtet6/u27BCP9YS4MDzEeKR3U27zUCZTKa5lskRdl6fDvYTr4JYtZaGIYzi5cycfxAa4L1C5SCrw49oq132P+90A4+EIHVLbmWgKjT7W1cXE8CCvbt9GoMJ+JH3L6cQS857H3o4AR0Khmmw3rQ4ERXhl+zY+GYqyP7gx5aat5aNEkpRaDoe6GAhUP0NNL2R7g0E+HqpMuWnr800qDSo83t1T1V5LKnE1yv01kyVhffZ0BAhX6c9a2kpUotyk75NSS5cIoXYOYDNI+aN8BdRXNRqMuZzHGzcX+H5lpUQecRxCIqypkrZ2UxstCcBDOZNY5t1bi6zo3Q4+HOygzzhMZzIstVsA1zIZTt5Y4Goms6E+ZBxGe0Igyrcrqar2mhZARpUPbyd4fzFBrkJ2h4zh5b4IPWL4Lr3CPzm/qt2mBHBpdZXXbyzwVy5XcU7EMbwQCRN1Xa5lc0ym0zXZ3tIAkr7lncVbnE0ub8ooAjza2UW/4/Knl2NiKUlWa+GgLQzgYirNmzcXuO1vngYuwhM9IR7oCDDveXyxnGLJ3/zglq5vMCpRYyWM9YbYEwiQtJYvl1NVAy5HwwKoRo0V16ky6+WYTKVZtbWlTTEkGj1QWOUF++o2kMe+ziC/rG1MjY2Gm0kUPjeslWiW8+Vo216oVhig6NTUnrstQym9+gb0Rn4kNXJvKyGUsFTc3LnKXFf6lStlu6DMxxkD8vV/ygzU1IW3Cor42WLBRWOMnM2PBMV4a833q0YYb634MUeNsefM3Nzly6DnC5P8DKY0yraA+Nmym0qZmJ29MmUAjHFOAMm8yngrGG+V9kgnxXirOF5Ja5Lwffsa3LncWFqKL0Yiu6ZU5UXu1AZRH/Gz61smBpDyy4Ut9FkR7Ho25FYw6hVrfVWOxePTl+CuVw1GxkT0DHDvPcXWYhl4aX5+6kJeUPLXVyp1/Y++vp0TIIPAQ2zwMkiLoKqctVbH4/HpH4oVFR2MxfaPWOuOi+goMAz009TXbbgO/A06aYxOzM5emdpo4r8PYtx5TTbwtQAAAABJRU5ErkJggg==" width="32" height="32" alt="" style="vertical-align:middle;margin-right:10px;border-radius:6px;"><span style="color:#fff;font-size:18px;font-weight:700;vertical-align:middle;">{SERVER_NAME}</span>
</td></tr>
<tr><td style="padding:24px;color:#e0e0e0;font-size:15px;line-height:1.6;">
{body}
</td></tr>
<tr><td style="padding:16px 24px;border-top:1px solid #1a3a5c;color:#5a6a8a;font-size:12px;text-align:center;">
Sent from {SERVER_NAME}
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
    msg["From"] = f"{SERVER_NAME} <{SMTP_FROM}>"
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
    jellyfin_url = JELLYFIN_EXTERNAL_URL or "your Jellyfin server URL"
    body = f"""\
{_heading('Adding Movies &amp; TV Shows')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li>Browse and request via <strong>Seerr</strong>. Sign in with your Jellyfin account.</li>
</ul>

{_heading('Removing Content')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li><strong>Delete from Jellyfin</strong> &mdash; select the item &rarr; Delete. Cleaned up within 30 minutes.</li>
</ul>

{_heading('Watching')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li><strong>Web browser</strong> (laptop/desktop/mobile) &mdash; Go to <strong>{jellyfin_url}</strong>.</li>
<li><strong>Jellyfin app</strong> (phone, Android TV, etc.) &mdash; Add the server URL <strong>{jellyfin_url}</strong> and sign in.</li>
<li><strong>Quality</strong> &mdash; For best results, use a client that supports direct play.</li>
<li><strong>Subtitles</strong> &mdash; Most downloads include English subtitles. Toggle them in the Jellyfin player.</li>
</ul>

{_heading('Status Page')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li>Check downloads, library stats, and service health at the <strong>Status Page</strong>.</li>
<li>Log in with your email &mdash; you'll receive a magic link (no password needed).</li>
</ul>

{_heading('Good to Know')}
<ul style="line-height:1.8;padding-left:20px;color:#e0e0e0;">
<li>Watched content is <strong>automatically removed after 30 days</strong> to free space.</li>
<li>Want to rewatch? Just request it again via Seerr.</li>
<li>New releases download once a digital version is available (not while in theaters).</li>
<li>TV series: all existing episodes download, and new ones download as they air.</li>
</ul>"""
    send_styled_email(email, "Media Server - Quick Actions Guide", body)
