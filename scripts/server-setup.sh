#!/bin/bash
# server-setup.sh - Provision a fresh Ubuntu server for the media server stack
#
# Run this ONCE on a fresh Ubuntu 24.04 install to configure:
# - mediaserver system user
# - Docker prerequisites
# - NFS mount
# - NAS route pinned to a dedicated wired NIC, if present (keeps NFS off
#   the WiFi radio so it can't contend with WiFi streaming bandwidth)
# - Network watchdog (self-heals a stuck NetworkManager connection)
# - Firewall (UFW)
# - Systemd drop-ins (Docker waits for NFS)
# - PAM SSH agent auth (passwordless sudo for key-based SSH)
#
# Prerequisites:
#   - Ubuntu 24.04 with Docker installed
#   - NAS at $NAS_IP with NFS export
#   - Run as root or with sudo
#
# Usage: sudo ./scripts/server-setup.sh
#   sudo WIRED_IFACE=enp0s31f6 ./scripts/server-setup.sh   # if a spare wired NIC exists
#   (the var must come AFTER "sudo": sudo's default env_reset strips
#   anything set only in the invoking shell's own environment before it)

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
WIRED_IFACE="${WIRED_IFACE:-}"

echo "=== Media Server - Server Setup ==="
echo "Server IP:  $SERVER_IP"
echo "NAS:        $NAS_IP:$NAS_EXPORT"
echo "Mount:      $MOUNT_POINT"
echo "Admin user: $ADMIN_USER"
echo ""

# --- 1. Create mediaserver system user ---

echo "[1/10] Creating mediaserver user..."
if id mediaserver &>/dev/null; then
    echo "  User 'mediaserver' already exists"
else
    useradd -r -s /usr/sbin/nologin -d /opt/mediaserver mediaserver
    echo "  Created user 'mediaserver'"
fi
usermod -aG docker mediaserver
usermod -aG mediaserver "$ADMIN_USER"
mkdir -p /opt/mediaserver
chown mediaserver:mediaserver /opt/mediaserver
chmod 2775 /opt/mediaserver

# --- 2. Pin NAS traffic to a dedicated wired NIC (optional) ---
#
# If the host's primary network path is WiFi (see network-watchdog below),
# NFS reads compete with WiFi airtime used to stream to LAN clients — heavy
# concurrent NFS I/O (e.g. several retried transcode reads of the same large
# file) can starve unrelated requests on the same radio for minutes at a
# time. When a spare wired NIC exists, route NAS-bound traffic over it
# instead, leaving the WiFi radio free for client-facing streaming. Skipped
# entirely when WIRED_IFACE isn't set (e.g. a wired-only or single-NIC host,
# where this isn't needed).
#
# nas-route.service (not a NetworkManager dispatcher script alone) applies
# the route: a dispatcher script only fires asynchronously off NM's own
# event queue, with no ordering guarantee relative to the NFS mount unit —
# on every future reboot, WiFi reaching network-online.target before the
# wired NIC comes up would let the mount race ahead and bind its initial
# connection to WiFi regardless. A systemd drop-in on the NFS mount unit
# itself (Wants=/After=nas-route.service, added in the NFS mount step
# below) is what actually closes that race on every boot — merely ordering
# this service Before=remote-fs-pre.target would NOT be enough, since that
# target is a passive ordering point nothing pulls into the boot transaction
# on its own.
#
# The dispatcher script still matters for anything AFTER boot: reapplying
# the route if the cable is unplugged and replugged, and removing it if the
# link drops (see below) so traffic doesn't blackhole against a dead NIC.
#
# Installed at /usr/local/sbin rather than under /opt/mediaserver: the repo
# isn't cloned there yet at this point in provisioning (see "Next steps" at
# the end of this script), and nas-route.service must be able to run
# starting from the very next boot regardless of when that clone happens.

echo "[2/10] Pinning NAS route to wired NIC..."
if [ -n "$WIRED_IFACE" ]; then
    # Computed once here (not re-derived in the NFS mount step below) so the
    # retry guidance below and the actual mount-unit drop-in always agree,
    # even when MOUNT_POINT isn't the default /mnt/mediaserver.
    MOUNT_UNIT="$(systemd-escape --path --suffix=mount "$MOUNT_POINT")"

    cat > /usr/local/sbin/nas-route-setup.sh << EOF
#!/bin/sh
# Pin NAS traffic to the wired NIC. Run by nas-route.service before every
# NFS mount attempt (see server-setup.sh for why). Safe to rerun manually
# any time, e.g. after reconnecting the cable.
set -eu
NAS_IP=$NAS_IP
WIRED_IF=$WIRED_IFACE
MOUNT_UNIT=$MOUNT_UNIT

is_usable() {
    # "ip link show up" only reflects administrative state — it stays true
    # while unplugged (NO-CARRIER) or before DHCP finishes. Require an
    # actual carrier and a global IPv4 address before trusting the link.
    [ "\$(cat "/sys/class/net/\$1/carrier" 2>/dev/null)" = "1" ] && \\
        ip -4 -o addr show dev "\$1" scope global 2>/dev/null | grep -q .
}

# Keep the wired NIC from becoming the general default route (e.g. if it
# picks up a gateway from DHCP or an IPv6 RA on the same LAN) — it should
# carry only the NAS route below, leaving WiFi as the default path for
# everything else. IPv4 and IPv6 never-default are separate NetworkManager
# properties (ipv6 defaults to enabled-as-default-candidate), so both need
# setting or an IPv6 gateway could still hijack the default route on its own.
# Applied via an active NM connection, NOT gated on is_usable() below: an
# IPv6 RA can already make this interface a default-route candidate before
# DHCPv4 (which is_usable() requires) finishes, so this can't wait for it.
apply_never_default() {
    conn=\$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v ifc="\$WIRED_IF" '\$2==ifc {print \$1; exit}')
    if [ -n "\$conn" ]; then
        nmcli connection modify "\$conn" \\
            ipv4.never-default yes ipv4.route-metric 900 \\
            ipv6.never-default yes ipv6.route-metric 900
        # "device reapply", NOT "connection up": these are route-level
        # settings NM can push onto the already-active device in place.
        # "connection up" on a connection whose settings just changed can
        # force a full deactivate/reactivate cycle, which would emit its own
        # down/up dispatcher events and re-enter this exact script — "device
        # reapply" applies the change without any such device-state
        # transition, so it can't self-trigger the dispatcher at all.
        nmcli device reapply "\$WIRED_IF" >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

guarded=0
for _ in \$(seq 1 15); do
    if [ "\$guarded" = 0 ] && apply_never_default; then
        guarded=1
    fi
    is_usable "\$WIRED_IF" && break
    sleep 1
done
[ "\$guarded" = 0 ] && apply_never_default || true

if ! is_usable "\$WIRED_IF"; then
    echo "WARNING: \$WIRED_IF never came up — traffic stays on the default route for now." >&2
    echo "Once it's connected, rerun this script or: systemctl restart \$MOUNT_UNIT" >&2
    # Exit non-zero so this shows as failed, not succeeded, in nas-route's
    # status/logs — the mount unit's Wants= (not Requires=) already lets it
    # proceed anyway, and every mount/remount re-runs this script fresh (no
    # RemainAfterExit here), so a later retry doesn't need any special
    # handling to get another chance at pinning the route.
    exit 1
fi

ip route replace \${NAS_IP}/32 dev "\$WIRED_IF"
echo "NAS route pinned to \$WIRED_IF"
EOF
    chmod 755 /usr/local/sbin/nas-route-setup.sh

    # dispatcher.d ships with the network-manager package, but may not exist
    # yet on a fresh install with no dispatcher scripts added before (and
    # under this script's own set -e, writing into a missing directory
    # would abort the rest of provisioning entirely).
    mkdir -p /etc/NetworkManager/dispatcher.d
    cat > /etc/NetworkManager/dispatcher.d/99-nas-via-wired.sh << EOF
#!/bin/sh
# Reapply/clear the NAS route on link changes after boot (nas-route.service
# handles the initial pin ahead of the NFS mount — see server-setup.sh).
# \$1/\$2 are the interface and action NetworkManager passes to every
# dispatcher script (e.g. "enp0s31f6 up", "enp0s31f6 down").
NAS_IP=$NAS_IP
WIRED_IF=$WIRED_IFACE
IFACE="\$1"
ACTION="\$2"

if [ "\$IFACE" = "\$WIRED_IF" ] && [ "\$ACTION" = "down" ]; then
    # Remove the pinned route so NAS traffic falls back to the default
    # (WiFi) route instead of blackholing against a dead link.
    ip route del \${NAS_IP}/32 dev "\$WIRED_IF" 2>/dev/null || true
    exit 0
fi

if [ "\$IFACE" = "\$WIRED_IF" ] && [ "\$ACTION" = "up" ] && \\
   [ "\$(cat /sys/class/net/\$WIRED_IF/carrier 2>/dev/null)" = "1" ]; then
    # Delegate to the same script nas-route.service uses, rather than just
    # replacing the /32 route here — this covers the case where the wired
    # NIC wasn't up during boot (nas-route.service already gave up) and only
    # comes up later: without also applying the never-default/route-metric
    # guard here, a DHCP gateway on this NIC could still hijack the default
    # route out from under WiFi at that point.
    #
    # ACTION must be "up" specifically, not any event for this interface:
    # never-default/route-metric are persistent profile settings — once
    # applied on "up", they don't need reapplying just because a lease
    # renews. nas-route-setup.sh uses "nmcli device reapply", not
    # "connection up" (see below), so this isn't about avoiding a disruptive
    # reactivation — it's just no reason to touch nmcli/NetworkManager on
    # every routine dhcp4-change/dhcp6-change when nothing has changed.
    #
    # By design, this only affects FUTURE connections/mounts, not an NFS
    # mount already open over WiFi from earlier in this same boot — a route
    # change never migrates an already-established TCP connection (see the
    # 2026-09-01 incident notes in CLAUDE.md). Actually moving that live
    # mount would mean stopping every container using it first (the same
    # disruption as the live fix), so it's deliberately not automated here;
    # the WARNING nas-route-setup.sh prints already tells the operator how
    # to remount by hand. That boot simply keeps running NFS over WiFi.
    #
    # This deliberately does NOT check whether NFS is currently mounted
    # before applying the route/guard live. Skipping it while mounted would
    # look more cautious but isn't: link-down cleanup and the never-default
    # guard both need to keep working regardless of mount state — gating on
    # it would leave the wired NIC exposed as a stray default-route
    # candidate for longer, and a dropped link still needs its /32 route
    # removed whether or not something happens to be mounted at that moment.
    # A route changing under an established connection was verified live on
    # this host (2026-09-01 fix) to not disrupt it, thanks to loose
    # rp_filter — on a host with strict rp_filter this could theoretically
    # still disrupt an in-flight NFS session, but that's a difference in
    # network config, not a flaw in this logic, and isn't being engineered
    # around here. No connection is force-migrated either way.
    #
    # Gated on carrier only, NOT a global IPv4 address: nas-route-setup.sh's
    # own never-default guard must run even when the interface only ever
    # gets an IPv6 RA/gateway and no (or slow) DHCPv4 — gating on IPv4 here
    # would skip calling it in exactly that case, the same gap this guard
    # exists to close.
    #
    # The \$IFACE check matters: this dispatcher fires for EVERY interface
    # event on the host, not just the wired one (WiFi DHCP renewals, AP
    # roams, etc.). Without it, nas-route-setup.sh would needlessly re-run
    # its whole check-and-apply sequence on every unrelated event.
    /usr/local/sbin/nas-route-setup.sh 2>/dev/null || true
    exit 0
fi

if [ "\$IFACE" = "\$WIRED_IF" ] && [ "\$ACTION" = "dhcp4-change" ]; then
    # DHCPv4 can complete, or a lease can be lost, without a fresh up/down
    # event: carrier is often reported before DHCPv4 finishes, so the "up"
    # branch above can already have given up and exited by the time the
    # address actually arrives — nothing would ever revisit it without this.
    # Deliberately NOT delegating to nas-route-setup.sh here: no need to
    # re-run nmcli/the never-default guard on every routine lease renewal
    # when nothing has actually changed profile-wise (see the ACTION="up"
    # restriction above). Just sync the /32 route to current reachability.
    if [ "\$(cat /sys/class/net/\$WIRED_IF/carrier 2>/dev/null)" = "1" ] && \\
       ip -4 -o addr show dev "\$WIRED_IF" scope global 2>/dev/null | grep -q .; then
        ip route replace \${NAS_IP}/32 dev "\$WIRED_IF" 2>/dev/null || true
    else
        ip route del \${NAS_IP}/32 dev "\$WIRED_IF" 2>/dev/null || true
    fi
fi
EOF
    chmod 755 /etc/NetworkManager/dispatcher.d/99-nas-via-wired.sh

    cat > /etc/systemd/system/nas-route.service << EOF
[Unit]
Description=Pin NAS route to wired NIC before NFS mounts
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nas-route-setup.sh
EOF
    systemctl daemon-reload
    # "start" (not just enabling it) also runs it now, synchronously, so the
    # mount immediately below picks up the route on this very first boot too.
    # It isn't started via a [Install]/WantedBy= — remote-fs-pre.target is a
    # passive ordering point that nothing pulls into the boot transaction on
    # its own; the actual "run before this mount" guarantee below (a drop-in
    # directly on the NFS mount unit) is what makes it start on every boot.
    #
    # "|| true": the wired NIC not coming up in time makes the service exit
    # non-zero by design (see nas-route-setup.sh), which "systemctl start"
    # then also reports as failed — under this script's own set -e, an
    # unguarded call here would abort the rest of provisioning entirely
    # instead of just falling back to WiFi as intended.
    systemctl start nas-route.service || true
    echo "  nas-route.service installed and run (see 'systemctl status nas-route' for the result)"
else
    echo "  WIRED_IFACE not set, skipping (no dedicated wired NIC for the NAS)"
fi

# --- 3. NFS mount ---

echo "[3/10] Setting up NFS mount..."
apt-get install -y -qq nfs-common
mkdir -p "$MOUNT_POINT"

if ! grep -q "$NAS_IP:$NAS_EXPORT" /etc/fstab; then
    echo "$NAS_IP:$NAS_EXPORT $MOUNT_POINT nfs defaults,_netdev,auto 0 0" >> /etc/fstab
    echo "  Added fstab entry"
else
    echo "  fstab entry already exists"
fi

if [ -n "$WIRED_IFACE" ]; then
    # Tie nas-route.service directly into this mount unit's own dependency
    # chain, rather than relying on remote-fs-pre.target to pull it in (it
    # won't — see above). This is what actually guarantees the route exists
    # before the mount is attempted on every future boot.
    #
    # Wants= (not Requires=): the wired NIC not coming up in time is a
    # tolerable, already-warned-about degraded case (NFS just falls back to
    # WiFi) — it must not be able to block the mount, and by extension the
    # whole stack, entirely. Requires= would propagate nas-route.service's
    # failure into a hard mount failure instead.
    # ($MOUNT_UNIT was already computed in step 2, above — reused here so
    # this drop-in and nas-route-setup.sh's retry guidance can't disagree.)
    mkdir -p "/etc/systemd/system/${MOUNT_UNIT}.d"
    cat > "/etc/systemd/system/${MOUNT_UNIT}.d/nas-route.conf" << 'EOF'
[Unit]
Wants=nas-route.service
After=nas-route.service
EOF
    systemctl daemon-reload
fi

mount -a 2>/dev/null || true

# --- 4. Docker waits for NFS ---

echo "[4/10] Configuring Docker to wait for NFS..."
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/wait-for-nfs.conf << EOF
[Unit]
After=remote-fs.target
Requires=remote-fs.target
EOF
systemctl daemon-reload

# --- 5. Network watchdog ---

echo "[5/10] Installing network watchdog..."
cat > /etc/systemd/system/network-watchdog.service << EOF
[Unit]
Description=Network connectivity watchdog (self-heal stuck NetworkManager state)
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/mediaserver/scripts/network-watchdog.sh
EOF
cat > /etc/systemd/system/network-watchdog.timer << EOF
[Unit]
Description=Run network-watchdog every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now network-watchdog.timer

# --- 6. UFW firewall ---

LAN_SUBNET="${LAN_SUBNET:-192.168.1.0/24}"

echo "[6/10] Configuring UFW firewall..."
ufw --force enable
ufw default deny incoming
ufw allow from "$LAN_SUBNET" to any port 22 proto tcp comment "SSH (LAN only)"
ufw allow 443/tcp comment "Caddy HTTPS"
ufw allow 51413/tcp comment "Transmission peer port"
ufw allow 51413/udp comment "Transmission peer port (uTP/DHT)"
ufw allow from "$LAN_SUBNET" to any port 53 comment "DNS (dnsmasq for LAN)"
ufw deny 3389/tcp comment "Block RDP"
echo "  UFW rules configured"

# --- 7. PAM SSH agent auth (passwordless sudo for key-based SSH) ---

echo "[7/10] Setting up PAM SSH agent auth..."
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

# --- 8. SSH server config ---

echo "[8/10] Configuring SSH server..."
if ! grep -q '^AllowAgentForwarding yes' /etc/ssh/sshd_config; then
    echo 'AllowAgentForwarding yes' >> /etc/ssh/sshd_config
fi
if grep -q '^X11Forwarding yes' /etc/ssh/sshd_config; then
    sed -i 's/^X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config
elif ! grep -q '^X11Forwarding no' /etc/ssh/sshd_config; then
    echo 'X11Forwarding no' >> /etc/ssh/sshd_config
fi
systemctl reload ssh

# --- 9. fail2ban ---

echo "[9/10] Setting up fail2ban..."
apt-get install -y -qq fail2ban
cat > /etc/fail2ban/jail.d/sshd.local << EOF
[sshd]
enabled = true
EOF
systemctl enable --now fail2ban
systemctl reload fail2ban

# --- 10. Git safe directory ---

echo "[10/10] Setting git safe directory..."
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
