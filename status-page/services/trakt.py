import requests

from config import RADARR_KEY, RADARR_URL, SONARR_KEY, SONARR_URL


def create_sonarr_import_list(trakt_username, access_token, refresh_token, expires_iso):
    payload = {
        "enableAutomaticAdd": True, "searchForMissingEpisodes": True,
        "shouldMonitor": "all", "monitorNewItems": "all",
        "rootFolderPath": "/data/media/guest-tv", "qualityProfileId": 1,
        "seriesType": "standard", "seasonFolder": True,
        "name": f"Trakt - {trakt_username}",
        "implementation": "TraktUserImport", "configContract": "TraktUserSettings", "listType": "trakt",
        "fields": [
            {"name": "accessToken", "value": access_token},
            {"name": "refreshToken", "value": refresh_token},
            {"name": "expires", "value": expires_iso},
            {"name": "authUser", "value": trakt_username},
            {"name": "traktListType", "value": 0},
            {"name": "username", "value": ""}, {"name": "limit", "value": 100},
        ], "tags": [],
    }
    r = requests.post(
        f"{SONARR_URL}/api/v3/importlist?forceSave=true",
        headers={"X-Api-Key": SONARR_KEY, "Content-Type": "application/json"},
        json=payload, timeout=10,
    )
    if r.status_code not in (200, 201):
        raise RuntimeError(f"Sonarr: HTTP {r.status_code}")


def create_radarr_import_list(trakt_username, access_token, refresh_token, expires_iso):
    payload = {
        "enabled": True, "enableAuto": True, "monitor": "movieOnly",
        "rootFolderPath": "/data/media/guest-movies", "qualityProfileId": 1,
        "searchOnAdd": True, "minimumAvailability": "released",
        "name": f"Trakt - {trakt_username}",
        "implementation": "TraktUserImport", "configContract": "TraktUserSettings", "listType": "trakt",
        "fields": [
            {"name": "accessToken", "value": access_token},
            {"name": "refreshToken", "value": refresh_token},
            {"name": "expires", "value": expires_iso},
            {"name": "authUser", "value": trakt_username},
            {"name": "traktListType", "value": 0},
            {"name": "username", "value": ""}, {"name": "limit", "value": 100},
        ], "tags": [],
    }
    r = requests.post(
        f"{RADARR_URL}/api/v3/importlist?forceSave=true",
        headers={"X-Api-Key": RADARR_KEY, "Content-Type": "application/json"},
        json=payload, timeout=10,
    )
    if r.status_code not in (200, 201):
        raise RuntimeError(f"Radarr: HTTP {r.status_code}")
