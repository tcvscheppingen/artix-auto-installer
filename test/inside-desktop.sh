#!/usr/bin/env bash
# Runs inside the artix-live-sim container: puts the base system that
# inside-install.sh saved without a desktop back on the test disk, and runs
# only the installer's desktop step on it. Much faster than a full install
# for every desktop; run-container-test.sh --full tests the whole way.
set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
prepare_dev
umount -R /mnt 2> /dev/null || true
release_test_disk

[[ -s /out/base.img ]] || { echo "No base system in /out/base.img" >&2; exit 1; }
cp --sparse=always /out/base.img /out/disk.img
echo "$DESKTOP" > /out/desktop.txt
echo "$DESKTOP" > /logs/desktop.txt
cp /out/base.nvidia /out/nvidia.txt 2> /dev/null || true

M=/mnt
# open_disk needs LUKS_PASSWORD
# shellcheck source=/dev/null
source /src/test/test.conf
open_disk
write_test_conf "$LOOP"
# shellcheck source=/dev/null
source /tmp/test.conf
# Only the functions, see the end of their part of the script
# shellcheck source-path=SCRIPTDIR source=../artix-install.sh
source /src/artix-install.sh
# What the installer sets up before its desktop step
ENABLED_SERVICES=()
NVIDIA_ID=${NVIDIA_ID-}
detect_gpus
mkdir -p "$M/var/cache/pacman/pkg"
mount --bind /pkgcache "$M/var/cache/pacman/pkg"
trap 'rice_cleanup; stop_chroot_processes; close_disk' EXIT

desktop_step() {
    step "Installing $(desktop_label "$DESKTOP") on the saved base system"
    case $DESKTOP in
        plasma|cinnamon|xfce|lxqt) install_desktop_environment ;;
        sway|dwm)                  install_rice ;;
        *)                         die "Not a desktop: $DESKTOP" ;;
    esac
}
start=$(date +%s)
rc=0
desktop_step < /dev/null 2>&1 | tee /logs/install.log || rc=$?
echo "Installer exit code: $rc, took $(( $(date +%s) - start ))s" | tee -a /logs/install.log
exit "$rc"
