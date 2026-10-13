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
