#!/system/bin/sh
# pivot_alpine.sh — enter Alpine via pivot_root instead of chroot(2)
#
# Unlike `chroot-distro login`, this leaves the process un-chrooted from the
# kernel's point of view: current_chrooted() returns false, so runc's
# `mount --make-rslave /` (and user-namespace creation) are allowed.
#
# Run from Android host shell (adb/Magisk su), NOT from inside another chroot.

set -e

ROOTFS=/data/local/chroot-distro/alpine
export PATH=/system/xbin:/system/bin:/sbin:/vendor/bin:$PATH

# --- Sanity checks -----------------------------------------------------------

if [ ! -d "$ROOTFS" ]; then
    echo "[!] $ROOTFS does not exist" >&2
    exit 1
fi

# Verify we're not already chrooted
SELF_ROOT=$(stat -c %i /proc/self/root/ 2>/dev/null)
INIT_ROOT=$(stat -c %i /proc/1/root/ 2>/dev/null)
if [ -n "$INIT_ROOT" ] && [ "$SELF_ROOT" != "$INIT_ROOT" ]; then
    echo "[!] Already inside a chroot (self=$SELF_ROOT init=$INIT_ROOT)" >&2
    echo "    Exit to the Android host shell first." >&2
    exit 1
fi

# Required tools
for t in unshare pivot_root mount umount; do
    if ! command -v "$t" >/dev/null 2>&1; then
        echo "[!] '$t' not found in PATH — install sysutils Magisk module" >&2
        exit 1
    fi
done

# --- Detach Android's BPF egress/ingress filters (host namespace) ------------
# These must be stripped BEFORE dockerd creates veths, otherwise forwarded
# packets from container netns hit cgroupskb/egress/stats which drops them
# (unknown UID → no BPF_PERMISSION_INTERNET bit). Also unload xt_qtaguid to
# prevent the null-deref panic on container teardown (4.19 kernels).

echo "[*] Stripping netd BPF cgroup filters..."
if command -v bpftool >/dev/null 2>&1; then
    CGROUP2_MP=$(mount | grep cgroup2 | head -1 | awk '{print $3}')
    if [ -z "$CGROUP2_MP" ]; then
        # Try mounting it ourselves
        CGROUP2_MP=/sys/fs/cgroup
        mount -t cgroup2 none "$CGROUP2_MP" 2>/dev/null || true
        # Re-check
        CGROUP2_MP=$(mount | grep cgroup2 | head -1 | awk '{print $3}')
    fi
    if [ -n "$CGROUP2_MP" ]; then
        for type in egress ingress sock_create; do
            for id in $(bpftool cgroup show "$CGROUP2_MP" 2>/dev/null \
                        | awk -v t="$type" '$2 ~ t {print $1}'); do
                bpftool cgroup detach "$CGROUP2_MP" "$type" id "$id" \
                    && echo "  [+] Detached $type program id $id" \
                    || echo "  [-] Failed to detach $type id $id (non-fatal)"
            done
        done
    else
        echo "  [-] No cgroup2 mount found — skipping BPF detach"
    fi
else
    echo "  [-] bpftool not found — install via 'apk add bpftool' in Alpine"
    echo "      or grab the static binary from your kernel source tree."
    echo "      BPF egress filter will NOT be stripped; container networking may fail."
fi

rmmod xt_qtaguid 2>/dev/null \
    && echo "[+] Unloaded xt_qtaguid (avoids veth teardown panic)" \
    || echo "[-] xt_qtaguid not modular or not loaded (ok)"

# --- Sysctls that must be set in the host namespace --------------------------

echo "[*] Setting host-side sysctls..."
# Load br_netfilter so bridge traffic traverses iptables FORWARD
modprobe br_netfilter 2>/dev/null || true
if [ -d /proc/sys/net/bridge ]; then
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-ip6tables
    echo 0 > /proc/sys/net/bridge/bridge-nf-call-arptables
fi
echo 1 > /proc/sys/net/ipv4/ip_forward
# Disable strict reverse-path filtering — Android defaults to 1, which drops
# reply packets whose source (172.17.0.x) has no route in the incoming iface's
# per-interface table.
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/default/rp_filter

# --- Re-exec inside a new mount namespace ------------------------------------

if [ -z "$PIVOTED_STAGE2" ]; then
    export PIVOTED_STAGE2=1
    exec unshare -m -- "$0" "$@"
fi

# --- Stage 2: we're now in a fresh mount namespace ---------------------------

echo "[*] Entered new mount namespace"

# Make ROOTFS a mount point (pivot_root requires this)
mount --rbind "$ROOTFS" "$ROOTFS"
# Slave propagation so mounts we do below don't escape back to the host
mount --make-rslave "$ROOTFS"

cd "$ROOTFS"

# Ensure required directories exist inside the new root
mkdir -p proc sys dev tmp run put_old

# /proc, /sys, /dev may already be bind-mounted via chroot-distro's android-bind
# feature — our `mount --rbind` above carried those along. Only mount if absent.

if ! mountpoint -q proc 2>/dev/null; then
    mount -t proc proc proc
fi

if ! mountpoint -q sys 2>/dev/null; then
    mount -t sysfs sysfs sys
fi

if ! mountpoint -q dev 2>/dev/null; then
    mount --rbind /dev dev
    mount --make-rslave dev
fi

# tmpfs for /tmp and /run (harmless if already mounted)
mountpoint -q tmp 2>/dev/null || mount -t tmpfs tmpfs tmp
mountpoint -q run 2>/dev/null || mount -t tmpfs tmpfs run

# --- Pivot -------------------------------------------------------------------

pivot_root . put_old

cd /

# We're now in Alpine's filesystem — switch PATH to Alpine binaries
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Drop the old root view
/bin/umount -l /put_old
/bin/rmdir /put_old 2>/dev/null || true

echo "[+] Pivoted into Alpine (now the mount-namespace root)"

# --- Cgroup setup ------------------------------------------------------------
# The host's cgroups are inherited via the rbind; mount them fresh in our view
# if they're not already there.

if ! mountpoint -q /sys/fs/cgroup 2>/dev/null; then
    mount -t tmpfs cgroup /sys/fs/cgroup
    for ctrl in cpuset cpu cpuacct blkio devices freezer pids; do
        mkdir -p /sys/fs/cgroup/$ctrl
        mount -t cgroup -o $ctrl cgroup /sys/fs/cgroup/$ctrl 2>/dev/null || true
    done
fi

# --- Verify no longer chrooted ----------------------------------------------

NEW_SELF=$(stat -c %i /proc/self/root/)
NEW_INIT=$(stat -c %i /proc/1/root/ 2>/dev/null || echo "?")
echo "[*] self_root=$NEW_SELF  init_root=$NEW_INIT"
if [ "$NEW_SELF" = "$NEW_INIT" ] || [ "$NEW_INIT" = "?" ]; then
    echo "[+] current_chrooted() should now be false"
fi

# --- Environment for Alpine --------------------------------------------------

export HOME=/root
export TERM=${TERM:-xterm}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /root 2>/dev/null || cd /

echo "[*] Dropping into shell"
exec /bin/sh -l
