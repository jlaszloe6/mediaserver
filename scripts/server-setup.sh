#!/bin/bash
# server-setup.sh - Provision a fresh Ubuntu server for the media server stack
#
# Run this ONCE on a fresh Ubuntu 24.04 install to configure:
# - mediaserver system user
# - Docker prerequisites
# - NFS mount
# - Firewall (UFW)
# - Systemd drop-ins (Docker waits for NFS)
# - sysctl (route_localnet for VPN DNAT)
# - PAM SSH agent auth (passwordless sudo for key-based SSH)
#
# Prerequisites:
#   - Ubuntu 24.04 with Docker installed
#   - NAS at $NAS_IP with NFS export
#   - Run as root or with sudo
#
# Usage: sudo ./scripts/server-setup.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root or with sudo" >&2
    exit 1
fi

# --- Configuration (edit these) ---

SERVER_IP="${SERVER_IP:?Set SERVER_IP}"
NAS_IP="${NAS_IP:?Set NAS_IP}"
NAS_EXPORT="${NAS_EXPORT:?Set NAS_EXPORT}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/mediaserver}"
ADMIN_USER="${ADMIN_USER:?Set ADMIN_USER}"

echo "=== Media Server - Server Setup ==="
echo "Server IP:  $SERVER_IP"
echo "NAS:        $NAS_IP:$NAS_EXPORT"
echo "Mount:      $MOUNT_POINT"
echo "Admin user: $ADMIN_USER"
echo ""

# --- 1. Create mediaserver system user ---

echo "[1/8] Creating mediaserver user..."
if id mediaserver &>/dev/null; then
    echo "  User 'mediaserver' already exists"
else
    useradd -r -s /bin/bash -d /opt/mediaserver mediaserver
    echo "  Created user 'mediaserver'"
fi
usermod -aG docker mediaserver
usermod -aG mediaserver "$ADMIN_USER"
mkdir -p /opt/mediaserver
chown mediaserver:mediaserver /opt/mediaserver
chmod 2775 /opt/mediaserver

# --- 2. NFS mount ---

echo "[2/8] Setting up NFS mount..."
apt-get install -y -qq nfs-common
mkdir -p "$MOUNT_POINT"

if ! grep -q "$NAS_IP:$NAS_EXPORT" /etc/fstab; then
    echo "$NAS_IP:$NAS_EXPORT $MOUNT_POINT nfs defaults,_netdev,auto 0 0" >> /etc/fstab
    echo "  Added fstab entry"
else
    echo "  fstab entry already exists"
fi
mount -a 2>/dev/null || true

# --- 3. Docker waits for NFS ---

echo "[3/8] Configuring Docker to wait for NFS..."
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/wait-for-nfs.conf << EOF
[Unit]
After=remote-fs.target
Requires=remote-fs.target
EOF
systemctl daemon-reload

# --- 4. sysctl: route_localnet for VPN DNAT ---

echo "[4/8] Setting sysctl route_localnet..."
if ! grep -q 'net.ipv4.conf.all.route_localnet' /etc/sysctl.d/99-mediaserver.conf 2>/dev/null; then
    cat > /etc/sysctl.d/99-mediaserver.conf << EOF
# Allow DNAT to localhost for WireGuard VPN clients
net.ipv4.conf.all.route_localnet = 1
EOF
    sysctl -p /etc/sysctl.d/99-mediaserver.conf
    echo "  Set route_localnet=1"
else
    echo "  Already configured"
fi

# --- 5. UFW firewall ---

echo "[5/8] Configuring UFW firewall..."
ufw --force enable
ufw allow 22/tcp comment "SSH"
ufw allow 32400/tcp comment "Plex"
ufw allow 80/tcp comment "Caddy HTTP redirect"
ufw allow 443/tcp comment "Caddy HTTPS"
ufw allow 51820/udp comment "WireGuard"
ufw allow in on wg0 from 10.13.13.0/24 comment "WireGuard VPN"
ufw allow from 192.168.1.0/24 to any port 53 comment "DNS (dnsmasq for LAN)"
ufw deny 3389/tcp comment "Block RDP"
echo "  UFW rules configured"

# --- 6. PAM SSH agent auth (passwordless sudo for key-based SSH) ---

echo "[6/8] Setting up PAM SSH agent auth..."
apt-get install -y -qq libpam-ssh-agent-auth

# Copy admin user's authorized keys for sudo verification
mkdir -p /etc/security
cp "/home/$ADMIN_USER/.ssh/authorized_keys" /etc/security/authorized_keys_sudo
chmod 644 /etc/security/authorized_keys_sudo

# Add to PAM sudo config
if ! grep -q pam_ssh_agent_auth /etc/pam.d/sudo; then
    sed -i '1a auth       sufficient   pam_ssh_agent_auth.so file=/etc/security/authorized_keys_sudo' /etc/pam.d/sudo
fi

# Allow SSH_AUTH_SOCK through sudo
cat > /etc/sudoers.d/ssh-agent << EOF
Defaults env_keep += "SSH_AUTH_SOCK"
EOF
chmod 440 /etc/sudoers.d/ssh-agent
visudo -c -f /etc/sudoers.d/ssh-agent

# --- 7. SSH server config ---

echo "[7/8] Configuring SSH server..."
if ! grep -q '^AllowAgentForwarding yes' /etc/ssh/sshd_config; then
    echo 'AllowAgentForwarding yes' >> /etc/ssh/sshd_config
fi
systemctl reload ssh

# --- 8. Git safe directory ---

echo "[8/8] Setting git safe directory..."
sudo -u mediaserver git config --global --add safe.directory /opt/mediaserver
sudo -u "$ADMIN_USER" git config --global --add safe.directory /opt/mediaserver

echo ""
echo "=== Server setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Clone repo:  sudo -u mediaserver git clone <repo-url> /opt/mediaserver"
echo "  2. Copy .env:   cp .env /opt/mediaserver/.env"
echo "  3. Start stack: cd /opt/mediaserver && sudo -u mediaserver docker compose up -d"
echo "  4. Run setup:   cd /opt/mediaserver && bash scripts/init-setup.sh"
echo "  5. Restore:     cd /opt/mediaserver && bash scripts/restore.sh"
