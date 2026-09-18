#!/bin/bash
# server-setup.sh - Provision a fresh Ubuntu server for the media server stack
#
# Run this ONCE on a fresh Ubuntu 24.04 install to configure:
# - mediaserver system user
# - Docker prerequisites
# - Primary media storage: a local SSD, formatted ext4 (required)
# - NFS mount (OPTIONAL, off by default - see ENABLE_NFS below; this stack's
#   primary storage is the local SSD, not NFS/a NAS)
# - NAS route pinned to a dedicated wired NIC, if present and ENABLE_NFS=true
# - Network watchdog (self-heals a stuck NetworkManager connection)
# - Firewall (UFW)
# - Systemd drop-ins (Docker waits for the SSD mount)
# - PAM SSH agent auth (passwordless sudo for key-based SSH)
#
# Prerequisites:
#   - Ubuntu 24.04 with Docker installed
#   - A local SSD/disk attached for primary media storage, identified by a
#     stable path under /dev/disk/by-id/ (NOT /dev/sdX, which can change
#     across reboots/replugs - this script formats the device you give it)
#   - Run as root or with sudo
#
# Usage: sudo SSD_DEVICE=/dev/disk/by-id/usb-Foo-part1 ./scripts/server-setup.sh
#   sudo ENABLE_NFS=true NAS_IP=... NAS_EXPORT=... SSD_DEVICE=... ./scripts/server-setup.sh
#       # only if you also want an NFS mount (not required by this stack)
#   sudo ENABLE_NFS=true WIRED_IFACE=enp0s31f6 NAS_IP=... NAS_EXPORT=... SSD_DEVICE=... ./scripts/server-setup.sh
#       # plus pin NFS traffic to a spare wired NIC, if present
#   (vars must come AFTER "sudo": sudo's default env_reset strips anything
#   set only in the invoking shell's own environment before it)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root or with sudo" >&2
    exit 1
fi

# --- Configuration (edit these) ---

SERVER_IP="${SERVER_IP:?Set SERVER_IP}"
ADMIN_USER="${ADMIN_USER:?Set ADMIN_USER}"

# Primary media storage (local SSD) - always required. No /dev/sdX default:
# device-node letters aren't stable across reboots/replugs, and this
# variable feeds a formatting operation later in this script.
SSD_DEVICE="${SSD_DEVICE:?Set SSD_DEVICE to the stable /dev/disk/by-id/...-partN path for the media SSD (run 'ls -l /dev/disk/by-id/' to find it)}"
SSD_MOUNT_POINT="${SSD_MOUNT_POINT:-/mnt/mediaserver-ssd}"

# NFS (optional - this stack's primary storage is the SSD above, not NFS).
# Only set NAS_IP/NAS_EXPORT and pay attention to MOUNT_POINT/WIRED_IFACE
# below if you explicitly want an NFS mount for reasons outside this stack.
ENABLE_NFS="${ENABLE_NFS:-false}"
if [ "$ENABLE_NFS" = true ]; then
    NAS_IP="${NAS_IP:?Set NAS_IP}"
    NAS_EXPORT="${NAS_EXPORT:?Set NAS_EXPORT}"
fi
MOUNT_POINT="${MOUNT_POINT:-/mnt/mediaserver}"
WIRED_IFACE="${WIRED_IFACE:-}"

echo "=== Media Server - Server Setup ==="
echo "Server IP:   $SERVER_IP"
echo "Admin user:  $ADMIN_USER"
echo "SSD device:  $SSD_DEVICE"
echo "SSD mount:   $SSD_MOUNT_POINT"
if [ "$ENABLE_NFS" = true ]; then
    echo "NFS:         $NAS_IP:$NAS_EXPORT (enabled)"
    echo "NFS mount:   $MOUNT_POINT"
else
    echo "NFS:         disabled (ENABLE_NFS=false) - this stack does not require it"
fi
echo ""

# --- 1. Create mediaserver system user ---

echo "[1/11] Creating mediaserver user..."
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

# --- 2. Provision primary media storage (local SSD) ---
#
# This is the stack's sole storage for media, downloads, and config backups
# - required unconditionally, unlike the optional NFS mount below. Detection
# is tri-state, not a simple "format if nothing else is there" check: an
# existing ext4 filesystem is reused as-is (never reformatted, so re-running
# this script against an already-provisioned host is safe), no filesystem
# means it's a fresh disk and gets one created, and any OTHER existing
# filesystem (e.g. this device's current NTFS) aborts loudly rather than
# silently skipping formatting and leaving a non-ext4 disk in place - ext4
# is required for correct hardlink semantics (Sonarr/Radarr's hardlink
# import, transmission-cleanup.sh's stat -c '%h' orphan check) and POSIX
# uid/gid ownership (the PUID/PGID convention every container here uses).

echo "[2/11] Provisioning primary media storage (SSD)..."

if [ ! -b "$SSD_DEVICE" ]; then
    echo "ERROR: $SSD_DEVICE does not resolve to a block device" >&2
    exit 1
fi

# Refuse to touch a device that's already mounted somewhere other than
# where we're about to put it - a re-run against an already-provisioned
# host should find it already at SSD_MOUNT_POINT (fine, falls through to
# the ext4 case below with nothing to do), not mounted anywhere unexpected.
EXISTING_MOUNT="$(findmnt -rn -S "$SSD_DEVICE" -o TARGET || true)"
if [ -n "$EXISTING_MOUNT" ] && [ "$EXISTING_MOUNT" != "$SSD_MOUNT_POINT" ]; then
    echo "ERROR: $SSD_DEVICE is already mounted at $EXISTING_MOUNT, not $SSD_MOUNT_POINT" >&2
    echo "Refusing to proceed against a device mounted somewhere unexpected." >&2
    exit 1
fi

SSD_FSTYPE="$(blkid -o value -s TYPE "$SSD_DEVICE" 2>/dev/null || true)"
case "$SSD_FSTYPE" in
    ext4)
        echo "  $SSD_DEVICE already ext4 - reusing, not formatting"
        ;;
    "")
        echo "  $SSD_DEVICE has no filesystem - creating ext4"
        # -m 1: reduces ext4's reserved-block ratio from the ~5% default to
        # 1%, reclaiming a few percent of the volume that's not needed on a
        # data-only disk owned by the mediaserver user, not root.
        mkfs.ext4 -L mediaserver-ssd -m 1 "$SSD_DEVICE"
        ;;
    *)
        echo "ERROR: $SSD_DEVICE has an existing '$SSD_FSTYPE' filesystem." >&2
        echo "Refusing to auto-format a non-ext4, non-empty device. If you intend" >&2
        echo "to reuse it, verify there is nothing worth keeping, then run manually:" >&2
        echo "  wipefs -a $SSD_DEVICE && mkfs.ext4 -L mediaserver-ssd -m 1 $SSD_DEVICE" >&2
        echo "and re-run this script." >&2
        exit 1
        ;;
esac

mkdir -p "$SSD_MOUNT_POINT"
SSD_UUID="$(blkid -o value -s UUID "$SSD_DEVICE")"
if ! grep -q "UUID=$SSD_UUID" /etc/fstab; then
    echo "UUID=$SSD_UUID $SSD_MOUNT_POINT ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2" >> /etc/fstab
    echo "  Added fstab entry"
else
    echo "  fstab entry already exists"
fi
mount -a 2>/dev/null || true
chown mediaserver:mediaserver "$SSD_MOUNT_POINT"

# --- 3. Pin NAS traffic to a dedicated wired NIC (optional, ENABLE_NFS only) ---
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

echo "[3/11] Pinning NAS route to wired NIC..."
if [ "$ENABLE_NFS" != true ]; then
    echo "  Skipped (ENABLE_NFS=false) - this stack's primary storage is the SSD, not NFS"
elif [ -n "$WIRED_IFACE" ]; then
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

# --- 4. NFS mount (optional, ENABLE_NFS only) ---

echo "[4/11] Setting up NFS mount..."
if [ "$ENABLE_NFS" != true ]; then
    echo "  Skipped (ENABLE_NFS=false) - this stack's primary storage is the SSD, not NFS"
else
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
        # ($MOUNT_UNIT was already computed in step 3, above — reused here so
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
fi

# --- 5. Docker waits for the SSD mount ---
#
# Docker's boot dependency is on the SSD ONLY, not NFS - this stack's
# primary storage. Unlike the NFS mount above (soft Wants= on its wired-NIC
# route, tolerating a degraded fallback), this is a hard Requires=: starting
# the stack with the SSD missing risks Sonarr/Radarr/Jellyfin concluding
# media was deleted and acting on it. RequiresMountsFor= auto-generates the
# correct Requires=/After= on the SSD's mount unit regardless of filesystem
# type, rather than chasing local-fs.target/remote-fs.target membership by
# hand. If a prior run of this script (or a manual install predating the
# SSD migration) left the old NFS-based drop-in in place, remove it first -
# two differently-named drop-ins under docker.service.d/ can coexist, which
# would leave the old NFS dependency active alongside this one.

echo "[5/11] Configuring Docker to wait for the SSD mount..."
mkdir -p /etc/systemd/system/docker.service.d
rm -f /etc/systemd/system/docker.service.d/wait-for-nfs.conf
cat > /etc/systemd/system/docker.service.d/wait-for-ssd.conf << EOF
[Unit]
RequiresMountsFor=$SSD_MOUNT_POINT
EOF
systemctl daemon-reload

# --- 6. Network watchdog ---

echo "[6/11] Installing network watchdog..."
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

# --- 7. UFW firewall ---

LAN_SUBNET="${LAN_SUBNET:-192.168.1.0/24}"

echo "[7/11] Configuring UFW firewall..."
ufw --force enable
ufw default deny incoming
ufw allow from "$LAN_SUBNET" to any port 22 proto tcp comment "SSH (LAN only)"
ufw allow 443/tcp comment "Caddy HTTPS"
ufw allow 51413/tcp comment "Transmission peer port"
ufw allow 51413/udp comment "Transmission peer port (uTP/DHT)"
ufw allow from "$LAN_SUBNET" to any port 53 comment "DNS (dnsmasq for LAN)"
ufw deny 3389/tcp comment "Block RDP"
echo "  UFW rules configured"

# --- 8. PAM SSH agent auth (passwordless sudo for key-based SSH) ---

echo "[8/11] Setting up PAM SSH agent auth..."
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

# --- 9. SSH server config ---

echo "[9/11] Configuring SSH server..."
if ! grep -q '^AllowAgentForwarding yes' /etc/ssh/sshd_config; then
    echo 'AllowAgentForwarding yes' >> /etc/ssh/sshd_config
fi
if grep -q '^X11Forwarding yes' /etc/ssh/sshd_config; then
    sed -i 's/^X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config
elif ! grep -q '^X11Forwarding no' /etc/ssh/sshd_config; then
    echo 'X11Forwarding no' >> /etc/ssh/sshd_config
fi
systemctl reload ssh

# --- 10. fail2ban ---

echo "[10/11] Setting up fail2ban..."
apt-get install -y -qq fail2ban
cat > /etc/fail2ban/jail.d/sshd.local << EOF
[sshd]
enabled = true
EOF
systemctl enable --now fail2ban
systemctl reload fail2ban

# --- 11. Git safe directory ---

echo "[11/11] Setting git safe directory..."
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
