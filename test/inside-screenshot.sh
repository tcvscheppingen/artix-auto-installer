#!/usr/bin/env bash
# Runs inside the artix-live-sim container after darbs-boot: copies the dwm
# screenshot that boot-checks.sh saved off the disk, for the report.
set -Eeuo pipefail
# shellcheck source=/dev/null
source /src/test/test.conf
# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
M=/mnt

open_disk
trap close_disk EXIT
if [[ -s $M/var/tmp/darbs-screenshot.png ]]; then
    cp $M/var/tmp/darbs-screenshot.png /logs/darbs-screenshot.png
    echo "Screenshot: test/out/darbs-screenshot.png"
else
    echo "No screenshot on the disk" >&2
fi
