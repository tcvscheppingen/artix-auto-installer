#!/usr/bin/env bash
# Runs inside the artix-live-sim container: installs DARBS on the installed
# disk (in a chroot, as the test user) and checks the result. DARBS comes
# from /darbs when mounted, otherwise from GitHub.
set -Eeuo pipefail
# shellcheck source=/dev/null
source /src/test/test.conf
# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
M=/mnt

H=$M/home/$USER_NAME
# shellcheck disable=SC2329  # used by trap
cleanup() {
    rm -f $M/etc/sudoers.d/99-darbs-test
    sed -i '/^DisableSandbox$/d' $M/etc/pacman.conf 2> /dev/null
    chroot $M gpgconf --homedir /etc/pacman.d/gnupg --kill all 2> /dev/null
    for pid in /proc/[0-9]*; do
        [[ $(readlink "$pid/root" 2> /dev/null) == "$M" ]] && kill "${pid#/proc/}" 2> /dev/null
    done
    sleep 1
    close_disk
}
open_disk
trap cleanup EXIT

# Test only: sudo without a password, and no pacman download sandbox (Docker)
echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > $M/etc/sudoers.d/99-darbs-test
chmod 440 $M/etc/sudoers.d/99-darbs-test
sed -i 's/^\[options\]$/&\nDisableSandbox/' $M/etc/pacman.conf

rm -rf "$H/DARBS"
if [[ -d /darbs ]]; then
    cp -a /darbs "$H/DARBS"
    chroot $M chown -R "$USER_NAME:" "/home/$USER_NAME/DARBS"
    echo "DARBS: local checkout"
else
    artix-chroot $M su - "$USER_NAME" -c 'git clone --depth 1 https://github.com/tcvscheppingen/DARBS ~/DARBS'
    echo "DARBS: cloned from GitHub"
fi
# safe.directory: the repository belongs to the user, git runs as root
echo "DARBS commit: $(chroot $M git -c safe.directory='*' -C "/home/$USER_NAME/DARBS" rev-parse --short HEAD 2> /dev/null || echo unknown)" \
    | tee /logs/darbs-source.log

start=$(date +%s)
rc=0
# Enter answers the remaining prompt (dwm autostart) with its default
artix-chroot $M su - "$USER_NAME" -c 'cd ~/DARBS && ./auto-rice-artix.sh' < <(yes '') 2>&1 \
    | tee /logs/darbs.log || rc=$?
echo "DARBS exit code: $rc, took $(( $(date +%s) - start ))s" | tee -a /logs/darbs.log

# Test only: the boot test logs in on the serial console, which belongs to
# no seat, so elogind gives the user no access to the sound card (on tty1 it
# does). The audio group gives that access without a seat.
chroot $M usermod -aG audio "$USER_NAME"

# The darbs-boot stage runs the current checks, also on a disk from an older run
install -m 755 /src/test/boot-checks.sh $M/usr/local/bin/boot-checks.sh

pass=0 fail=0
check() {
    local name=$1; shift
    if "$@" > /dev/null 2>&1; then echo "PASS  $name"; pass=$((pass + 1))
    else echo "FAIL  $name"; fail=$((fail + 1)); fi
}

{
echo "== DARBS"
check "auto-rice-artix.sh exits 0"             test "$rc" -eq 0
check "no dinit services missing"              sh -c "! grep -q 'services were not found' /logs/darbs.log"
for prog in dwm st dmenu slock dwmblocks; do
    check "$prog built and installed"          test -x $M/usr/local/bin/$prog
done
check "dwm runs"                               sh -c "chroot $M /usr/local/bin/dwm -v 2>&1 | grep -q '^dwm-'"
check "st runs"                                sh -c "chroot $M /usr/local/bin/st -v 2>&1 | grep -qE 'st [0-9]'"
check "desktop packages installed"             chroot $M pacman -Q xorg-server xorg-xinit pipewire wireplumber dunst librewolf turnstile
check "xss-lock installed from [extra]"        chroot $M pacman -Q xss-lock
check "[extra] enabled"                        grep -q '^\[extra\]' $M/etc/pacman.conf
check "Arch keys populated"                    sh -c "chroot $M pacman-key --list-keys 2>/dev/null | grep -qi archlinux"
for svc in dbus turnstiled bluetoothd NetworkManager; do
    check "system service $svc enabled"        test -L $M/etc/dinit.d/boot.d/$svc
done
for svc in pipewire pipewire-pulse wireplumber; do
    check "user service $svc enabled"          test -L "$H/.config/dinit.d/boot.d/$svc"
done
check "$USER_NAME in group video"              sh -c "chroot $M id -nG $USER_NAME | grep -qw video"
check "dotfiles copied"                        test -d "$H/.config/x11" -a -d "$H/.local/bin"
check "wallpaper linked"                       test -L "$H/.local/share/bg"
check "home files owned by $USER_NAME"         sh -c "[ -z \"\$(find $H ! -uid \$(chroot $M id -u $USER_NAME) | head -1)\" ]"
echo "== Result: $pass passed, $fail failed"
} 2>&1 | tee /logs/darbs-checks.log

grep -q ' 0 failed$' /logs/darbs-checks.log
