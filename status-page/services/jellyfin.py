import requests

from config import API_TIMEOUT, JELLYFIN_API_KEY, JELLYFIN_URL

HEADERS = {"X-Emby-Token": JELLYFIN_API_KEY}

GUEST_LIBRARY_PATHS = {"/movies-guests", "/tv-guests"}


def _get_guest_library_ids():
    """Fetch Jellyfin library IDs for guest folders."""
    try:
        r = requests.get(
            f"{JELLYFIN_URL}/Library/VirtualFolders",
            headers=HEADERS,
            timeout=API_TIMEOUT,
        )
        if r.status_code != 200:
            return []
        folders = r.json()
        ids = []
        for folder in folders:
            locations = folder.get("Locations", [])
            if any(loc in GUEST_LIBRARY_PATHS for loc in locations):
                ids.append(folder["ItemId"])
        return ids
    except requests.RequestException:
        return []


def _set_user_policy(user_id, guest_library_ids):
    """Restrict user to guest libraries with content deletion enabled."""
    try:
        # Fetch current policy (includes required fields like AuthenticationProviderId)
        r = requests.get(
            f"{JELLYFIN_URL}/Users/{user_id}",
            headers=HEADERS,
            timeout=API_TIMEOUT,
        )
        if r.status_code != 200:
            return False
        current_policy = r.json().get("Policy", {})

        # Merge our restrictions into the existing policy
        current_policy.update({
            "EnableAllFolders": False,
            "EnabledFolders": guest_library_ids,
            "EnableContentDeletion": True,
            "EnableContentDeletionFromFolders": guest_library_ids,
            "IsAdministrator": False,
            "EnableAllChannels": False,
        })

        r = requests.post(
            f"{JELLYFIN_URL}/Users/{user_id}/Policy",
            json=current_policy,
            headers=HEADERS,
            timeout=API_TIMEOUT,
        )
        return r.status_code == 200 or r.status_code == 204
    except requests.RequestException:
        return False


def create_jellyfin_user(username, password):
    """Create a new Jellyfin user restricted to guest libraries. Returns (success, error_message)."""
    if not JELLYFIN_API_KEY:
        return False, "Jellyfin API key not configured"
    try:
        r = requests.post(
            f"{JELLYFIN_URL}/Users/New",
            json={"Name": username, "Password": password},
            headers=HEADERS,
            timeout=API_TIMEOUT,
        )
        if r.status_code != 200:
            return False, f"Jellyfin returned {r.status_code}: {r.text[:200]}"

        user_id = r.json().get("Id")
        if not user_id:
            return False, "Jellyfin did not return a user ID"

        guest_lib_ids = _get_guest_library_ids()
        if guest_lib_ids:
            if not _set_user_policy(user_id, guest_lib_ids):
                return True, "User created but failed to restrict library access"
        else:
            return True, "User created but guest libraries not found — no library restriction applied"

        return True, None
    except requests.RequestException as e:
        return False, str(e)
