#!/usr/bin/env bash
# Copies the screenshots boot-checks.sh saved off the test disk
set -Eeuo pipefail
# shellcheck source=/dev/null
source /src/test/test.conf
# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
M=/mnt

open_disk
trap close_disk EXIT
for shot in dm-screenshot desktop-screenshot; do
    if [[ -s $M/var/tmp/$shot.png ]]; then
        cp "$M/var/tmp/$shot.png" "/logs/$shot.png"
        echo "Screenshot: test/out/$shot.png"
    else
        echo "No $shot.png on the disk" >&2
    fi
done
