import xml.etree.ElementTree as ET

import requests
from flask import current_app

from config import API_TIMEOUT, PLEX_TOKEN, PLEX_URL


def share_plex_guest_libraries(guest_email):
    """Invite a Plex user and share only Guest TV / Guest Movies libraries via plex.tv API."""
    if not PLEX_TOKEN:
        raise RuntimeError("PLEX_TOKEN not configured")

    machine_id = ET.fromstring(
        requests.get(f"{PLEX_URL}/identity", params={"X-Plex-Token": PLEX_TOKEN}, timeout=API_TIMEOUT).text
    ).get("machineIdentifier")
    if not machine_id:
        raise RuntimeError("Could not get Plex machine identifier")

    # Get section IDs from plex.tv (different from local keys)
    server_root = ET.fromstring(
        requests.get(
            f"https://plex.tv/api/servers/{machine_id}",
            params={"X-Plex-Token": PLEX_TOKEN},
            headers={"X-Plex-Client-Identifier": "mediaserver-statuspage"},
            timeout=API_TIMEOUT,
        ).text
    )
    guest_section_ids = []
    for server in server_root.findall("Server"):
        for section in server.findall("Section"):
            if section.get("title") in ("Guest TV", "Guest Movies"):
                guest_section_ids.append(int(section.get("id")))
    if not guest_section_ids:
        raise RuntimeError("Guest TV / Guest Movies libraries not found on plex.tv")

    r = requests.post(
        f"https://plex.tv/api/servers/{machine_id}/shared_servers",
        params={"X-Plex-Token": PLEX_TOKEN},
        headers={"Content-Type": "application/json", "X-Plex-Client-Identifier": "mediaserver-statuspage"},
        json={
            "server_id": machine_id,
            "shared_server": {
                "library_section_ids": guest_section_ids,
                "invited_email": guest_email,
                "sharing_settings": {},
            },
        },
        timeout=15,
    )
    if r.status_code in (200, 201):
        current_app.logger.info(f"Shared Plex guest libraries with {guest_email}")
    elif "already" in r.text.lower():
        current_app.logger.info(f"Plex libraries already shared with {guest_email}")
    else:
        raise RuntimeError(f"Plex sharing API returned HTTP {r.status_code}: {r.text[:200]}")


def revoke_plex_share(guest_email):
    """Revoke Plex library share for a guest."""
    machine_id = ET.fromstring(
        requests.get(f"{PLEX_URL}/identity", params={"X-Plex-Token": PLEX_TOKEN}, timeout=API_TIMEOUT).text
    ).get("machineIdentifier")
    r = requests.get(
        f"https://plex.tv/api/servers/{machine_id}/shared_servers",
        params={"X-Plex-Token": PLEX_TOKEN},
        headers={"X-Plex-Client-Identifier": "mediaserver-statuspage"},
        timeout=API_TIMEOUT,
    )
    if r.status_code == 200:
        for ss in ET.fromstring(r.text).findall("SharedServer"):
            if ss.get("email", "").lower() == guest_email.lower():
                share_id = ss.get("id")
                requests.delete(
                    f"https://plex.tv/api/servers/{machine_id}/shared_servers/{share_id}",
                    params={"X-Plex-Token": PLEX_TOKEN},
                    headers={"X-Plex-Client-Identifier": "mediaserver-statuspage"},
                    timeout=API_TIMEOUT,
                )
                current_app.logger.info(f"Revoked Plex share for {guest_email} (share {share_id})")
                break
