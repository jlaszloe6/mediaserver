import requests
from flask import current_app

from config import WG_EASY_URL, WG_PASSWORD


def _wg_easy_session():
    """Get an authenticated session for wg-easy API."""
    s = requests.Session()
    r = s.post(f"{WG_EASY_URL}/api/session", json={"password": WG_PASSWORD}, timeout=5)
    r.raise_for_status()
    return s


def create_wg_client(guest_name):
    """Create a WireGuard client in wg-easy and return its ID."""
    if not WG_PASSWORD:
        raise RuntimeError("WG_PASSWORD not configured")
    s = _wg_easy_session()
    r = s.post(f"{WG_EASY_URL}/api/wireguard/client", json={"name": guest_name}, timeout=5)
    r.raise_for_status()
    # wg-easy API returns {"success": true} — fetch client list to get the ID
    r = s.get(f"{WG_EASY_URL}/api/wireguard/client", timeout=5)
    r.raise_for_status()
    clients = [c for c in r.json() if c["name"] == guest_name]
    if not clients:
        raise RuntimeError(f"Client '{guest_name}' not found after creation")
    return clients[-1]["id"]


def delete_wg_client(client_id):
    """Delete a WireGuard client by ID."""
    s = _wg_easy_session()
    s.delete(f"{WG_EASY_URL}/api/wireguard/client/{client_id}", timeout=5)


def get_client_qr(client_id):
    """Get QR code SVG for a WireGuard client."""
    s = _wg_easy_session()
    r = s.get(f"{WG_EASY_URL}/api/wireguard/client/{client_id}/qrcode.svg", timeout=5)
    r.raise_for_status()
    return r.content


def get_client_config(client_id):
    """Get WireGuard configuration file for a client."""
    s = _wg_easy_session()
    r = s.get(f"{WG_EASY_URL}/api/wireguard/client/{client_id}/configuration", timeout=5)
    r.raise_for_status()
    return r.content
