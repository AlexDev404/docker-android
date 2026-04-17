#!/bin/sh
# start_docker.sh — Alpine chroot side
#
# Run this AFTER entering Alpine via pivot_alpine.sh (NOT chroot-distro login).
# pivot_alpine.sh un-chroots us so runc/crun can do `mount --make-rslave /`.
#
# Prerequisites (handled elsewhere):
#   - docker-chroot-selinux Magisk module mounts /var/lib/docker at boot
#   - pivot_alpine.sh pivoted us into Alpine with mount-ns-root status
#   - Docker 24.0.9 static binaries at /usr/local/bin/
#   - crun installed (apk add crun) — used instead of runc because Android's
#     kernel forces cpuset_v2_mode which breaks runc 1.2.x

set -e

# ---------------------------------------------------------------------------
# 0. Sanity: are we un-chrooted? (pivot_alpine.sh should have handled this)
# ---------------------------------------------------------------------------

SELF_ROOT=$(stat -c %i /proc/self/root/ 2>/dev/null)
INIT_ROOT=$(stat -c %i /proc/1/root/ 2>/dev/null)
if [ -n "$INIT_ROOT" ] && [ "$SELF_ROOT" != "$INIT_ROOT" ]; then
    echo "[!] Still appears to be chrooted (self=$SELF_ROOT init=$INIT_ROOT)"
    echo "    Run pivot_alpine.sh from Android host first, not chroot-distro login."
    # Not exiting — might still work for some use cases, just warn
fi

# ---------------------------------------------------------------------------
# 1. Canonical daemon.json
# ---------------------------------------------------------------------------

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
    "storage-driver": "overlay2",
    "data-root": "/var/lib/docker",
    "default-runtime": "crun",
    "runtimes": {
        "crun": {
            "path": "/usr/bin/crun"
        }
    }
}
EOF

# ---------------------------------------------------------------------------
# 2. Kill any stale dockerd + clean up its runtime state
# ---------------------------------------------------------------------------

pkill dockerd 2>/dev/null || true
pkill containerd 2>/dev/null || true
sleep 2

# Clear stale exec-root state (otherwise containerd gets confused on restart)
rm -rf /var/lib/docker/run/containerd 2>/dev/null || true
mkdir -p /var/lib/docker/run

# Clear stale docker sub-cgroups from previous failed runs
for ctrl in cpuset cpu cpuacct blkio devices freezer pids; do
    find /sys/fs/cgroup/$ctrl/ -maxdepth 1 -name 'docker*' -type d \
         -exec rmdir {} \; 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 3. Safety net for /var/lib/docker mount (should be handled by Magisk module)
# ---------------------------------------------------------------------------

if ! mountpoint -q /var/lib/docker 2>/dev/null; then
    echo "[!] /var/lib/docker is NOT a mount point — the Magisk module may not"
    echo "    have run. Docker will still start but storage is not on the loop."
else
    # Remount rw if it slipped to ro
    if mount | grep '/var/lib/docker' | grep -q '\bro\b'; then
        echo "[*] /var/lib/docker was ro — remounting rw"
        mount -o remount,rw /var/lib/docker
    fi
fi

# ---------------------------------------------------------------------------
# 4. Cgroups
# ---------------------------------------------------------------------------

if ! mountpoint -q /sys/fs/cgroup 2>/dev/null; then
    mount -t tmpfs cgroup /sys/fs/cgroup
fi

for ctrl in cpuset cpu cpuacct blkio devices freezer pids; do
    if ! mountpoint -q /sys/fs/cgroup/$ctrl 2>/dev/null; then
        mkdir -p /sys/fs/cgroup/$ctrl
        mount -t cgroup -o $ctrl cgroup /sys/fs/cgroup/$ctrl 2>/dev/null || true
    fi
done

# Note: Android's kernel forces cpuset with noprefix,cpuset_v2_mode globally,
# which breaks runc 1.2.x. We work around this by using crun as the default
# runtime (configured in /etc/docker/daemon.json above).

# ---------------------------------------------------------------------------
# 5. Network setup
# ---------------------------------------------------------------------------

# Ensure ip forwarding is on (Android may reset it)
echo 1 > /proc/sys/net/ipv4/ip_forward

# Make sure iptables points to legacy (Docker 24 doesn't support nft)
if [ -f /usr/sbin/iptables-legacy ]; then
    ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables 2>/dev/null || true
    ln -sf /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save 2>/dev/null || true
    ln -sf /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore 2>/dev/null || true
    ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables 2>/dev/null || true
fi

# Patch the filter chain
# Flush the Android-polluted filter table so Docker can create its chains
iptables -t filter -F
iptables -t nat -F

# ---------------------------------------------------------------------------
# 5.5. Detach Android's BPF cgroup egress/ingress filters
# ---------------------------------------------------------------------------

#echo "[*] Stripping netd BPF cgroup filters..."
#if command -v bpftool >/dev/null 2>&1; then
#    # Find existing cgroup2 mount, or temporarily mount one in a side path
#    # Do NOT mount over /sys/fs/cgroup — that's Docker's cgroup v1 tmpfs
#    CGROUP2_MP=$(mount | grep cgroup2 | head -1 | awk '{print $3}')
#    CGROUP2_TEMP=0
#    if [ -z "$CGROUP2_MP" ]; then
#        CGROUP2_MP=/tmp/.bpf_cgroup2
#        mkdir -p "$CGROUP2_MP"
#        if mount -t cgroup2 none "$CGROUP2_MP" 2>/dev/null; then
#            CGROUP2_TEMP=1
#        else
#            CGROUP2_MP=""
#        fi
#    fi
#    if [ -n "$CGROUP2_MP" ]; then
#        for type in egress ingress sock_create; do
#            for id in $(bpftool cgroup show "$CGROUP2_MP" 2>/dev/null \
#                        | awk -v t="$type" '$2 ~ t {print $1}'); do
#                bpftool cgroup detach "$CGROUP2_MP" "$type" id "$id" \
#                    && echo "  [+] Detached $type program id $id" \
#                    || echo "  [-] Failed to detach $type id $id (non-fatal)"
#            done
#        done
#        # Clean up temp mount so it doesn't interfere with Docker's cgroup v1
#        if [ "$CGROUP2_TEMP" = "1" ]; then
#            umount "$CGROUP2_MP" 2>/dev/null
#            rmdir "$CGROUP2_MP" 2>/dev/null
#        fi
#    else
#        echo "  [-] Could not mount cgroup2 — skipping BPF detach"
#    fi
#else
#    echo "  [-] bpftool not found — install with: apk add bpftool"
#fi

# ---------------------------------------------------------------------------
# 6. Start dockerd
# ---------------------------------------------------------------------------

# --exec-root=/var/lib/docker/run avoids /run being a tmpfs that gets wiped
# and where containerd fails to create task state directories.

echo "[*] Starting dockerd..."
dockerd \
    --exec-opt native.cgroupdriver=cgroupfs \
    --exec-root=/var/lib/docker/run \
    >/var/log/dockerd.log 2>&1 &

DOCKERD_PID=$!
echo "[*] dockerd PID: $DOCKERD_PID (logs: /var/log/dockerd.log)"

# ---------------------------------------------------------------------------
# 7. Wait for socket
# ---------------------------------------------------------------------------

for i in $(seq 1 30); do
    if [ -S /var/run/docker.sock ]; then
        echo "[+] Docker daemon ready after ${i}s"
        docker info 2>/dev/null | grep -E 'Server Version|Storage Driver|Runtimes|Default Runtime|Cgroup' || true

        # -------------------------------------------------------------------
        # 8. Android policy-routing bypass (must run AFTER docker0 exists)
        # -------------------------------------------------------------------
        echo ""
        echo "[*] Applying Android policy-routing fix..."

        # Disable rp_filter on all interfaces docker traffic touches.
        # pivot_alpine.sh sets all/default, but dockerd just created docker0
        # and veth interfaces inherit from default — force them too.
        for iface in all default docker0; do
            echo 0 > /proc/sys/net/ipv4/conf/$iface/rp_filter 2>/dev/null || true
        done
        # Also catch wlan0 if visible in this namespace
        echo 0 > /proc/sys/net/ipv4/conf/wlan0/rp_filter 2>/dev/null || true

        # Shadow Android's netd per-UID/fwmark ip rules (priority 10000-25000)
        # with a catch-all that consults the main table, where docker0's
        # 172.17.0.0/16 route lives. Without this, reply packets to containers
        # hit Android's per-interface wlan0 table which has no route to
        # 172.17.0.0/16 and get dropped as "network unreachable".
        ip rule add to 172.17.0.0/16 lookup main pref 11500 2>/dev/null || true
        ip rule add from 172.17.0.0/16 lookup main pref 11501 2>/dev/null || true

        # Detect upstream gateway for the default route
        GW=$(ip route show table 1021 default 2>/dev/null | awk '/via/{print $3; exit}')
        DEV=$(ip route show table 1021 default 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1); exit}')
	if [ -z "$GW" ]; then
            # Fallback: check main table, or neighbour table
            GW=$(ip route show default 2>/dev/null | awk '/via/{print $3; exit}')
            DEV=$(ip route show default 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1); exit}')
        fi
        if [ -z "$GW" ]; then
            # Last resort: wlan0 neighbour (router)
            GW=$(ip neigh show dev wlan0 2>/dev/null | awk '/REACHABLE|STALE|DELAY/{print $1; exit}')
            DEV=wlan0
        fi
        if [ -n "$GW" ] && [ -n "$DEV" ]; then
            ip route add default via "$GW" dev "$DEV" 2>/dev/null || true
            echo "  [+] Default route: via $GW dev $DEV"
        else
            echo "  [!] Could not detect gateway — container internet will not work"
        fi

        # Flush conntrack so cached "unreachable" entries from earlier failed
        # pings don't poison new connections
        conntrack -F 2>/dev/null || true

        echo "[+] Policy-routing fix applied"
        echo ""

        # Verify with a quick bridge-gateway ping
        if command -v ping >/dev/null 2>&1; then
            if ping -c 1 -W 2 172.17.0.1 >/dev/null 2>&1; then
                echo "[+] Bridge gateway 172.17.0.1 is reachable"
            else
                echo "[!] 172.17.0.1 still unreachable — check 'bpftool cgroup tree' output"
                echo "    (pivot_alpine.sh should have detached BPF filters; verify with"
                echo "     bpftool cgroup show /sys/fs/cgroup)"
            fi
        fi

        echo ""
        echo "[+] Try it: docker run --rm alpine ping -c 3 172.17.0.1"
        echo "           docker run --rm alpine ping -c 3 8.8.8.8"
        exit 0
    fi
    sleep 1
done

echo "[!] Timed out waiting for /var/run/docker.sock after 30s"
echo "[!] Check /var/log/dockerd.log for details"
tail -20 /var/log/dockerd.log 2>/dev/null
exit 1
