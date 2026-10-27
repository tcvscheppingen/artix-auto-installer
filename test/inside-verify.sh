#!/usr/bin/env bash
# Runs inside the artix-live-sim container: opens the installed disk and
# checks the result. Also adds a serial getty (test only) for the boot test.
set -Eeuo pipefail
# shellcheck source=/dev/null
source /src/test/test.conf
# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
M=/mnt
H=$M/home/$USER_NAME
# The desktop that inside-install.sh installed, and whether with NVIDIA's
# driver (no when the run includes sway, see run-container-test.sh)
DESKTOP=$(cat /out/desktop.txt 2> /dev/null || echo none)
NVIDIA=$(cat /out/nvidia.txt 2> /dev/null || echo yes)

open_disk
trap close_disk EXIT

pass=0 fail=0
check() {
    local name=$1; shift
    if "$@" > /dev/null 2>&1; then echo "PASS  $name"; pass=$((pass + 1))
    else echo "FAIL  $name"; fail=$((fail + 1)); fi
}

{
echo "== Disk layout"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP"
check "GPT with ESP (type EF00) as partition 1" sh -c "sfdisk -d $LOOP | grep -q 'p1.*C12A7328-F81F-11D2-BA4B-00A0C93EC93B'"
check "partition 2 is LUKS2"                   sh -c "cryptsetup luksDump ${LOOP}p2 | grep -q 'Version:.*2'"
check "ESP is FAT32"                           sh -c "blkid -s TYPE -o value ${LOOP}p1 | grep -qx vfat"
check "root is ext4"                           sh -c "blkid -s TYPE -o value /dev/mapper/$MAP | grep -qx ext4"

echo "== Boot chain"
LUUID=$(cryptsetup luksUUID "${LOOP}p2")
check "fstab mounts / by UUID"                 grep -qE '^UUID=\S+\s+/\s+ext4' $M/etc/fstab
check "fstab mounts /boot"                     grep -qE '^UUID=\S+\s+/boot\s+vfat' $M/etc/fstab
check "fstab has swapfile"                     grep -q '^/swapfile' $M/etc/fstab
check "fstab has no other swap"                sh -c "[ \$(grep -v '^#' $M/etc/fstab | grep -c swap) -eq 1 ]"
check "mkinitcpio HOOKS: keyboard keymap before encrypt before filesystems" \
      grep -qE '^HOOKS=\(.*keyboard keymap .*block encrypt filesystems' $M/etc/mkinitcpio.conf
check "initramfs contains encrypt hook"        sh -c "chroot $M lsinitcpio /boot/initramfs-linux.img | grep -q 'hooks/encrypt'"
check "initramfs contains dm_crypt"            sh -c "chroot $M lsinitcpio /boot/initramfs-linux.img | grep -q 'dm-crypt'"
check "initramfs contains nvme driver"         sh -c "chroot $M lsinitcpio /boot/initramfs-linux.img | grep -q 'nvme'"
check "initramfs contains keymap"              sh -c "chroot $M lsinitcpio /boot/initramfs-linux.img | grep -q 'keymap.bin'"
check "LTS initramfs exists"                   test -f $M/boot/initramfs-linux-lts.img
check "microcode present"                      sh -c "ls $M/boot/*-ucode.img"
check "GRUB EFI binary (artix)"                test -f $M/boot/EFI/artix/grubx64.efi
check "GRUB fallback BOOTX64.EFI"              test -f $M/boot/EFI/BOOT/BOOTX64.EFI
check "grub.cfg has cryptdevice=UUID=$LUUID"   grep -q "cryptdevice=UUID=$LUUID:$CRYPT_NAME root=/dev/mapper/$CRYPT_NAME" $M/boot/grub/grub.cfg
check "first GRUB entry boots the main kernel" sh -c "grep -m1 -E '^\s*linux\s' $M/boot/grub/grub.cfg | grep -q 'vmlinuz-linux '"
check "grub.cfg has linux-lts entry"           grep -q 'vmlinuz-linux-lts' $M/boot/grub/grub.cfg
check "GRUB: no submenu, no BootNext entries"  sh -c "! grep -q '^submenu' $M/boot/grub/grub.cfg && grep -qx 'GRUB_DISABLE_BOOTNEXT=true' $M/etc/default/grub"
check "GRUB: two kernels and UEFI settings"    sh -c "[ \$(grep -cE '^\s*menuentry ' $M/boot/grub/grub.cfg) -eq 3 ]"

echo "== Configuration"
check "hostname"                               grep -qx "$HOST_NAME" $M/etc/hostname
check "locale.conf"                            grep -qx "LANG=$LOCALE" $M/etc/locale.conf
check "locale generated"                       sh -c "chroot $M locale -a | grep -qi 'en_US.utf8'"
check "vconsole keymap"                        grep -qx "KEYMAP=$KEYMAP" $M/etc/vconsole.conf
check "X keyboard: us international"           sh -c "grep -q 'XkbLayout\" \"us\"' $M/etc/X11/xorg.conf.d/00-keyboard.conf && grep -q 'XkbVariant\" \"intl\"' $M/etc/X11/xorg.conf.d/00-keyboard.conf"
check "timezone"                               sh -c "readlink $M/etc/localtime | grep -q '$TIMEZONE'"
check "user exists in wheel"                   sh -c "chroot $M id -nG $USER_NAME | grep -qw wheel"
check "user password is set (hash)"            sh -c "grep '^$USER_NAME:' $M/etc/shadow | cut -d: -f2 | grep -q '^\\\$'"
check "root is locked"                         sh -c "grep '^root:' $M/etc/shadow | cut -d: -f2 | grep -q '^!'"
check "sudoers wheel rule + valid syntax"      sh -c "grep -q '^%wheel ALL=(ALL:ALL) ALL' $M/etc/sudoers.d/10-wheel && chroot $M visudo -cq"
check "keyring initialised in target"          test -s $M/etc/pacman.d/gnupg/pubring.gpg
check "artix keys populated"                   sh -c "chroot $M pacman-key --list-keys 2>/dev/null | grep -qi artix"
check "mirrorlist has active servers"          grep -q '^Server' $M/etc/pacman.d/mirrorlist
check "mirrorlist is ranked, stock list kept"  sh -c "grep -q rankmirrors $M/etc/pacman.d/mirrorlist && test -s $M/etc/pacman.d/mirrorlist.stock"

echo "== Services and packages"
for s in NetworkManager ufw; do
    check "service $s enabled"                 test -L $M/etc/dinit.d/boot.d/$s
done
check "time sync service enabled"              sh -c "ls $M/etc/dinit.d/boot.d/ | grep -q chrony"
check "pacdiff installed (pacman-contrib)"     chroot $M pacman -Q pacman-contrib
# ufw-dinit runs ufw enable at boot and ufw disable at shutdown, which
# writes ENABLED=no; so ENABLED=yes only until the first boot (its log)
check "ufw service enables ufw at boot"        grep -qE '^command\s*=\s*/usr/bin/ufw enable' $M/etc/dinit.d/ufw
if [[ ! -e $M/var/log/dinit/ufw.log ]]; then
    check "ufw ENABLED=yes"                    grep -q '^ENABLED=yes' $M/etc/ufw/ufw.conf
fi
check "ufw default deny incoming"              grep -q '^DEFAULT_INPUT_POLICY="DROP"' $M/etc/default/ufw
if [[ $ENABLE_TIMESHIFT == yes ]]; then
    check "timeshift installed"                chroot $M pacman -Q timeshift
    check "service cronie enabled"             test -L $M/etc/dinit.d/boot.d/cronie
    TS=$M/etc/timeshift/timeshift.json
    ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/$MAP)
    check "timeshift snapshots the root fs"    grep -q "\"backup_device_uuid\" : \"$ROOT_UUID\"" $TS
    check "timeshift: daily, no setup wizard"  sh -c "grep -q '\"schedule_daily\" : \"true\"' $TS && grep -q '\"do_first_run\" : \"false\"' $TS"
    check "timeshift excludes every home folder" grep -qF '"/home/**"' $TS
    check "timeshift excludes pacman's lock"   grep -qF '"/var/lib/pacman/db.lck"' $TS
    check "timeshift hourly cron job"          grep -q 'root timeshift --check --scripted' $M/etc/cron.d/timeshift-hourly
    check "pacman hook snapshots before upgrades" grep -qx 'When = PreTransaction' $M/etc/pacman.d/hooks/00-timeshift.hook
    # timeshift never removes a snapshot with a comment
    check "pacman hook snapshots get removed"  sh -c "grep -q -- '--tags D' $M/etc/pacman.d/hooks/00-timeshift.hook && ! grep -q -- '--comments' $M/etc/pacman.d/hooks/00-timeshift.hook"
    check "summary explains restoring a snapshot" grep -q -- "--restore --snapshot '.*' --skip-grub" "$M/home/$USER_NAME/artix-install-summary.md"
else
    check "no timeshift (not enabled)"         sh -c "! chroot $M pacman -Q timeshift"
fi
if [[ $ENABLE_AUR == yes ]]; then
    check "yay installed"                      chroot $M pacman -Q yay
    check "go removed after yay build"         sh -c "! chroot $M pacman -Q go"
else
    check "no yay (AUR not enabled)"           sh -c "! chroot $M pacman -Q yay"
fi
# By name: pacman -Q also matches what a package provides, and Artix's
# artix-archlinux-support provides a dummy systemd (Cinnamon pulls it in)
check "no systemd installed"                   sh -c "! chroot $M pacman -Qq | grep -qxE 'systemd|systemd-libs'"
check "mesa not installed explicitly"          sh -c "! chroot $M pacman -Qeq mesa"
if [[ $NVIDIA == no ]]; then
    check "no NVIDIA driver (none in this run)" sh -c "! chroot $M pacman -Q nvidia-open-dkms"
elif [[ $DESKTOP == sway ]]; then
    # sway doesn't support NVIDIA's driver, so the installer leaves it out
    check "no NVIDIA driver with sway"         sh -c "! chroot $M pacman -Q nvidia-open-dkms"
    check "installer warned about sway + NVIDIA" grep -q "sway doesn't support NVIDIA's driver" /logs/install.log
else
    check "nvidia-open-dkms installed"         chroot $M pacman -Q nvidia-open-dkms nvidia-utils
    check "nvidia module built for linux"      sh -c "find $M/usr/lib/modules/*-artix*/ -name 'nvidia.ko*' | grep -q ."
    check "nvidia module built for linux-lts"  sh -c "find $M/usr/lib/modules/*-lts/ -name 'nvidia.ko*' | grep -q ."
    check "no kms hook (keeps nouveau out)"    sh -c "! grep -E '^HOOKS=.* kms ' $M/etc/mkinitcpio.conf"
    check "nouveau not in initramfs"           sh -c "! chroot $M lsinitcpio /boot/initramfs-linux.img | grep -q nouveau"
    # Suspend relies on it; the installer adds no hook of its own
    check "nvidia-utils' elogind sleep hook"   test -x $M/usr/lib/elogind/system-sleep/nvidia
fi
check "older HDA driver instead of SOF"        grep -qx 'options snd-intel-dspcfg dsp_driver=1' $M/etc/modprobe.d/legacy-hda.conf
check "summary saved in the user's home"       test -s "$M/home/$USER_NAME/artix-install-summary.md"
check "summary belongs to the user"            sh -c "chroot $M stat -c %U /home/$USER_NAME/artix-install-summary.md | grep -qx $USER_NAME"
check "summary explains the sound switch"      grep -q 'sound-fix sof' "$M/home/$USER_NAME/artix-install-summary.md"
check "install log written"                    test -s $M/var/log/artix-install/install.log
check "install log has no LUKS passphrase"     sh -c "! grep -qF '$LUKS_PASSWORD' $M/var/log/artix-install/install.log"
check "install log has no user password"       sh -c "! grep -qF '$USER_PASSWORD' $M/var/log/artix-install/install.log"

echo "== Desktop: $DESKTOP"
check "no rice sudoers rule left"              test ! -e $M/etc/sudoers.d/99-artix-install
check "no DisableSandbox left in pacman.conf"  sh -c "! grep -q '^DisableSandbox' $M/etc/pacman.conf"
if [[ $DESKTOP == none && $ENABLE_TIMESHIFT == no ]]; then
    check "no GTK installed"                   sh -c "! chroot $M pacman -Q gtk3"
    check "no display manager enabled"         sh -c "! ls $M/etc/dinit.d/boot.d/ | grep -qE '^(sddm|lightdm)$'"
else
    case $DESKTOP in plasma) dm=sddm ;; *) dm=lightdm ;; esac
    check "Xorg and LibreWolf installed"       chroot $M pacman -Q xorg-server librewolf
    for svc in dbus turnstiled bluetoothd $dm; do
        check "system service $svc enabled"    test -L "$M/etc/dinit.d/boot.d/$svc"
    done
    for svc in pipewire pipewire-pulse wireplumber; do
        check "user service $svc enabled"      test -L "$H/.config/dinit.d/boot.d/$svc"
    done
    check "home files owned by $USER_NAME"     sh -c "[ -z \"\$(find $H ! -uid \$(chroot $M id -u $USER_NAME) | head -1)\" ]"
fi
case $DESKTOP in
    plasma)
        check "Plasma installed"               chroot $M pacman -Q plasma-meta plasma-workspace konsole dolphin sddm-dinit
        check "SDDM uses the Breeze theme"     grep -qx 'Current=breeze' $M/etc/sddm.conf.d/10-theme.conf
        check "Plasma session file"            test -f $M/usr/share/wayland-sessions/plasma.desktop ;;
    cinnamon|xfce|lxqt)
        session=$DESKTOP
        case $DESKTOP in xfce) pkg=xfce4-session ;; lxqt) pkg=lxqt-session ;; *) pkg=cinnamon ;; esac
        check "$DESKTOP installed"             chroot $M pacman -Q "$pkg" lightdm-gtk-greeter lightdm-dinit
        check "LightDM starts the $session session" grep -qx "user-session=$session" $M/etc/lightdm/lightdm.conf.d/50-artix-install.conf
        check "$session session file"          test -f "$M/usr/share/xsessions/$session.desktop" ;;
    dwm)
        check "no dinit services missing"      sh -c "! grep -q 'services were not found' /logs/install.log"
        for prog in dwm st dmenu slock dwmblocks; do
            check "$prog built and installed"  test -x $M/usr/local/bin/$prog
        done
        check "dwm runs"                       sh -c "chroot $M /usr/local/bin/dwm -v 2>&1 | grep -q '^dwm-'"
        check "st runs"                        sh -c "chroot $M /usr/local/bin/st -v 2>&1 | grep -qE 'st [0-9]'"
        check "desktop packages installed"     chroot $M pacman -Q xorg-server xorg-xinit pipewire wireplumber dunst librewolf turnstile
        check "xss-lock installed from [extra]" chroot $M pacman -Q xss-lock
        check "[extra] enabled"                grep -q '^\[extra\]' $M/etc/pacman.conf
        check "Arch keys populated"            sh -c "chroot $M pacman-key --list-keys 2>/dev/null | grep -qi archlinux"
        for svc in dbus turnstiled bluetoothd NetworkManager lightdm; do
            check "system service $svc enabled" test -L $M/etc/dinit.d/boot.d/$svc
        done
        for svc in pipewire pipewire-pulse wireplumber; do
            check "user service $svc enabled"  test -L "$H/.config/dinit.d/boot.d/$svc"
        done
        check "$USER_NAME in group video"      sh -c "chroot $M id -nG $USER_NAME | grep -qw video"
        check "dotfiles copied"                test -d "$H/.config/x11" -a -d "$H/.local/bin"
        check "wallpaper linked"               test -L "$H/.local/share/bg"
        check "dwm session for LightDM"        sh -c "grep -q '^Exec=/usr/local/bin/dwm-session' $M/usr/share/xsessions/dwm.desktop && test -x $M/usr/local/bin/dwm-session"
        check "LightDM starts dwm by default"  grep -qx 'user-session=dwm' $M/etc/lightdm/lightdm.conf.d/50-darbs.conf
        check "minimal greeter, DARBS wallpaper" sh -c "grep -q '^background = /usr/share/backgrounds/darbs/wallpaper.jpg' $M/etc/lightdm/lightdm-gtk-greeter.conf && test -s $M/usr/share/backgrounds/darbs/wallpaper.jpg"
        check "no TTY autostart (dm chosen)"   sh -c "! grep -qs 'exec startx' $H/.bash_profile"
        check "home files owned by $USER_NAME" sh -c "[ -z \"\$(find $H ! -uid \$(chroot $M id -u $USER_NAME) | head -1)\" ]" ;;
    sway)
        check "no dinit services missing"      sh -c "! grep -q 'services were not found' /logs/install.log"
        check "sway and its tools installed"   chroot $M pacman -Q sway swaybg swaylock swayidle foot waybar mako grim pipewire wireplumber librewolf turnstile
        check "wmenu installed from [extra]"   chroot $M pacman -Q wmenu
        check "[extra] enabled"                grep -q '^\[extra\]' $M/etc/pacman.conf
        for svc in dbus turnstiled bluetoothd NetworkManager lightdm; do
            check "system service $svc enabled" test -L $M/etc/dinit.d/boot.d/$svc
        done
        for svc in pipewire pipewire-pulse wireplumber; do
            check "user service $svc enabled"  test -L "$H/.config/dinit.d/boot.d/$svc"
        done
        check "$USER_NAME in group video"      sh -c "chroot $M id -nG $USER_NAME | grep -qw video"
        check "sway config copied"             test -f "$H/.config/sway/config"
        check "sway session file"              test -f $M/usr/share/wayland-sessions/sway.desktop
        check "LightDM starts sway by default" grep -qx 'user-session=sway' $M/etc/lightdm/lightdm.conf.d/50-sarbs.conf
        check "minimal greeter, SARBS wallpaper" sh -c "grep -q '^background = /usr/share/backgrounds/sarbs/wallpaper.jpg' $M/etc/lightdm/lightdm-gtk-greeter.conf && test -s $M/usr/share/backgrounds/sarbs/wallpaper.jpg"
        check "no TTY autostart (dm chosen)"   sh -c "! grep -qs 'exec sway' $H/.bash_profile"
        check "home files owned by $USER_NAME" sh -c "[ -z \"\$(find $H ! -uid \$(chroot $M id -u $USER_NAME) | head -1)\" ]" ;;
esac

echo "== Result: $pass passed, $fail failed"
} 2>&1 | tee /logs/verify.log

# Test only: a login on the serial port, and the boot check script
cat > $M/etc/dinit.d/getty@ttyS0 << 'GETTY'
@include /usr/lib/dinit.d/getty
inittab-line = ttyS0
GETTY
ln -sfn /etc/dinit.d/getty@ttyS0 $M/etc/dinit.d/boot.d/getty@ttyS0
install -m 755 /src/test/boot-checks.sh $M/usr/local/bin/boot-checks.sh
echo "$DESKTOP" > $M/etc/artix-test-desktop

# Test only: the boot test logs in through the display manager's greeter
# with xdotool, and takes screenshots of the greeter and the desktop with
# maim. No autologin, so the login screen itself is tested.
rm -f $M/etc/sddm.conf.d/90-test-autologin.conf $M/etc/lightdm/lightdm.conf.d/90-test-autologin.conf
if [[ $DESKTOP != none ]]; then
    # artix-chroot: pacman needs /proc, /dev and resolv.conf
    # fastfetch: the dwm and sway screenshots show it in a floating terminal
    extra=(); [[ $DESKTOP == dwm || $DESKTOP == sway ]] && extra=(fastfetch)
    artix-chroot $M pacman -S --needed --noconfirm --disable-sandbox maim xdotool "${extra[@]}" > /dev/null
    artix-chroot $M gpgconf --homedir /etc/pacman.d/gnupg --kill all &> /dev/null || true
fi

grep -q 'failed$' /logs/verify.log && ! grep -q ' 0 failed$' /logs/verify.log && exit 1
exit 0
