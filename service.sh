#!/system/bin/sh
# service.sh — Magisk late_start service script
# Mounts docker-storage.img RW with forced SELinux context and shared propagation
# so chroot-distro's rbind carries the RW state into the Alpine chroot.

MODDIR=${0%/*}
IMG=/data/local/chroot-distro/alpine/docker-storage.img
MNT=/data/local/chroot-distro/alpine/var/lib/docker
CTX=u:object_r:system_data_file:s0
LOG=/data/local/tmp/docker-mount.log

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

mkdir -p /data/local/tmp
# Ensure sysutils and standard Android paths are available
export PATH=/system/xbin:/system/bin:/sbin:/vendor/bin:$PATH

log "docker-chroot-selinux service.sh starting"

# Wait for sysutils losetup (Magisk magic_mount may not be done yet)
LOSETUP=""
i=0
while [ $i -lt 30 ]; do
    if [ -x /system/xbin/losetup ]; then
        LOSETUP=/system/xbin/losetup
        break
    elif [ -x /system/bin/losetup ]; then
        LOSETUP=/system/bin/losetup
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ -z "$LOSETUP" ]; then
    log "FATAL: losetup not found at /system/xbin or /system/bin after 30s"
    exit 1
fi
log "losetup found at: $LOSETUP"

# Wait for /data decryption and the image file to appear
i=0
while [ ! -f "$IMG" ] && [ $i -lt 60 ]; do
    sleep 2
    i=$((i + 1))
done

if [ ! -f "$IMG" ]; then
    log "FATAL: $IMG not found after 120s — aborting"
    exit 1
fi

# Idempotency: if image is already attached to a loop AND mounted, skip
EXISTING_LOOP=$("$LOSETUP" -a 2>/dev/null | grep "$IMG" | head -1 | cut -d: -f1)
if [ -n "$EXISTING_LOOP" ] && grep -q " $MNT " /proc/self/mountinfo; then
    log "Already mounted via $EXISTING_LOOP — skipping"
    exit 0
fi

# If loop exists but not mounted, clean it up before re-attaching
if [ -n "$EXISTING_LOOP" ]; then
    log "Stale loop $EXISTING_LOOP found without mount — detaching"
    "$LOSETUP" -d "$EXISTING_LOOP" 2>/dev/null
fi

# Skip if already mounted (defensive)
if mountpoint -q "$MNT" 2>/dev/null; then
    log "$MNT already mounted — skipping"
    exit 0
fi

# Prepare mountpoint
mkdir -p "$MNT"
chmod 0600 "$IMG"
chcon "$CTX" "$IMG"

# Attach loop device (NO -r flag)
LOSETUP_ERR=$("$LOSETUP" -f --show "$IMG" 2>&1)
LOOP=$(echo "$LOSETUP_ERR" | grep -E '^/dev/')
if [ -z "$LOOP" ]; then
    log "FATAL: losetup failed — output: $LOSETUP_ERR"
    exit 1
fi
log "Loop device: $LOOP"

# Verify loop is rw
LOOP_NAME=$(basename "$LOOP")
if [ "$(cat /sys/block/$LOOP_NAME/ro 2>/dev/null)" = "1" ]; then
    log "FATAL: $LOOP is read-only — check file permissions"
    "$LOSETUP" -d "$LOOP"
    exit 1
fi

# Mount with forced context (disables xattr lookup, prevents restorecon)
mount -t ext4 -o rw,noatime,suid,dev,errors=remount-ro,context="$CTX" "$LOOP" "$MNT"
RC=$?
if [ $RC -ne 0 ]; then
    log "FATAL: mount failed (exit $RC)"
    "$LOSETUP" -d "$LOOP"
    exit 1
fi

# Shared propagation so chroot-distro's rbind carries RW
mount --make-shared "$MNT"

# NOTE: chroot self-bind is NOT done here — it shadows the loop mount.
# Instead it's done inside the Alpine chroot on / via start_docker.sh

# Write test
if touch "$MNT/.wtest" && rm "$MNT/.wtest"; then
    log "SUCCESS: $MNT mounted rw via $LOOP, shared propagation set"
else
    log "WARNING: mount succeeded but write test failed"
fi
