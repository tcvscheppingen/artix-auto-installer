#!/usr/bin/env bash
# Runs inside the artix-live-sim container: runs the installer on a loop device.
set -Eeuo pipefail

# Docker's /dev is a tmpfs; the kernel's devtmpfs gets partition and
# /dev/mapper nodes, like the live ISO
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm

# Loop devices and mappings live in the Docker VM's kernel and survive
# an aborted run
umount -R /mnt 2> /dev/null || true
dmsetup remove_all 2> /dev/null || true
losetup -D

IMG=/out/disk.img
rm -f "$IMG"
truncate -s 24G "$IMG"
LOOP=$(losetup -fP --show "$IMG")
trap 'losetup -d "$LOOP"' EXIT
echo "Test disk: $LOOP"

sed "s|__LOOP__|$LOOP|" /src/test/test.conf > /tmp/test.conf
start=$(date +%s)
bash /src/artix-install.sh --config /tmp/test.conf < /dev/null 2>&1 | tee /logs/install.log
rc=${PIPESTATUS[0]}
echo "Installer exit code: $rc, took $(( $(date +%s) - start ))s" | tee -a /logs/install.log
exit "$rc"
