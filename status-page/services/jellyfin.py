import requests

from config import API_TIMEOUT, JELLYFIN_KEY, JELLYFIN_URL


def create_jellyfin_user(guest_name, library_ids=None):
    headers = {"X-Emby-Token": JELLYFIN_KEY}
    r = requests.post(f"{JELLYFIN_URL}/Users/New",
        headers=headers, json={"Name": guest_name}, timeout=API_TIMEOUT)
    r.raise_for_status()
    user = r.json()
    user_id = user["Id"]
    if library_ids:
        policy = user.get("Policy", {})
        policy["EnableAllFolders"] = False
        policy["EnabledFolders"] = library_ids
        requests.post(f"{JELLYFIN_URL}/Users/{user_id}/Policy",
            headers=headers, json=policy, timeout=API_TIMEOUT)
    return user_id


def delete_jellyfin_user(user_id):
    headers = {"X-Emby-Token": JELLYFIN_KEY}
    requests.delete(f"{JELLYFIN_URL}/Users/{user_id}",
        headers=headers, timeout=API_TIMEOUT)


def get_guest_library_ids():
    headers = {"X-Emby-Token": JELLYFIN_KEY}
    r = requests.get(f"{JELLYFIN_URL}/Library/VirtualFolders",
        headers=headers, timeout=API_TIMEOUT)
    r.raise_for_status()
    ids = []
    for lib in r.json():
        if lib["Name"] in ("Guest TV", "Guest Movies"):
            ids.append(lib["ItemId"])
    return ids
