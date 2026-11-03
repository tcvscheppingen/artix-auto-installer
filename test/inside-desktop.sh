#!/usr/bin/env bash
# Restores the saved base system and runs only the installer's desktop step
set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
prepare_dev
umount -R /mnt 2> /dev/null || true
release_test_disk

base=/out/base-nvidia-${TEST_NVIDIA:-yes}.img
[[ -s $base ]] || { echo "No base system in $base" >&2; exit 1; }
cp --sparse=always "$base" /out/disk.img
echo "$DESKTOP" > /out/desktop.txt
echo "$DESKTOP" > /logs/desktop.txt
echo "${TEST_NVIDIA:-yes}" > /out/nvidia.txt

M=/mnt
# open_disk needs LUKS_PASSWORD
# shellcheck source=/dev/null
source /src/test/test.conf
open_disk
write_test_conf "$LOOP"
# shellcheck source=/dev/null
source /tmp/test.conf
# Defines the functions only
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
        sway|dwm|penrose)          install_rice ;;
        *)                         die "Not a desktop: $DESKTOP" ;;
    esac
}
# The installer adds the Timeshift hook after the desktop step
hook=$M/etc/pacman.d/hooks/00-timeshift.hook
[[ -e $hook ]] && mv "$hook" "$hook.off"
start=$(date +%s)
rc=0
desktop_step < /dev/null 2>&1 | tee /logs/install.log || rc=$?
[[ -e $hook.off ]] && mv "$hook.off" "$hook"
echo "Installer exit code: $rc, took $(( $(date +%s) - start ))s" | tee -a /logs/install.log
exit "$rc"
