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


def _verify_user_policy(user_id, guest_library_ids):
    """Re-fetch the user's policy and confirm the restriction actually took effect."""
    try:
        r = requests.get(
            f"{JELLYFIN_URL}/Users/{user_id}",
            headers=HEADERS,
            timeout=API_TIMEOUT,
        )
        if r.status_code != 200:
            return False
        policy = r.json().get("Policy", {})
        if policy.get("IsAdministrator") or policy.get("EnableAllFolders"):
            return False
        return set(policy.get("EnabledFolders", [])) == set(guest_library_ids)
    except requests.RequestException:
        return False


def _delete_jellyfin_user(user_id):
    """Remove a Jellyfin user. Used to roll back a guest account that couldn't be restricted."""
    try:
        requests.delete(
            f"{JELLYFIN_URL}/Users/{user_id}",
            headers=HEADERS,
            timeout=API_TIMEOUT,
        )
    except requests.RequestException:
        pass


def create_jellyfin_user(username, password):
    """Create a new Jellyfin user restricted to guest libraries. Returns (success, warning, jellyfin_user_id).

    Fails closed: if library restriction can't be established and verified, the
    Jellyfin account is deleted and creation is reported as failed, rather than
    leaving behind a guest account with full library access.
    """
    if not JELLYFIN_API_KEY:
        return False, "Jellyfin API key not configured", None
    try:
        r = requests.post(
            f"{JELLYFIN_URL}/Users/New",
            json={"Name": username, "Password": password},
            headers=HEADERS,
            timeout=API_TIMEOUT,
        )
        if r.status_code != 200:
            return False, f"Jellyfin returned {r.status_code}: {r.text[:200]}", None

        user_id = r.json().get("Id")
        if not user_id:
            return False, "Jellyfin did not return a user ID", None

        guest_lib_ids = _get_guest_library_ids()
        if not guest_lib_ids:
            _delete_jellyfin_user(user_id)
            return False, "Guest libraries not found in Jellyfin — refusing to create an unrestricted account", None

        if not _set_user_policy(user_id, guest_lib_ids):
            _delete_jellyfin_user(user_id)
            return False, "Failed to restrict library access — account rolled back", None

        if not _verify_user_policy(user_id, guest_lib_ids):
            _delete_jellyfin_user(user_id)
            return False, "Library restriction did not verify after being applied — account rolled back", None

        return True, None, user_id
    except requests.RequestException as e:
        return False, str(e), None
