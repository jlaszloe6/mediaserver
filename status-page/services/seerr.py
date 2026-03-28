import requests

from config import (
    API_TIMEOUT, RADARR_KEY, RADARR_URL, SEERR_API_KEY, SEERR_URL,
    SONARR_KEY, SONARR_URL,
)

SEERR_HEADERS = {"X-Api-Key": SEERR_API_KEY} if SEERR_API_KEY else {}

GUEST_MOVIE_ROOT = "/data/media/movies-guests"
GUEST_TV_ROOT = "/data/media/tv-guests"
GUEST_RADARR_NAME = "Radarr (Guest)"
GUEST_SONARR_NAME = "Sonarr (Guest)"


def _get_seerr_user_by_jellyfin_username(username):
    """Find a Seerr user by their Jellyfin username."""
    try:
        r = requests.get(
            f"{SEERR_URL}/api/v1/user",
            params={"take": 100},
            headers=SEERR_HEADERS,
            timeout=API_TIMEOUT,
        )
        if r.status_code != 200:
            return None
        data = r.json()
        users = data.get("results", data) if isinstance(data, dict) else data
        for user in users:
            if user.get("jellyfinUsername") == username:
                return user.get("id")
    except requests.RequestException:
        pass
    return None


def _ensure_guest_server_configs():
    """Create guest Radarr/Sonarr configs in Seerr if missing. Returns (radarr_id, sonarr_id) or (None, None)."""
    try:
        radarr_cfgs = requests.get(f"{SEERR_URL}/api/v1/settings/radarr", headers=SEERR_HEADERS, timeout=API_TIMEOUT).json()
        sonarr_cfgs = requests.get(f"{SEERR_URL}/api/v1/settings/sonarr", headers=SEERR_HEADERS, timeout=API_TIMEOUT).json()
    except requests.RequestException:
        return None, None

    # Find or create guest Radarr config
    guest_radarr = next((c for c in radarr_cfgs if c["name"] == GUEST_RADARR_NAME), None)
    if not guest_radarr:
        main = next((c for c in radarr_cfgs if c.get("isDefault")), radarr_cfgs[0] if radarr_cfgs else None)
        if not main:
            return None, None
        try:
            r = requests.post(f"{SEERR_URL}/api/v1/settings/radarr", json={
                "name": GUEST_RADARR_NAME, "hostname": main["hostname"], "port": main["port"],
                "apiKey": main["apiKey"], "useSsl": main.get("useSsl", False),
                "activeProfileId": main["activeProfileId"], "activeProfileName": main["activeProfileName"],
                "activeDirectory": GUEST_MOVIE_ROOT, "is4k": False, "minimumAvailability": "released",
                "isDefault": False, "externalUrl": "", "syncEnabled": False, "preventSearch": False,
            }, headers=SEERR_HEADERS, timeout=API_TIMEOUT)
            guest_radarr = r.json() if r.ok else None
        except requests.RequestException:
            return None, None

    # Find or create guest Sonarr config
    guest_sonarr = next((c for c in sonarr_cfgs if c["name"] == GUEST_SONARR_NAME), None)
    if not guest_sonarr:
        main = next((c for c in sonarr_cfgs if c.get("isDefault")), sonarr_cfgs[0] if sonarr_cfgs else None)
        if not main:
            return guest_radarr.get("id") if guest_radarr else None, None
        try:
            r = requests.post(f"{SEERR_URL}/api/v1/settings/sonarr", json={
                "name": GUEST_SONARR_NAME, "hostname": main["hostname"], "port": main["port"],
                "apiKey": main["apiKey"], "useSsl": main.get("useSsl", False),
                "activeProfileId": main["activeProfileId"], "activeProfileName": main["activeProfileName"],
                "activeDirectory": GUEST_TV_ROOT,
                "activeLanguageProfileId": main.get("activeLanguageProfileId", 1),
                "is4k": False, "isDefault": False, "externalUrl": "", "syncEnabled": False,
                "preventSearch": False, "enableSeasonFolders": True,
            }, headers=SEERR_HEADERS, timeout=API_TIMEOUT)
            guest_sonarr = r.json() if r.ok else None
        except requests.RequestException:
            return guest_radarr.get("id") if guest_radarr else None, None

    radarr_id = guest_radarr.get("id") if guest_radarr else None
    sonarr_id = guest_sonarr.get("id") if guest_sonarr else None
    return radarr_id, sonarr_id


def import_and_configure_seerr_user(jellyfin_username, jellyfin_user_id):
    """Import Jellyfin user into Seerr and set override rule for guest servers. Returns (success, warning)."""
    if not jellyfin_user_id:
        return False, "No Jellyfin user ID provided"
    if not SEERR_API_KEY:
        return False, "Seerr API key not configured"

    # Import specific Jellyfin user into Seerr
    try:
        r = requests.post(
            f"{SEERR_URL}/api/v1/user/import-from-jellyfin",
            json={"jellyfinUserIds": [jellyfin_user_id]},
            headers=SEERR_HEADERS,
            timeout=API_TIMEOUT * 3,
        )
        if r.status_code not in (200, 201):
            return False, f"Seerr import failed (HTTP {r.status_code})"
    except requests.RequestException as e:
        return False, f"Seerr import failed: {e}"

    # Find the imported user
    seerr_user_id = _get_seerr_user_by_jellyfin_username(jellyfin_username)
    if not seerr_user_id:
        return False, "User imported but not found in Seerr"

    # Ensure guest server configs exist
    radarr_id, sonarr_id = _ensure_guest_server_configs()
    if radarr_id is None or sonarr_id is None:
        return False, "Failed to create guest server configs in Seerr"

    # Create override rule for this user
    try:
        r = requests.post(f"{SEERR_URL}/api/v1/overrideRule", json={
            "radarrServiceId": radarr_id,
            "sonarrServiceId": sonarr_id,
            "users": str(seerr_user_id),
        }, headers=SEERR_HEADERS, timeout=API_TIMEOUT)
        if r.status_code == 200:
            return True, None
        return False, f"Failed to create override rule (HTTP {r.status_code})"
    except requests.RequestException as e:
        return False, f"Failed to create override rule: {e}"
