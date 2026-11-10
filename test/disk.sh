# shellcheck shell=bash
# Sourced by inside-*.sh. On a Linux host loop devices and device-mapper names
# are shared with the host, so only touch the test disk's own.
MAP=artixtest-check

# Leftovers of an aborted run
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

# Docker's /dev is a tmpfs without partition and /dev/mapper nodes
prepare_dev() {
    # Not allowed in a user namespace: rootless Docker, Podman, userns-remap
    if ! mount -t devtmpfs devtmpfs /dev; then
        echo "Can't mount devtmpfs on /dev: the container isn't really privileged." >&2
        echo "The test needs rootful Docker Engine (not rootless, Podman, userns-remap or snap Docker)." >&2
        exit 1
    fi
    mkdir -p /dev/pts /dev/shm
    mount -t devpts devpts /dev/pts
    mount -t tmpfs tmpfs /dev/shm
}

# test.conf for disk $1, plus this run's choices
write_test_conf() {
    sed "s|__LOOP__|$1|" /src/test/test.conf > /tmp/test.conf
    {
        echo "DESKTOP=${DESKTOP:-none}"
        if [[ -d /darbs ]]; then echo "DARBS_REPO=/darbs"; fi
        if [[ -d /sarbs ]]; then echo "SARBS_REPO=/sarbs"; fi
        if [[ -d /parbs ]]; then echo "PARBS_REPO=/parbs"; fi
        if [[ ${TEST_NVIDIA:-yes} == no ]]; then
            # A base system that suits sway too
            echo "NVIDIA_ID="
            echo "INSTALL_NVIDIA=no"
        elif [[ ${DESKTOP:-none} == sway ]]; then
            # sway doesn't support NVIDIA's driver; the installer leaves it out
            echo "SWAY_WITHOUT_NVIDIA=yes"
        fi
    } >> /tmp/test.conf
}
