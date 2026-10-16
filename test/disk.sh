# shellcheck shell=bash
# Sourced by the inside-*.sh scripts, which set M=/mnt: opens the test disk
# on $M and closes it again. LUKS_PASSWORD comes from test.conf.
#
# The container shares the kernel with the host: on a Linux host, all loop
# devices and device-mapper names are the host's too. So this only touches
# the loop devices of /out/disk.img and uses a name of its own.
MAP=artixtest-check

# What an aborted run left behind: the mappings on the loop devices of
# /out/disk.img, then those loop devices
release_test_disk() {
    local loop dev holder
    [[ -e /out/disk.img ]] || return 0
    for loop in $(losetup -l -n -O NAME -j /out/disk.img); do
        dev=${loop##*/}
        for holder in /sys/block/"$dev"/holders/* /sys/block/"$dev"/"$dev"p*/holders/*; do
            [[ -r $holder/dm/name ]] || continue
            dmsetup remove "$(< "$holder/dm/name")" 2> /dev/null || true
        done
        losetup -d "$loop" 2> /dev/null || true
    done
}

open_disk() {
    local n p major minor
    release_test_disk
    LOOP=$(losetup -fP --show /out/disk.img)
    for n in 1 2; do
        p=${LOOP}p$n
        if [[ ! -b $p ]]; then
            IFS=: read -r major minor < "/sys/class/block/$(basename "$p")/dev"
            mknod "$p" b "$major" "$minor"
        fi
    done
    printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file=- "${LOOP}p2" "$MAP"
    mount "/dev/mapper/$MAP" "$M"
    mount "${LOOP}p1" "$M/boot"
}

close_disk() {
    umount -R "$M" 2> /dev/null || true
    cryptsetup close "$MAP" 2> /dev/null || true
    losetup -d "$LOOP" || true
}

# Docker's /dev is a tmpfs; the kernel's devtmpfs gets partition and
# /dev/mapper nodes, like the live ISO
prepare_dev() {
    mount -t devtmpfs devtmpfs /dev
    mkdir -p /dev/pts /dev/shm
    mount -t devpts devpts /dev/pts
    mount -t tmpfs tmpfs /dev/shm
}

# /tmp/test.conf: test.conf for disk $1, with the desktop to test, local
# DARBS/SARBS checkouts when mounted, and the NVIDIA choice of this run
# (TEST_NVIDIA, from run-container-test.sh)
write_test_conf() {
    sed "s|__LOOP__|$1|" /src/test/test.conf > /tmp/test.conf
    {
        echo "DESKTOP=${DESKTOP:-none}"
        if [[ -d /darbs ]]; then echo "DARBS_REPO=/darbs"; fi
        if [[ -d /sarbs ]]; then echo "SARBS_REPO=/sarbs"; fi
        if [[ ${TEST_NVIDIA:-yes} == no ]]; then
            # No pretend NVIDIA GPU: the base system then suits sway too
            echo "NVIDIA_ID="
            echo "INSTALL_NVIDIA=no"
        elif [[ ${DESKTOP:-none} == sway ]]; then
            # sway doesn't support NVIDIA's driver; the installer leaves it out
            echo "SWAY_WITHOUT_NVIDIA=yes"
        fi
    } >> /tmp/test.conf
}
