import requests

from config import API_TIMEOUT, JELLYFIN_API_KEY, JELLYFIN_URL


def create_jellyfin_user(username, password):
    """Create a new Jellyfin user. Returns (success, error_message)."""
    if not JELLYFIN_API_KEY:
        return False, "Jellyfin API key not configured"
    try:
        r = requests.post(
            f"{JELLYFIN_URL}/Users/New",
            json={"Name": username, "Password": password},
            headers={"X-Emby-Token": JELLYFIN_API_KEY},
            timeout=API_TIMEOUT,
        )
        if r.status_code == 200:
            return True, None
        return False, f"Jellyfin returned {r.status_code}: {r.text[:200]}"
    except requests.RequestException as e:
        return False, str(e)
