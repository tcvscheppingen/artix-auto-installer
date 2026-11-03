#!/usr/bin/env bash
# Runs the installer on a loop device
set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
prepare_dev
# Leftovers of an aborted run
umount -R /mnt 2> /dev/null || true
release_test_disk

IMG=/out/disk.img
rm -f "$IMG"
truncate -s 24G "$IMG"
LOOP=$(losetup -fP --show "$IMG")
trap 'losetup -d "$LOOP"' EXIT
echo "Test disk: $LOOP"

write_test_conf "$LOOP"
# For the verify and boot stages
echo "${DESKTOP:-none}" > /out/desktop.txt
echo "${DESKTOP:-none}" > /logs/desktop.txt
echo "${TEST_NVIDIA:-yes}" > /out/nvidia.txt
echo "Desktop: ${DESKTOP:-none}"
start=$(date +%s)
# pipefail: the installer's exit code
rc=0
bash /src/artix-install.sh --config /tmp/test.conf < /dev/null 2>&1 | tee /logs/install.log || rc=$?
echo "Installer exit code: $rc, took $(( $(date +%s) - start ))s" | tee -a /logs/install.log
# The base system the desktop tests start from, with and without NVIDIA
if [[ $rc == 0 && ${DESKTOP:-none} == none && -n ${BASE_KEY-} ]]; then
    base=/out/base-nvidia-${TEST_NVIDIA:-yes}
    rm -f "$base.key" /out/base.img /out/base.key /out/base.nvidia   # also the single base of before
    cp --sparse=always "$IMG" "$base.img"
    echo "$BASE_KEY" > "$base.key"
    echo "Saved the base system for the desktop tests ($base.img)"
fi
exit "$rc"
