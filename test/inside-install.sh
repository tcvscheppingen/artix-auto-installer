#!/usr/bin/env bash
# Runs inside the artix-live-sim container: runs the installer on a loop device.
set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
prepare_dev
# Loop devices and mappings outlive an aborted run. Only the test's own: on
# a Linux host, the others are the host's.
umount -R /mnt 2> /dev/null || true
release_test_disk

IMG=/out/disk.img
rm -f "$IMG"
truncate -s 24G "$IMG"
LOOP=$(losetup -fP --show "$IMG")
trap 'losetup -d "$LOOP"' EXIT
echo "Test disk: $LOOP"

write_test_conf "$LOOP"
# For the verify and boot stages, also when they run on their own later
echo "${DESKTOP:-none}" > /out/desktop.txt
echo "${DESKTOP:-none}" > /logs/desktop.txt
echo "${TEST_NVIDIA:-yes}" > /out/nvidia.txt
echo "Desktop: ${DESKTOP:-none}"
start=$(date +%s)
# pipefail: the installer's exit code (tee doesn't fail)
rc=0
bash /src/artix-install.sh --config /tmp/test.conf < /dev/null 2>&1 | tee /logs/install.log || rc=$?
echo "Installer exit code: $rc, took $(( $(date +%s) - start ))s" | tee -a /logs/install.log
# Without a desktop, this is the base system the desktop tests start from
if [[ $rc == 0 && ${DESKTOP:-none} == none && -n ${BASE_KEY-} ]]; then
    rm -f /out/base.key
    cp --sparse=always "$IMG" /out/base.img
    cp /out/nvidia.txt /out/base.nvidia
    echo "$BASE_KEY" > /out/base.key
    echo "Saved the base system for the desktop tests"
fi
exit "$rc"
