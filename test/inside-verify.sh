#!/usr/bin/env bash
# Runs inside the artix-live-sim container: opens the installed disk and
# checks the result. Also adds a serial getty (test only) for the boot test.
set -Eeuo pipefail
# shellcheck source=/dev/null
source /src/test/test.conf
# shellcheck source-path=SCRIPTDIR source=disk.sh
source /src/test/disk.sh
M=/mnt

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
check "ufw ENABLED=yes"                        grep -q '^ENABLED=yes' $M/etc/ufw/ufw.conf
check "ufw default deny incoming"              grep -q '^DEFAULT_INPUT_POLICY="DROP"' $M/etc/default/ufw
check "yay installed"                          chroot $M pacman -Q yay
check "go removed after yay build"             sh -c "! chroot $M pacman -Q go"
check "no systemd installed"                   sh -c "! chroot $M pacman -Q systemd"
check "no GTK installed"                       sh -c "! chroot $M pacman -Q gtk3"
check "mesa not installed explicitly"          sh -c "! chroot $M pacman -Qeq mesa"
check "nvidia-open-dkms installed"             chroot $M pacman -Q nvidia-open-dkms nvidia-utils
check "nvidia module built for linux"          sh -c "find $M/usr/lib/modules/*-artix*/ -name 'nvidia.ko*' | grep -q ."
check "nvidia module built for linux-lts"      sh -c "find $M/usr/lib/modules/*-lts/ -name 'nvidia.ko*' | grep -q ."
check "no kms hook (keeps nouveau out)"        sh -c "! grep -E '^HOOKS=.* kms ' $M/etc/mkinitcpio.conf"
check "older HDA driver instead of SOF"        grep -qx 'options snd-intel-dspcfg dsp_driver=1' $M/etc/modprobe.d/legacy-hda.conf
check "nouveau not in initramfs"               sh -c "! chroot $M lsinitcpio /boot/initramfs-linux.img | grep -q nouveau"
check "summary saved in the user's home"       test -s "$M/home/$USER_NAME/artix-install-summary.md"
check "summary belongs to the user"            sh -c "chroot $M stat -c %U /home/$USER_NAME/artix-install-summary.md | grep -qx $USER_NAME"
check "summary explains the sound switch"      grep -q 'sound-fix sof' "$M/home/$USER_NAME/artix-install-summary.md"
check "install log written"                    test -s $M/var/log/artix-install/install.log
check "install log has no LUKS passphrase"     sh -c "! grep -qF '$LUKS_PASSWORD' $M/var/log/artix-install/install.log"
check "install log has no user password"       sh -c "! grep -qF '$USER_PASSWORD' $M/var/log/artix-install/install.log"

echo "== Result: $pass passed, $fail failed"
} 2>&1 | tee /logs/verify.log

# Test only: a login on the serial port, and the boot check script
cat > $M/etc/dinit.d/getty@ttyS0 << 'GETTY'
@include /usr/lib/dinit.d/getty
inittab-line = ttyS0
GETTY
ln -sfn /etc/dinit.d/getty@ttyS0 $M/etc/dinit.d/boot.d/getty@ttyS0
install -m 755 /src/test/boot-checks.sh $M/usr/local/bin/boot-checks.sh

grep -q 'failed$' /logs/verify.log && ! grep -q ' 0 failed$' /logs/verify.log && exit 1
exit 0
