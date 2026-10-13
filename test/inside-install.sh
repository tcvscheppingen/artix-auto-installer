#!/usr/bin/env bash
# Runs inside the artix-live-sim container: runs the installer on a loop device.
set -Eeuo pipefail

# The live ISO's /dev is a devtmpfs managed by udev; Docker gives a tmpfs.
# Use the kernel's devtmpfs so device nodes (partitions, /dev/mapper/...)
# exist, also inside artix-chroot (which mounts devtmpfs itself).
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm

# Device mappings and loop devices belong to the Docker VM's kernel, so
# remove leftovers from an earlier, aborted test run.
umount -R /mnt 2> /dev/null || true
dmsetup remove_all 2> /dev/null || true
losetup -D

IMG=/out/disk.img
rm -f "$IMG"
truncate -s 24G "$IMG"            # sparse; similar to a small NVMe drive
LOOP=$(losetup -fP --show "$IMG")
trap 'losetup -d "$LOOP"' EXIT
echo "Test disk: $LOOP"

sed "s|__LOOP__|$LOOP|" /src/test/test.conf > /tmp/test.conf
start=$(date +%s)
bash /src/artix-install.sh --config /tmp/test.conf < /dev/null 2>&1 | tee /logs/install.log
rc=${PIPESTATUS[0]}
echo "Installer exit code: $rc, took $(( $(date +%s) - start ))s" | tee -a /logs/install.log
exit "$rc"
