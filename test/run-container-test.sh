#!/usr/bin/env bash
#
# Automated validation of ../artix-install.sh, run on the host (macOS/Linux
# with Docker):
#
#   1. shellcheck
#   2. install: a privileged Artix container (the "live ISO") runs the real
#      installer against a 24 GiB loop device
#   3. verify: opens the encrypted disk again and checks the result
#   4. boot: QEMU (UEFI/OVMF, q35, NVMe, e1000e) boots the disk image,
#      types the LUKS passphrase over the serial console, logs in and runs
#      checks in the booted system
#   5. darbs (optional): installs DARBS on the disk and checks it, then
#      darbs-boot boots it again to check the desktop services and Xorg
#
# The results go to out/test-report.pdf when pandoc and a TeX engine are
# installed, otherwise to out/test-report.md. With DARBS, the report shows
# a screenshot of dwm (out/darbs-screenshot.png).
#
# Usage: ./run-container-test.sh [shellcheck|install|verify|boot|darbs|all] [--darbs]
#   all --darbs   all stages including DARBS
#   darbs         DARBS on the disk of an earlier run
#   DARBS_DIR=~/src/DARBS ./run-container-test.sh all --darbs
#                 test a local DARBS checkout instead of the one on GitHub

set -Eeuo pipefail
cd "$(dirname "$0")"

STAGE=all
WITH_DARBS=no
for arg; do
    case $arg in
        --darbs) WITH_DARBS=yes ;;
        shellcheck|install|verify|boot|darbs|all) STAGE=$arg ;;
        *) echo "Usage: $0 [shellcheck|install|verify|boot|darbs|all] [--darbs]" >&2; exit 1 ;;
    esac
done
case $STAGE in
    all)   STAGES=(shellcheck install verify boot)
           if [[ $WITH_DARBS == yes ]]; then STAGES+=(darbs darbs-boot); fi ;;
    darbs) STAGES=(darbs darbs-boot) ;;
    *)     STAGES=("$STAGE") ;;
esac

VOLUME=artix-install-test
REPORT=out/test-report
DARBS_MOUNT=()
if [[ -n ${DARBS_DIR-} ]]; then
    DARBS_DIR=$(cd "$DARBS_DIR" && pwd)
    DARBS_MOUNT=(-v "$DARBS_DIR:/darbs:ro")
fi
mkdir -p out
rm -f "$REPORT.md" "$REPORT.pdf"

build_images() {
    docker build -q --platform linux/amd64 -t artix-live-sim -f Dockerfile.live . > /dev/null
    docker build -q -t artix-qemu -f Dockerfile.qemu . > /dev/null
}

live() {
    # --privileged: loop devices, device mapper (LUKS), mounts, chroot
    docker run --rm --platform linux/amd64 --privileged \
        -v "$VOLUME:/out" -v "$PWD/..:/src:ro" -v "$PWD/out:/logs" ${DARBS_MOUNT[@]+"${DARBS_MOUNT[@]}"} \
        artix-live-sim "$@"
}

boot_vm() {
    docker run --rm -e "BOOT_LOG=$1" -v "$VOLUME:/out" -v "$PWD:/test:ro" -v "$PWD/out:/logs" \
        artix-qemu expect /test/boot-test.exp
}

run_shellcheck() {
    docker run --rm -v "$PWD/..:/src:ro" koalaman/shellcheck:stable -x \
        /src/artix-install.sh /src/test/run-container-test.sh /src/test/inside-install.sh \
        /src/test/inside-verify.sh /src/test/inside-darbs.sh /src/test/inside-screenshot.sh \
        /src/test/disk.sh /src/test/boot-checks.sh \
        2>&1 | tee out/shellcheck.log
}
run_install()    { build_images; live bash /src/test/inside-install.sh; }
run_verify()     { build_images; live bash /src/test/inside-verify.sh; }
run_boot()       { build_images; boot_vm boot.log; }
run_darbs()      { build_images; rm -f out/darbs-source.log; live bash /src/test/inside-darbs.sh; }
run_darbs_boot() {
    local rc=0
    build_images
    rm -f out/darbs-screenshot.png
    boot_vm boot-darbs.log || rc=$?
    # Also after a failed boot: the screenshot helps to see what went wrong
    live bash /src/test/inside-screenshot.sh || true
    return "$rc"
}

# --- Report ---

# No associative arrays: macOS ships bash 3.2
log_of() {
    case $1 in
        darbs)      echo out/darbs-checks.log ;;
        darbs-boot) echo out/boot-darbs.log ;;
        *)          echo "out/$1.log" ;;
    esac
}
set_result()   { printf -v "RESULT_${1//-/_}" '%s' "$2"; }
result()       { local v="RESULT_${1//-/_}"; echo "${!v-}"; }
set_duration() { printf -v "DURATION_${1//-/_}" '%s' "$2"; }
duration_of()  { local v="DURATION_${1//-/_}"; echo "${!v-}"; }

# Log text without colors, carriage returns and non-ASCII (for LaTeX)
plain() { perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/[^\t\n\x20-\x7e]//g' "$@"; }

duration() {
    [[ -n ${1-} ]] || { echo -; return; }
    printf '%dm %02ds' $(( $1 / 60 )) $(( $1 % 60 ))
}

git_info() {
    local dir=$1 dirty=""
    git -C "$dir" diff --quiet HEAD 2> /dev/null || dirty=", uncommitted changes"
    echo "$(git -C "$dir" rev-parse --short HEAD 2> /dev/null || echo unknown)$dirty"
}

# test.conf value, without quotes
conf() { sed -n "s/^$1=//p" test.conf | tr -d "'\""; }

check_table() {
    echo "| Check | Result |"
    echo "|---|---|"
    plain "$1" | grep -E '^(PASS|FAIL)  ' \
        | sed -E 's/[][\\`*_<>|#]/\\&/g; s/^(PASS|FAIL) +(.*)$/| \2 | \1 |/'
}

write_report() {
    local s log engine=""
    {
        echo "---"
        echo "title: Artix installer test report"
        echo "date: $(date '+%F %R')"
        echo "geometry: margin=2cm"
        echo "---"
        echo
        echo "## Summary"
        echo
        echo "| Stage | Result | Duration |"
        echo "|---|---|---|"
        for s in "${STAGES[@]}"; do
            echo "| $s | $(result "$s") | $(duration "$(duration_of "$s")") |"
        done
        echo
        echo "- Installer: commit $(git_info ..)"
        if [[ " ${STAGES[*]} " == *" darbs "* ]]; then
            if [[ -n ${DARBS_DIR-} ]]; then
                echo "- DARBS: local checkout $DARBS_DIR, commit $(git_info "$DARBS_DIR")"
            else
                echo "- DARBS: GitHub, commit $(sed -n 's/^DARBS commit: //p' out/darbs-source.log 2> /dev/null)"
            fi
        fi
        echo "- Test configuration: CPU $(conf CPU_VENDOR), NVIDIA device $(conf NVIDIA_ID)," \
             "LTS kernel $(conf INSTALL_LTS), AUR $(conf ENABLE_AUR), swap $(conf SWAP_SIZE) GiB"

        if [[ -n $(result install) && -s out/install.log ]]; then
            echo
            echo "## Install"
            echo
            plain out/install.log | grep -E 'Installer exit code|mirrors answered|NVIDIA GPU:|built for every kernel' \
                | sed -E 's/^ +//; s/^/- /'
            plain out/install.log | awk '/Total Installed Size/ && !n++ {sub(/^ */, "- Base system: "); print}'
        fi
        if [[ -n $(result darbs) && -s out/darbs.log ]]; then
            echo
            echo "## DARBS install"
            echo
            plain out/darbs.log | grep -E '^DARBS exit code' | sed 's/^/- /'
        fi
        if [[ -n $(result darbs-boot) && -s out/darbs-screenshot.png ]]; then
            echo
            echo "## DARBS desktop"
            echo
            echo "![dwm after installing DARBS, in the test VM](darbs-screenshot.png){width=100%}"
        fi

        for s in verify boot darbs darbs-boot; do
            log=$(log_of "$s")
            [[ -n $(result "$s") && -s $log ]] || continue
            echo
            echo "## Checks: $s ($(plain "$log" | grep -cE '^PASS  ') passed, $(plain "$log" | grep -cE '^FAIL  ') failed)"
            echo
            check_table "$log"
        done

        for s in "${STAGES[@]}"; do
            [[ $(result "$s") == FAILED ]] || continue
            log=$(log_of "$s")
            [[ $s == darbs ]] && log=out/darbs.log
            echo
            echo "## Failure: $s"
            echo
            echo "Last lines of \`${log#out/}\`:"
            echo
            echo '```'
            # Boot logs end with the shutdown messages; stop before those
            [[ -s $log ]] && plain "$log" | sed '/sudo poweroff/,$d' | tail -n 40
            echo '```'
        done
    } > "$REPORT.md"

    for s in xelatex lualatex pdflatex tectonic; do
        if command -v "$s" > /dev/null; then engine=$s; break; fi
    done
    if command -v pandoc > /dev/null && [[ -n $engine ]]; then
        if pandoc "$REPORT.md" -o "$REPORT.pdf" --pdf-engine="$engine" --resource-path=out 2> out/pandoc.log; then
            rm -f "$REPORT.md" out/pandoc.log
            echo "Report: test/$REPORT.pdf"
            return 0
        fi
        echo "pandoc couldn't make a PDF (see test/out/pandoc.log)"
    fi
    echo "Report: test/$REPORT.md"
}

# --- Run ---

failed=no
for s in "${STAGES[@]}"; do
    if [[ $failed == yes ]]; then
        set_result "$s" skipped
        continue
    fi
    echo "==> $s"
    rm -f "$(log_of "$s")"
    start=$(date +%s)
    # A subshell, so set -e still stops the stage at its first error
    set +e
    ( set -e; "run_${s//-/_}" )
    rc=$?
    set -e
    set_duration "$s" $(( $(date +%s) - start ))
    if (( rc == 0 )); then set_result "$s" passed; else set_result "$s" FAILED; failed=yes; fi
done

echo
# || true: a report with gaps beats none, so no set -e in there
write_report || true
[[ $failed == no ]]
