#!/usr/bin/env bash
# Runs inside the artix-live-sim container: runs the installer on a loop device.
set -Eeuo pipefail

# Docker's /dev is a tmpfs; the kernel's devtmpfs gets partition and
# /dev/mapper nodes, like the live ISO
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm

# Loop devices and mappings outlive an aborted run. Only the test's own: on
# a Linux host, the others are the host's.
# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
umount -R /mnt 2> /dev/null || true
release_test_disk

IMG=/out/disk.img
rm -f "$IMG"
truncate -s 24G "$IMG"
LOOP=$(losetup -fP --show "$IMG")
trap 'losetup -d "$LOOP"' EXIT
echo "Test disk: $LOOP"

sed "s|__LOOP__|$LOOP|" /src/test/test.conf > /tmp/test.conf
# The desktop to test, and local DARBS/SARBS checkouts when mounted
{
    echo "DESKTOP=${DESKTOP:-none}"
    if [[ -d /darbs ]]; then echo "DARBS_REPO=/darbs"; fi
    if [[ -d /sarbs ]]; then echo "SARBS_REPO=/sarbs"; fi
    # sway doesn't support NVIDIA's driver; the installer leaves it out
    if [[ ${DESKTOP:-none} == sway ]]; then echo "SWAY_WITHOUT_NVIDIA=yes"; fi
} >> /tmp/test.conf
# For the verify and boot stages, also when they run on their own later
echo "${DESKTOP:-none}" > /out/desktop.txt
echo "${DESKTOP:-none}" > /logs/desktop.txt
echo "Desktop: ${DESKTOP:-none}"
start=$(date +%s)
bash /src/artix-install.sh --config /tmp/test.conf < /dev/null 2>&1 | tee /logs/install.log
rc=${PIPESTATUS[0]}
echo "Installer exit code: $rc, took $(( $(date +%s) - start ))s" | tee -a /logs/install.log
exit "$rc"
