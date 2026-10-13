#!/usr/bin/env bash
#
# Automated validation of ../artix-install.sh, run on the host (macOS/Linux
# with Docker):
#
#   1. shellcheck
#   2. install: a privileged Artix container (the "live ISO") runs the real
#      installer against a 24 GiB loop device - partitioning, LUKS2,
#      basestrap, chroot setup, GRUB, users, firewall, Timeshift, yay
#   3. verify: opens the encrypted disk again and checks the result
#   4. boot: QEMU (UEFI/OVMF, q35, NVMe, e1000e) boots the disk image,
#      types the LUKS passphrase over the serial console, logs in and runs
#      checks in the booted system (services, firewall, sudo, Timeshift...)
#
# Usage: ./run-container-test.sh [shellcheck|install|verify|boot|all]

set -Eeuo pipefail
cd "$(dirname "$0")"

STAGE=${1:-all}
VOLUME=artix-install-test
mkdir -p out

run_shellcheck() {
    echo "==> shellcheck"
    docker run --rm -v "$PWD/..:/src:ro" koalaman/shellcheck:stable -x \
        /src/artix-install.sh /src/test/run-container-test.sh \
        /src/test/inside-install.sh /src/test/inside-verify.sh /src/test/boot-checks.sh
    echo "shellcheck: clean"
}

build_images() {
    docker build -q --platform linux/amd64 -t artix-live-sim -f Dockerfile.live . > /dev/null
    docker build -q -t artix-qemu -f Dockerfile.qemu . > /dev/null
}

live() {
    # --privileged: loop devices, device mapper (LUKS), mounts, chroot
    docker run --rm --platform linux/amd64 --privileged \
        -v "$VOLUME:/out" -v "$PWD/..:/src:ro" -v "$PWD/out:/logs" \
        artix-live-sim "$@"
}

case $STAGE in
    shellcheck) run_shellcheck ;;
    install)    build_images; live bash /src/test/inside-install.sh ;;
    verify)     build_images; live bash /src/test/inside-verify.sh ;;
    boot)       build_images
                docker run --rm -v "$VOLUME:/out" -v "$PWD:/test:ro" -v "$PWD/out:/logs" \
                    artix-qemu expect /test/boot-test.exp ;;
    all)        run_shellcheck
                "$0" install
                "$0" verify
                "$0" boot ;;
    *)          echo "Unknown stage $STAGE"; exit 1 ;;
esac
