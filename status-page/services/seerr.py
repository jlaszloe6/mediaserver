import requests

from config import API_TIMEOUT, RADARR_KEY, RADARR_URL, SEERR_API_KEY, SEERR_URL, SONARR_KEY, SONARR_URL

SEERR_HEADERS = {"X-Api-Key": SEERR_API_KEY} if SEERR_API_KEY else {}

GUEST_MOVIE_ROOT = "/data/media/movies-guests"
GUEST_TV_ROOT = "/data/media/tv-guests"


def _get_root_folder_id(service_url, api_key, target_path):
    """Get root folder ID from Sonarr/Radarr by path."""
    try:
        r = requests.get(
            f"{service_url}/api/v3/rootfolder",
            headers={"X-Api-Key": api_key},
            timeout=API_TIMEOUT,
        )
        if r.status_code != 200:
            return None
        for folder in r.json():
            if folder.get("path") == target_path:
                return folder.get("id")
    except requests.RequestException:
        pass
    return None


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


def import_and_configure_seerr_user(jellyfin_username, jellyfin_user_id):
    """Import Jellyfin user into Seerr and set guest root folders. Returns (success, warning)."""
    if not jellyfin_user_id:
        return False, "No Jellyfin user ID provided"

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

    # Get guest root folder IDs from Sonarr/Radarr
    movie_root_id = _get_root_folder_id(RADARR_URL, RADARR_KEY, GUEST_MOVIE_ROOT)
    tv_root_id = _get_root_folder_id(SONARR_URL, SONARR_KEY, GUEST_TV_ROOT)

    if not movie_root_id or not tv_root_id:
        return False, "Guest root folders not found in Sonarr/Radarr"

    # Set user's default root folders
    settings = {
        "radarrRootFolder": GUEST_MOVIE_ROOT,
        "sonarrRootFolder": GUEST_TV_ROOT,
    }
    try:
        r = requests.post(
            f"{SEERR_URL}/api/v1/user/{seerr_user_id}/settings/main",
            json=settings,
            headers=SEERR_HEADERS,
            timeout=API_TIMEOUT,
        )
        if r.status_code in (200, 201):
            return True, None
        return False, f"Failed to set Seerr user settings (HTTP {r.status_code})"
    except requests.RequestException as e:
        return False, f"Failed to set Seerr user settings: {e}"
