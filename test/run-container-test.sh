#!/usr/bin/env bash
#
# Automated validation of ../artix-install.sh, run on the host (macOS/Linux
# with Docker):
#
#   1. shellcheck
#   2. packages: every desktop environment's package list still resolves in
#      the Artix repos (cheap, so all of them on every run)
#   3. install: a privileged Artix container (the "live ISO") runs the real
#      installer against a 24 GiB loop device, with the desktop to test
#   4. verify: opens the encrypted disk again and checks the result
#   5. boot: QEMU (UEFI/OVMF, q35, NVMe, e1000e) boots the disk image,
#      types the LUKS passphrase over the serial console, logs in and runs
#      checks in the booted system; with a desktop, it logs in through the
#      display manager's greeter (xdotool) and checks the session
#
# Stages 3-5 run once per desktop. Their logs, screenshots and report go to
# out/<desktop>/ (test-report.pdf with pandoc and a TeX engine, otherwise
# test-report.md); shellcheck and packages log to out/. With --desktop all,
# every desktop is tested in turn and out/test-report.pdf combines them.
# Every stage's result is saved (out/results.txt, out/<desktop>/results.txt),
# so `report` writes the reports again, e.g. after rerunning one desktop.
#
# Usage: ./run-container-test.sh [shellcheck|packages|install|verify|boot|all|report] [--desktop NAME]
#   --desktop NAME   none (default), plasma, cinnamon, xfce, lxqt, sway, dwm or
#                    all: each of them in turn (hours: every one installs again)
#   --darbs          the same as --desktop dwm
#   DARBS_DIR=~/src/DARBS SARBS_DIR=~/src/SARBS ./run-container-test.sh all --desktop sway
#                    test local DARBS/SARBS checkouts instead of the ones on GitHub

set -Eeuo pipefail
cd "$(dirname "$0")"

ALL_DESKTOPS=(none plasma cinnamon xfce lxqt sway dwm)
usage() { echo "Usage: $0 [shellcheck|packages|install|verify|boot|all|report] [--desktop none|plasma|cinnamon|xfce|lxqt|sway|dwm|all]" >&2; exit 1; }
STAGE=all
DESKTOP_ARG=none
while (( $# )); do
    case $1 in
        --darbs)   DESKTOP_ARG=dwm ;;
        --desktop) DESKTOP_ARG=${2-}; shift ;;
        shellcheck|packages|install|verify|boot|all|report) STAGE=$1 ;;
        *) usage ;;
    esac
    shift
done
case $DESKTOP_ARG in
    all) DESKTOPS=("${ALL_DESKTOPS[@]}") ;;
    none|plasma|cinnamon|xfce|lxqt|sway|dwm) DESKTOPS=("$DESKTOP_ARG") ;;
    *) usage ;;
esac
GLOBAL_STAGES=() DESKTOP_STAGES=()
case $STAGE in
    all)                 GLOBAL_STAGES=(shellcheck packages); DESKTOP_STAGES=(install verify boot) ;;
    report)              GLOBAL_STAGES=(shellcheck packages); DESKTOP_STAGES=(install verify boot) ;;
    shellcheck|packages) GLOBAL_STAGES=("$STAGE") ;;
    *)                   DESKTOP_STAGES=("$STAGE") ;;
esac
(( ${#DESKTOP_STAGES[@]} )) || DESKTOPS=()

VOLUME=artix-install-test
RICE_MOUNTS=()
if [[ -n ${DARBS_DIR-} ]]; then
    DARBS_DIR=$(cd "$DARBS_DIR" && pwd)
    RICE_MOUNTS+=(-v "$DARBS_DIR:/darbs:ro")
fi
if [[ -n ${SARBS_DIR-} ]]; then
    SARBS_DIR=$(cd "$SARBS_DIR" && pwd)
    RICE_MOUNTS+=(-v "$SARBS_DIR:/sarbs:ro")
fi
mkdir -p out
if [[ $DESKTOP_ARG == all && $STAGE == all ]]; then rm -f out/test-report.md out/test-report.pdf; fi

# The desktop being tested, and the folder its logs go to (out/ for the
# stages that don't install: shellcheck and packages)
DESKTOP=none
OUT=out

build_images() {
    docker build -q --platform linux/amd64 -t artix-live-sim -f Dockerfile.live . > /dev/null
    docker build -q -t artix-qemu -f Dockerfile.qemu . > /dev/null
}

live() {
    # --privileged: loop devices, device mapper (LUKS), mounts, chroot
    docker run --rm --platform linux/amd64 --privileged \
        -e "DESKTOP=$DESKTOP" -v "$VOLUME:/out" -v "$PWD/..:/src:ro" -v "$PWD/$OUT:/logs" \
        ${RICE_MOUNTS[@]+"${RICE_MOUNTS[@]}"} artix-live-sim "$@"
}

boot_vm() {
    docker run --rm -e "BOOT_LOG=$1" -v "$VOLUME:/out" -v "$PWD:/test:ro" -v "$PWD/$OUT:/logs" \
        artix-qemu expect /test/boot-test.exp
}

# The desktop on the test disk, which inside-install.sh notes there
disk_desktop() {
    docker run --rm --platform linux/amd64 -v "$VOLUME:/out" artix-live-sim cat /out/desktop.txt 2> /dev/null || echo "no disk"
}

# verify and boot on their own use the disk of an earlier install, which
# holds only the desktop installed last
check_disk_desktop() {
    local on_disk
    on_disk=$(disk_desktop)
    [[ $on_disk == "$DESKTOP" ]] && return 0
    echo "The test disk has desktop '$on_disk', not '$DESKTOP'; run the install stage for $DESKTOP first" >&2
    return 1
}

run_shellcheck() {
    docker run --rm -v "$PWD/..:/src:ro" koalaman/shellcheck:stable -x \
        /src/artix-install.sh /src/test/run-container-test.sh /src/test/inside-install.sh \
        /src/test/inside-verify.sh /src/test/inside-screenshot.sh /src/test/inside-packages.sh \
        /src/test/disk.sh /src/test/boot-checks.sh \
        2>&1 | tee out/shellcheck.log
}
run_packages()   { build_images; live bash /src/test/inside-packages.sh; }
run_install()    { build_images; live bash /src/test/inside-install.sh; }
run_verify()     { build_images; check_disk_desktop; live bash /src/test/inside-verify.sh; }
run_boot() {
    local rc=0
    build_images
    check_disk_desktop
    rm -f "$OUT/dm-screenshot.png" "$OUT/desktop-screenshot.png"
    boot_vm boot.log || rc=$?
    # Also after a failed boot: the screenshots help to see what went wrong
    if [[ $DESKTOP != none ]]; then live bash /src/test/inside-screenshot.sh || true; fi
    return "$rc"
}

# --- Results ---

# No associative arrays: macOS ships bash 3.2. Keys: <desktop>_<stage>, and
# global_<stage> for shellcheck and packages.
set_result()   { printf -v "RESULT_$1" '%s' "$2"; }
# Saved results: lines "stage result seconds" in out/results.txt (common
# stages) and out/<desktop>/results.txt. A rerun replaces the stage's line.
results_file() { if [[ $1 == global ]]; then echo out/results.txt; else echo "out/$1/results.txt"; fi; }
save_result() {
    local file
    file=$(results_file "$1")
    mkdir -p "$(dirname "$file")"
    { grep -v "^$2 " "$file" 2> /dev/null || true; echo "$2 $3 $4"; } > "$file.tmp"
    mv "$file.tmp" "$file"
}
load_results() {
    local key=$1 stage res secs
    [[ -r $(results_file "$key") ]] || return 0
    while read -r stage res secs; do
        set_result "${key}_$stage" "$res"
        set_duration "${key}_$stage" "$secs"
    done < "$(results_file "$key")"
}
result()       { local v="RESULT_$1"; echo "${!v-}"; }
set_duration() { printf -v "DURATION_$1" '%s' "$2"; }
duration_of()  { local v="DURATION_$1"; echo "${!v-}"; }

# Runs one stage; returns 1 when it failed
run_stage() {
    local key=$1 stage=$2 rc start
    echo "==> $stage$([[ $key != global ]] && echo " ($DESKTOP)")"
    rm -f "$OUT/$stage.log"
    start=$(date +%s)
    # A subshell, so set -e still stops the stage at its first error
    set +e
    ( set -e; "run_$stage" )
    rc=$?
    set -e
    set_duration "${key}_$stage" $(( $(date +%s) - start ))
    if (( rc == 0 )); then set_result "${key}_$stage" passed; else set_result "${key}_$stage" FAILED; fi
    save_result "$key" "$stage" "$(result "${key}_$stage")" "$(duration_of "${key}_$stage")"
    (( rc == 0 ))
}

# --- Report ---

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

# "12 passed, 0 failed" for a stage log; for the install, which has no
# checks, the installer's exit code and time
check_counts() {
    [[ -s $1 ]] || return 0
    if [[ $1 == */install.log ]]; then
        plain "$1" | sed -nE 's/^Installer exit code: ([0-9]+), took ([0-9]+)s$/exit code \1, \2 s/p' | tail -n 1
        return 0
    fi
    echo "$(plain "$1" | grep -cE '^PASS  ') passed, $(plain "$1" | grep -cE '^FAIL  ') failed"
}

report_header() {
    echo "---"
    echo "title: \"$1\""
    echo "date: $(date '+%F %R')"
    echo "geometry: margin=2cm"
    echo "---"
}

# The shellcheck and packages results, and what was tested
report_common() {
    local h=$1 s
    if (( ${#GLOBAL_STAGES[@]} )); then
        echo
        echo "$h Common stages"
        echo
        echo "| Stage | Result | Duration |"
        echo "|---|---|---|"
        for s in "${GLOBAL_STAGES[@]}"; do
            echo "| $s | $(result "global_$s") | $(duration "$(duration_of "global_$s")") |"
        done
        if [[ -n $(result global_packages) && -s out/packages.log ]]; then
            echo
            plain out/packages.log | grep -E '^(PASS|FAIL)  ' | sed -E 's/^(PASS|FAIL) +/- \1: /'
        fi
    fi
    echo
    echo "- Installer: commit $(git_info ..)"
    echo "- Test configuration: CPU $(conf CPU_VENDOR), NVIDIA device $(conf NVIDIA_ID)," \
         "LTS kernel $(conf INSTALL_LTS), AUR $(conf ENABLE_AUR), swap $(conf SWAP_SIZE) GiB"
}

# One desktop's results. $1: heading level, $2: path to its folder from the
# report (for the screenshots)
report_desktop() {
    local h=$1 dir=$2 d=$DESKTOP s log rice rice_dir
    echo
    echo "$h Stages"
    echo
    echo "| Stage | Result | Duration | Checks / installer |"
    echo "|---|---|---|---|"
    for s in "${DESKTOP_STAGES[@]}"; do
        echo "| $s | $(result "${d}_$s") | $(duration "$(duration_of "${d}_$s")") | $(check_counts "$OUT/$s.log") |"
    done
    echo
    echo "- Desktop: $d$([[ $d == sway || $d == dwm ]] && echo ", login $(conf DESKTOP_LOGIN)")"
    if [[ $d == dwm || $d == sway ]]; then
        rice=DARBS rice_dir=${DARBS_DIR-}
        [[ $d == sway ]] && rice=SARBS rice_dir=${SARBS_DIR-}
        if [[ -n $rice_dir ]]; then
            echo "- $rice: local checkout $rice_dir, commit $(git_info "$rice_dir")"
        else
            echo "- $rice: GitHub, commit $(plain "$OUT/install.log" 2> /dev/null | sed -n "s/^ *$rice commit //p" | head -n 1)"
        fi
    fi
    if [[ -n $(result "${d}_install") && -s $OUT/install.log ]]; then
        plain "$OUT/install.log" | grep -E 'Installer exit code|mirrors answered|NVIDIA GPU:|built for every kernel|Installing .*(screen|login|yourself)' \
            | sed -E 's/^ +//; s/^/- /'
        plain "$OUT/install.log" | awk '/Total Installed Size/ && !n++ {sub(/^ */, "- Base system: "); print}'
    fi
    if [[ -n $(result "${d}_boot") && -s $OUT/dm-screenshot.png ]]; then
        echo
        echo "$h Login screen"
        echo
        echo "![The display manager's greeter for $d, in the test VM]($dir/dm-screenshot.png){width=100%}"
    fi
    if [[ -n $(result "${d}_boot") && -s $OUT/desktop-screenshot.png ]]; then
        echo
        echo "$h Desktop"
        echo
        echo "![$d after logging in through the greeter, in the test VM]($dir/desktop-screenshot.png){width=100%}"
    fi
    for s in verify boot; do
        log=$OUT/$s.log
        [[ -n $(result "${d}_$s") && -s $log ]] || continue
        echo
        echo "$h Checks: $s ($(check_counts "$log"))"
        echo
        check_table "$log"
        if plain "$log" | grep -q '^NOTE  '; then
            echo
            plain "$log" | sed -n 's/^NOTE  /- Note: /p'
        fi
    done
    for s in "${DESKTOP_STAGES[@]}"; do
        [[ $(result "${d}_$s") == FAILED ]] || continue
        log=$OUT/$s.log
        echo
        echo "$h Failure: $s"
        echo
        echo "Last lines of \`${log#out/}\`:"
        echo
        echo '```'
        # Boot logs end with the shutdown messages; stop before those
        [[ -s $log ]] && plain "$log" | sed '/sudo poweroff/,$d' | tail -n 40
        echo '```'
    done
}

# Markdown to PDF next to it, when pandoc and a TeX engine are there.
# $2: the folder the image paths start from.
make_pdf() {
    local md=$1 res=$2 engine="" e
    for e in xelatex lualatex pdflatex tectonic; do
        if command -v "$e" > /dev/null; then engine=$e; break; fi
    done
    if command -v pandoc > /dev/null && [[ -n $engine ]]; then
        if pandoc "$md" -o "${md%.md}.pdf" --pdf-engine="$engine" --resource-path="$res" 2> "${md%.md}-pandoc.log"; then
            rm -f "$md" "${md%.md}-pandoc.log"
            echo "Report: test/${md%.md}.pdf"
            return 0
        fi
        echo "pandoc couldn't make a PDF (see test/${md%.md}-pandoc.log)"
    fi
    echo "Report: test/$md"
}

# The report of one run: out/<desktop>/test-report, or out/test-report
# for the shellcheck and packages stages on their own
write_desktop_report() {
    local md=$OUT/test-report.md
    rm -f "$md" "$OUT/test-report.pdf"
    {
        report_header "Artix installer test report: $DESKTOP"
        report_common "##"
        report_desktop "##" .
    } > "$md"
    make_pdf "$md" "$OUT"
}

write_global_report() {
    local md=out/test-report.md
    rm -f "$md" out/test-report.pdf
    {
        report_header "Artix installer test report"
        report_common "##"
    } > "$md"
    make_pdf "$md" out
}

# All desktops: a table with every desktop, then each one's results
write_combined_report() {
    local md=out/test-report.md d s line
    {
        report_header "Artix installer test report: all desktops"
        echo
        echo "## Summary"
        echo
        line="| Desktop |"; for s in "${DESKTOP_STAGES[@]}"; do line+=" $s |"; done
        echo "$line Duration |"
        line="|---|"; for s in "${DESKTOP_STAGES[@]}"; do line+="---|"; done
        echo "$line---|"
        for d in "${DESKTOPS[@]}"; do
            DESKTOP=$d OUT=out/$d
            local total=0
            line="| $d |"
            for s in "${DESKTOP_STAGES[@]}"; do
                line+=" $(result "${d}_$s")$([[ -n $(check_counts "$OUT/$s.log") ]] && echo " ($(check_counts "$OUT/$s.log"))") |"
                total=$(( total + $(duration_of "${d}_$s" | grep . || echo 0) ))
            done
            echo "$line $(duration "$total") |"
        done
        report_common "##"
        for d in "${DESKTOPS[@]}"; do
            DESKTOP=$d OUT=out/$d
            echo
            printf '%s\n' '\newpage'
            echo
            echo "## Desktop: $d"
            report_desktop "###" "$d"
        done
    } > "$md"
    make_pdf "$md" out
}

# --- Run ---

if [[ $STAGE == report ]]; then
    load_results global
    if [[ $DESKTOP_ARG == all ]]; then
        # Only the desktops that ran
        DESKTOPS=()
        for d in "${ALL_DESKTOPS[@]}"; do [[ -r out/$d/results.txt ]] && DESKTOPS+=("$d"); done
    fi
    for d in ${DESKTOPS[@]+"${DESKTOPS[@]}"}; do
        load_results "$d"
        DESKTOP=$d OUT=out/$d
        write_desktop_report || true
    done
    if (( ${#DESKTOPS[@]} > 1 )); then write_combined_report || true; fi
    exit 0
fi

failed=no
for s in ${GLOBAL_STAGES[@]+"${GLOBAL_STAGES[@]}"}; do
    run_stage global "$s" || failed=yes
done
# With failing common stages a desktop install makes no sense
common_failed=$failed
if [[ $common_failed == yes ]]; then
    for d in ${DESKTOPS[@]+"${DESKTOPS[@]}"}; do
        for s in "${DESKTOP_STAGES[@]}"; do set_result "${d}_$s" skipped; done
    done
fi

for d in ${DESKTOPS[@]+"${DESKTOPS[@]}"}; do
    DESKTOP=$d OUT=out/$d
    mkdir -p "$OUT"
    desktop_failed=$common_failed
    for s in "${DESKTOP_STAGES[@]}"; do
        if [[ $desktop_failed == yes ]]; then
            set_result "${d}_$s" skipped
            continue
        fi
        # A failed desktop doesn't stop the next one
        run_stage "$d" "$s" || { desktop_failed=yes; failed=yes; }
    done
    echo
    # || true: a report with gaps beats none, so no set -e in there
    write_desktop_report || true
done

if (( ${#DESKTOPS[@]} > 1 )); then
    write_combined_report || true
elif (( ${#DESKTOPS[@]} == 0 )); then
    DESKTOP=none OUT=out
    write_global_report || true
fi
[[ $failed == no ]]
