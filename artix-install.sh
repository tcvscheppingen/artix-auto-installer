#!/usr/bin/env bash
#
# artix-install.sh - automated Artix Linux (dinit) installation
#
# Installs a minimal Artix with dinit that boots to a TTY:
#   * UEFI only, GPT, 1 GiB unencrypted EFI partition mounted at /boot
#   * LUKS2 encrypted root (ext4); the initramfs asks for the passphrase
#   * GRUB, NetworkManager, chrony, ufw firewall (deny incoming)
#   * optional: linux-lts fallback kernel, yay (AUR)
#
# Made for the ThinkPad T14s Gen 2 (Intel or AMD) and other recent
# ThinkPads. Run it as root from the Artix base dinit live ISO. Afterwards,
# install a desktop with https://github.com/tcvscheppingen/DARBS
#
# Usage:
#   ./artix-install.sh                  # interactive
#   ./artix-install.sh --config FILE    # preset answers (see install.conf.example)
#
# Every variable listed in install.conf.example can also be set in the
# environment. Anything not set is asked for.

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly MNT=/mnt
readonly CRYPT_NAME=cryptroot
readonly LOG=/tmp/artix-install.log
readonly AUR_WIKI="https://wiki.archlinux.org/title/Arch_User_Repository"
readonly DARBS_URL="https://github.com/tcvscheppingen/DARBS"

# --- Output helpers ---

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[1;34m'; C_RST=$'\e[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_RST=''
fi

step() { printf '\n%s==> %s%s\n' "$C_BLU" "$*" "$C_RST"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s  ✓ %s%s\n' "$C_GRN" "$*" "$C_RST"; }
warn() { printf '%s  ! %s%s\n' "$C_YLW" "$*" "$C_RST" >&2; }
die()  { printf '%sERROR: %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }

# --- Prompt helpers: they only ask when the variable is still empty ---

# ask VAR "Question" [default]
ask() {
    local -n _ref=$1
    local question=$2 default=${3-} answer
    [[ -n ${_ref-} ]] && return 0
    while :; do
        if [[ -n $default ]]; then
            read -r -p "$question [$default]: " answer
            answer=${answer:-$default}
        else
            read -r -p "$question: " answer
        fi
        [[ -n $answer ]] && break
        warn "Please enter a value."
    done
    _ref=$answer
}

# ask_yes_no VAR "Question" default(y|n) -> VAR is "yes" or "no"
ask_yes_no() {
    local -n _yn=$1
    local question=$2 default=$3 answer hint
    case ${_yn-} in
        y|Y|yes|YES|true|1) _yn=yes; return 0 ;;
        n|N|no|NO|false|0)  _yn=no;  return 0 ;;
    esac
    [[ $default == y ]] && hint="Y/n" || hint="y/N"
    while :; do
        read -r -p "$question [$hint]: " answer
        answer=${answer:-$default}
        case $answer in
            y|Y|yes|Yes) _yn=yes; return 0 ;;
            n|N|no|No)   _yn=no;  return 0 ;;
        esac
        warn "Please answer y or n."
    done
}

# ask_password VAR "What" [min_length]
ask_password() {
    local -n _pw=$1
    local what=$2 min=${3:-1} p1 p2
    [[ -n ${_pw-} ]] && return 0
    while :; do
        read -r -s -p "$what: " p1; echo
        read -r -s -p "Repeat $what: " p2; echo
        if [[ $p1 != "$p2" ]]; then
            warn "The entries don't match, try again."
        elif (( ${#p1} < min )); then
            warn "Use at least $min characters."
        else
            break
        fi
    done
    _pw=$p1
}

# --- Misc helpers ---

# Partition device name: /dev/sda -> /dev/sda1, /dev/nvme0n1 -> /dev/nvme0n1p1
part_name() {
    if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "${1}$2"; fi
}

in_chroot() { artix-chroot "$MNT" "$@"; }

# PACMAN_CHROOT_OPTS: --disable-sandbox in containers
# shellcheck disable=SC2086
chroot_pacman() { in_chroot pacman $PACMAN_CHROOT_OPTS "$@"; }

# dinit doesn't run in the chroot, so create the link `dinitctl enable` would
enable_service() {
    local svc=$1
    [[ -e $MNT/etc/dinit.d/$svc ]] || die "dinit service '$svc' not found in the new system"
    ln -sfn "/etc/dinit.d/$svc" "$MNT/etc/dinit.d/boot.d/$svc"
    ENABLED_SERVICES+=("$svc")
}

# Without udev (containers) partition nodes never appear; make them from sysfs
wait_for_partitions() {
    local disk=$1 dev name i major minor
    partx -u "$disk" 2> /dev/null || blockdev --rereadpt "$disk" 2> /dev/null || true
    for dev in "$PART_EFI" "$PART_ROOT"; do
        for (( i = 0; i < 20; i++ )); do
            [[ -b $dev ]] && break
            sleep 0.5
        done
        if [[ ! -b $dev ]]; then
            name=$(basename "$dev")
            [[ -r /sys/class/block/$name/dev ]] || die "Partition $dev did not appear"
            IFS=: read -r major minor < "/sys/class/block/$name/dev"
            mknod "$dev" b "$major" "$minor"
        fi
    done
}

# The stock list isn't sorted by distance and has dead mirrors. -w drops
# the ones that don't answer within 5 s.
rank_mirrors() {
    local list=/etc/pacman.d/mirrorlist tmp count
    if ! command -v rankmirrors > /dev/null; then
        pacman -S --needed --noconfirm pacman-contrib > /dev/null \
            || { warn "Couldn't install pacman-contrib; keeping the stock mirror order"; return 0; }
    fi
    [[ -e $list.stock ]] || cp "$list" "$list.stock"
    info "Timing every mirror, this takes up to a minute..."
    tmp=$(mktemp)
    rankmirrors -w -n 0 -r system -m 5 "$list.stock" > "$tmp" 2> /dev/null || true
    count=$(grep -c '^Server' "$tmp" || true)
    if (( count == 0 )); then
        warn "No mirror answered within 5 s; keeping the stock mirror order"
        rm -f "$tmp"
        return 0
    fi
    install -m 644 "$tmp" "$list"
    rm -f "$tmp"
    ok "$count of $(grep -c '^[[:space:]]*Server' "$list.stock") mirrors answered, fastest: $(awk '/^Server/ {sub(/^[a-z]+:\/\//, "", $3); sub(/\/.*/, "", $3); print $3; exit}' "$list")"
}

# gpg-agent/dirmngr started in the chroot keep running and block umount
stop_chroot_processes() {
    local pid
    artix-chroot "$MNT" gpgconf --homedir /etc/pacman.d/gnupg --kill all &> /dev/null || true
    for pid in /proc/[0-9]*; do
        if [[ $(readlink "$pid/root" 2> /dev/null) == "$MNT" ]]; then
            kill "${pid#/proc/}" 2> /dev/null || true
        fi
    done
    sleep 1
}

cleanup() {
    local rc=$?
    set +e
    if (( rc != 0 )); then
        printf '\n%sThe installation failed (exit code %s). See %s%s\n' "$C_RED" "$rc" "$LOG" "$C_RST" >&2
    fi
    if mountpoint -q "$MNT" 2> /dev/null; then
        stop_chroot_processes
        umount -R "$MNT" 2> /dev/null
    fi
    [[ -e /dev/mapper/$CRYPT_NAME ]] && cryptsetup close "$CRYPT_NAME" 2> /dev/null
    exit "$rc"
}

usage() {
    sed -n '3,/^$/s/^# \{0,1\}//p' "$0"
    exit 0
}

# --- Arguments and logging ---

CONFIG_FILE=""
while (( $# )); do
    case $1 in
        -c|--config) CONFIG_FILE=${2-}; shift 2 ;;
        -h|--help)   usage ;;
        *)           die "Unknown option: $1 (see --help)" ;;
    esac
done

if [[ -n $CONFIG_FILE ]]; then
    [[ -r $CONFIG_FILE ]] || die "Can't read config file $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Everything that can be preset (empty = ask)
DISK=${DISK-}
HOST_NAME=${HOST_NAME-}
USER_NAME=${USER_NAME-}
USER_PASSWORD=${USER_PASSWORD-}
LUKS_PASSWORD=${LUKS_PASSWORD-}
ENABLE_ROOT=${ENABLE_ROOT-}
ROOT_PASSWORD=${ROOT_PASSWORD-}
TIMEZONE=${TIMEZONE-}
KEYMAP=${KEYMAP-}
LOCALE=${LOCALE-}
SWAP_SIZE=${SWAP_SIZE-}
INSTALL_LTS=${INSTALL_LTS-}
ENABLE_AUR=${ENABLE_AUR-}
CONFIRM_WIPE=${CONFIRM_WIPE-}
REBOOT_WHEN_DONE=${REBOOT_WHEN_DONE-}
# Advanced / testing
EXTRA_KERNEL_PARAMS=${EXTRA_KERNEL_PARAMS-}
LUKS_FORMAT_OPTS=${LUKS_FORMAT_OPTS-}
ALLOW_NO_UEFI=${ALLOW_NO_UEFI-no}
CPU_VENDOR=${CPU_VENDOR-}
PACMAN_CHROOT_OPTS=${PACMAN_CHROOT_OPTS-}

ENABLED_SERVICES=()

(( EUID == 0 )) || die "Run this script as root (on the live ISO you are root already)."

: > "$LOG"
chmod 600 "$LOG"
# Passwords are read with read -s, so they never reach the log
exec > >(tee -a "$LOG") 2>&1
trap cleanup EXIT

cat << EOF
${C_BLU}
  Artix Linux (dinit) installer v$SCRIPT_VERSION
  -------------------------------------------
  UEFI + GRUB, LUKS2 encrypted root, boots to a TTY.
  The whole target disk will be ERASED.
${C_RST}
EOF

# --- 1. Pre-flight checks ---

step "Checking the live environment"

if [[ -d /sys/firmware/efi/efivars ]] || [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE=UEFI
    ok "Booted in UEFI mode"
elif [[ $ALLOW_NO_UEFI == yes ]]; then
    BOOT_MODE="none (test mode)"
    warn "No UEFI firmware found; continuing because ALLOW_NO_UEFI=yes (testing only)"
else
    die "This system did not boot in UEFI mode. Reboot, and in the ThinkPad F12 boot menu pick the USB stick's UEFI entry. Make sure CSM/legacy boot is off in the firmware setup (F1)."
fi

grep -qs '^ID=artix' /etc/os-release || die "This doesn't look like an Artix system. Boot the Artix base dinit ISO."

for cmd in basestrap artix-chroot cryptsetup sfdisk mkfs.fat mkfs.ext4 pacman-key curl; do
    command -v "$cmd" > /dev/null || die "Required command '$cmd' not found. Use the Artix base dinit ISO."
done
ok "Required tools are present"

if ! curl -fsS --max-time 10 -o /dev/null https://artixlinux.org; then
    die "No internet connection. Connect with a cable, or Wi-Fi via connmanctl (see the guide), then run this script again."
fi
ok "Internet connection works"

if [[ -n $CPU_VENDOR ]]; then
    :   # preset (tests)
elif grep -qm1 'GenuineIntel' /proc/cpuinfo; then
    CPU_VENDOR=intel
elif grep -qm1 'AuthenticAMD' /proc/cpuinfo; then
    CPU_VENDOR=amd
else
    CPU_VENDOR=unknown
fi
ok "CPU vendor: $CPU_VENDOR"

# --- 2. Questions ---

step "Target disk"
mapfile -t DISKS < <(lsblk -dpno NAME,TYPE,RO | awk '$2 == "disk" && $3 == 0 {print $1}')
(( ${#DISKS[@]} )) || [[ -n $DISK ]] || die "No disks found."
if [[ -z $DISK ]]; then
    lsblk -dpo NAME,SIZE,MODEL,TRAN | grep -Ev 'loop|sr[0-9]|zram'
    default_disk=""
    [[ -b /dev/nvme0n1 ]] && default_disk=/dev/nvme0n1
    [[ -z $default_disk ]] && default_disk=${DISKS[0]}
    ask DISK "Disk to install to (it will be erased)" "$default_disk"
fi
[[ -b $DISK ]] || die "$DISK is not a block device."
PART_EFI=$(part_name "$DISK" 1)
PART_ROOT=$(part_name "$DISK" 2)
DISK_SIZE=$(lsblk -dbno SIZE "$DISK")
(( DISK_SIZE >= 20 * 1024 ** 3 )) || die "$DISK is smaller than 20 GiB."
if lsblk -no MOUNTPOINTS "$DISK" 2> /dev/null | grep -q .; then
    die "$DISK (or a partition on it) is mounted. Is this the USB stick you booted from?"
fi

step "Keyboard, language and time zone"
info "The console keymap is also used at the disk passphrase prompt during boot."
info "us-acentos = US international with dead keys ( ' then e = é, ' then space = ' )."
while :; do
    ask KEYMAP "Console keymap" "us-acentos"
    if find /usr/share/kbd/keymaps -name "$KEYMAP.map.gz" 2> /dev/null | grep -q .; then break; fi
    warn "Keymap '$KEYMAP' not found (list them with: localectl list-keymaps or ls /usr/share/kbd/keymaps/i386/*)"
    KEYMAP=""
done
# Same layout for the passwords below as at the boot prompt
if loadkeys "$KEYMAP" 2> /dev/null; then
    ok "Loaded keymap $KEYMAP for the rest of the installation"
    KEYMAP_LOADED=yes
else
    KEYMAP_LOADED=no
fi

while :; do
    ask LOCALE "System language (locale)" "en_US.UTF-8"
    if grep -q "^$LOCALE " /usr/share/i18n/SUPPORTED 2> /dev/null; then break; fi
    warn "Locale '$LOCALE' not found in /usr/share/i18n/SUPPORTED (example: en_US.UTF-8, nl_NL.UTF-8)"
    LOCALE=""
done

while :; do
    ask TIMEZONE "Time zone" "Europe/Amsterdam"
    if [[ -f /usr/share/zoneinfo/$TIMEZONE ]]; then break; fi
    warn "Time zone '$TIMEZONE' not found (examples: Europe/Amsterdam, America/New_York, UTC)"
    TIMEZONE=""
done

step "Host name and users"
while :; do
    ask HOST_NAME "Host name" "t14s"
    [[ $HOST_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] && break
    warn "Use letters, digits and hyphens only (max 63 characters)."
    HOST_NAME=""
done

while :; do
    ask USER_NAME "User name"
    if [[ $USER_NAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [[ $USER_NAME != root ]]; then break; fi
    warn "Use lower-case letters, digits, '-' and '_', starting with a letter (not 'root')."
    USER_NAME=""
done
ask_password USER_PASSWORD "Password for $USER_NAME"

info ""
info "If you don't enable root, the root account is locked and you use sudo."
ask_yes_no ENABLE_ROOT "Enable the root account (set a root password)?" n
if [[ $ENABLE_ROOT == yes ]]; then
    ask_password ROOT_PASSWORD "Root password"
fi

step "Disk encryption"
info "This passphrase unlocks the disk at every boot. Without it your data is gone."
ask_password LUKS_PASSWORD "Disk encryption passphrase" 8
if [[ $KEYMAP_LOADED == no ]] && [[ $KEYMAP == *acentos* || $KEYMAP == *intl* ]] \
        && [[ $LUKS_PASSWORD =~ [\'\"\`~^] ]]; then
    warn "Your passphrase contains ' \" \` ~ or ^. With the dead-key keymap $KEYMAP"
    warn "you must press space after those characters at the boot prompt."
fi

step "Extras"
info "A swap file in the encrypted root protects against out-of-memory crashes."
while :; do
    ask SWAP_SIZE "Swap file size in GiB (0 = no swap)" "4"
    [[ $SWAP_SIZE =~ ^[0-9]+$ ]] && break
    warn "Enter a whole number."
    SWAP_SIZE=""
done

info ""
info "The LTS kernel is a second boot entry (GRUB > Advanced options) you can"
info "use when an update of the normal kernel doesn't boot."
ask_yes_no INSTALL_LTS "Install the linux-lts fallback kernel?" y

info ""
printf '%s' "$C_YLW"
cat << EOF
    The AUR (Arch User Repository):
    AUR packages are user-produced content. These PKGBUILDs are completely
    unofficial and have not been thoroughly vetted. Any use of the provided
    files is at your own risk.
    More information: $AUR_WIKI
EOF
printf '%s' "$C_RST"
ask_yes_no ENABLE_AUR "Enable the AUR (installs the yay AUR helper)?" n

# --- 3. Confirmation ---

step "Overview"
cat << EOF
    Disk            : $DISK ($(numfmt --to=iec "$DISK_SIZE")) - WILL BE ERASED
                      $PART_EFI  1 GiB  EFI / /boot (FAT32, not encrypted)
                      $PART_ROOT rest   LUKS2 -> /dev/mapper/$CRYPT_NAME (ext4, /)
    Host name       : $HOST_NAME
    User            : $USER_NAME (groups: wheel, sudo allowed)
    Root account    : $([[ $ENABLE_ROOT == yes ]] && echo enabled || echo "locked (use sudo)")
    Keymap          : $KEYMAP
    Locale          : $LOCALE
    Time zone       : $TIMEZONE
    Swap file       : $([[ $SWAP_SIZE == 0 ]] && echo none || echo "$SWAP_SIZE GiB")
    LTS kernel      : $INSTALL_LTS
    AUR (yay)       : $ENABLE_AUR
    Firewall        : ufw (deny incoming, allow outgoing)
EOF

if [[ $CONFIRM_WIPE != yes ]]; then
    echo
    read -r -p "Type ERASE to wipe $DISK and install: " answer
    [[ $answer == ERASE ]] || die "Aborted, nothing was changed."
fi

# --- 4. Clock and keyring on the live system ---

step "Checking the clock"
# A wrong clock breaks PGP signatures and TLS
if web_date=$(curl -fsSI --max-time 10 https://artixlinux.org | awk -F': ' 'tolower($1) == "date" {print $2}' | tr -d '\r') \
        && [[ -n $web_date ]]; then
    web_epoch=$(date -d "$web_date" +%s)
    skew=$(( $(date +%s) - web_epoch ))
    if (( ${skew#-} > 120 )); then
        date -s "@$web_epoch" > /dev/null
        ok "Clock was off by ${skew}s, set to $(date -u '+%F %T') UTC"
    else
        ok "Clock is correct ($(date -u '+%F %T') UTC)"
    fi
else
    warn "Couldn't check the clock. If package signatures fail, set it with: date -s 'YYYY-MM-DD HH:MM'"
fi

step "Initialising the pacman keyring"
pacman-key --init
pacman-key --populate artix
pacman -Sy --needed --noconfirm artix-keyring
ok "Keyring ready"

step "Ranking the package mirrors"
rank_mirrors

# --- 5. Partitioning and encryption ---

step "Partitioning $DISK"
# Leftovers from an earlier, failed run
if mountpoint -q "$MNT"; then
    swapoff "$MNT/swapfile" 2> /dev/null || true
    umount -R "$MNT"
fi
if [[ -e /dev/mapper/$CRYPT_NAME ]]; then
    cryptsetup close "$CRYPT_NAME" || die "/dev/mapper/$CRYPT_NAME is still in use; reboot the live ISO and try again"
    info "Closed $CRYPT_NAME left over from an earlier attempt"
fi
swapoff -a 2> /dev/null || true
wipefs -af "$DISK" > /dev/null
sfdisk -q --wipe always "$DISK" << 'EOF'
label: gpt
size=1GiB, type=U, name=EFI
type=L, name=ARTIX
EOF
wait_for_partitions "$DISK"
ok "Created $PART_EFI (EFI) and $PART_ROOT (LUKS)"

step "Encrypting $PART_ROOT (LUKS2)"
# shellcheck disable=SC2086  # LUKS_FORMAT_OPTS is intentionally split
printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 --batch-mode \
    $LUKS_FORMAT_OPTS --key-file=- "$PART_ROOT"
printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file=- "$PART_ROOT" "$CRYPT_NAME"
LUKS_UUID=$(cryptsetup luksUUID "$PART_ROOT")
ok "Encrypted, LUKS UUID $LUKS_UUID"

step "Creating file systems"
mkfs.fat -F 32 -n EFI "$PART_EFI" > /dev/null
mkfs.ext4 -q -F -L ROOT "/dev/mapper/$CRYPT_NAME"
mount "/dev/mapper/$CRYPT_NAME" "$MNT"
mkdir -p "$MNT/boot"
mount "$PART_EFI" "$MNT/boot"
ROOT_FS_UUID=$(blkid -s UUID -o value "/dev/mapper/$CRYPT_NAME")
ok "Mounted the new system on $MNT"

if (( SWAP_SIZE > 0 )); then
    step "Creating a ${SWAP_SIZE} GiB swap file"
    fallocate -l "${SWAP_SIZE}G" "$MNT/swapfile"
    chmod 600 "$MNT/swapfile"
    mkswap -q "$MNT/swapfile"
    ok "Swap file created"
fi

# --- 6. Base system ---

step "Installing the base system (this takes a while)"
PACKAGES=(
    base base-devel dinit elogind-dinit
    linux linux-headers linux-firmware sof-firmware
    cryptsetup grub efibootmgr dosfstools e2fsprogs
    networkmanager networkmanager-dinit
    chrony chrony-dinit
    ufw ufw-dinit
    sudo git vim man-db bash-completion
)
# No GPU userspace (mesa etc.): that's up to the desktop installer
case $CPU_VENDOR in
    intel) PACKAGES+=(intel-ucode) ;;
    amd)   PACKAGES+=(amd-ucode) ;;
    *)     PACKAGES+=(intel-ucode amd-ucode) ;;
esac
[[ $INSTALL_LTS == yes ]] && PACKAGES+=(linux-lts linux-lts-headers)

# -K: separate keyring for the new system
basestrap -K "$MNT" "${PACKAGES[@]}"
# Make sure the new system gets the ranked list, not the package's stock one
cp /etc/pacman.d/mirrorlist "$MNT/etc/pacman.d/mirrorlist"
if [[ -e /etc/pacman.d/mirrorlist.stock ]]; then
    cp /etc/pacman.d/mirrorlist.stock "$MNT/etc/pacman.d/mirrorlist.stock"
fi
ok "Base system installed"

step "Generating /etc/fstab"
# Not fstabgen: it would also add the live system's zram swap
EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")
[[ -n $ROOT_FS_UUID && -n $EFI_UUID ]] || die "Couldn't read the file system UUIDs"
{
    printf '# <file system>\t<dir>\t<type>\t<options>\t<dump>\t<pass>\n'
    printf '# /dev/mapper/%s (LUKS2 on %s)\n' "$CRYPT_NAME" "$PART_ROOT"
    printf 'UUID=%s\t/\text4\trw,relatime\t0 1\n\n' "$ROOT_FS_UUID"
    printf '# %s (EFI system partition)\n' "$PART_EFI"
    printf 'UUID=%s\t/boot\tvfat\trw,relatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro\t0 2\n' "$EFI_UUID"
    if (( SWAP_SIZE > 0 )); then
        printf '\n/swapfile\tnone\tswap\tdefaults\t0 0\n'
    fi
} >> "$MNT/etc/fstab"
ok "fstab written"

# --- 7. System configuration ---

step "Configuring the keyring in the new system"
in_chroot pacman-key --init
in_chroot pacman-key --populate artix
ok "Keyring initialised and populated"

step "Time zone, locale, keymap and host name"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
in_chroot hwclock --systohc || warn "hwclock failed (normal in a container)"

for loc in "$LOCALE" en_US.UTF-8; do
    charset=$(grep -m1 "^$loc " /usr/share/i18n/SUPPORTED | awk '{print $2}')
    if ! grep -q "^$loc $charset" "$MNT/etc/locale.gen"; then
        echo "$loc $charset" >> "$MNT/etc/locale.gen"
    fi
done
in_chroot locale-gen
echo "LANG=$LOCALE" > "$MNT/etc/locale.conf"
echo "KEYMAP=$KEYMAP" > "$MNT/etc/vconsole.conf"

echo "$HOST_NAME" > "$MNT/etc/hostname"
cat > "$MNT/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST_NAME.localdomain $HOST_NAME
EOF
ok "$TIMEZONE, $LOCALE, $KEYMAP, $HOST_NAME"

step "Initramfs with the encrypt hook"
# keyboard and keymap before encrypt, for the passphrase prompt
hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck"
for h in $hooks; do
    [[ -e $MNT/usr/lib/initcpio/install/$h ]] || hooks=${hooks/ $h / }
done
sed -i "s/^HOOKS=.*/HOOKS=($hooks)/" "$MNT/etc/mkinitcpio.conf"
grep -q '^HOOKS=(.*encrypt' "$MNT/etc/mkinitcpio.conf" || die "Couldn't set HOOKS in mkinitcpio.conf"
info "HOOKS=($hooks)"
in_chroot mkinitcpio -P
ok "Initramfs built"

step "Installing GRUB"
cmdline="cryptdevice=UUID=$LUKS_UUID:$CRYPT_NAME root=/dev/mapper/$CRYPT_NAME"
[[ -n $EXTRA_KERNEL_PARAMS ]] && cmdline+=" $EXTRA_KERNEL_PARAMS"
if grep -q '^GRUB_CMDLINE_LINUX=' "$MNT/etc/default/grub"; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$cmdline\"|" "$MNT/etc/default/grub"
else
    echo "GRUB_CMDLINE_LINUX=\"$cmdline\"" >> "$MNT/etc/default/grub"
fi
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/; s/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' "$MNT/etc/default/grub"
grep -q '^GRUB_SAVEDEFAULT=' "$MNT/etc/default/grub" || echo 'GRUB_SAVEDEFAULT=true' >> "$MNT/etc/default/grub"
# Otherwise grub-mkconfig puts linux-lts first
sed -i '/^#\?GRUB_TOP_LEVEL=/d' "$MNT/etc/default/grub"
echo 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux"' >> "$MNT/etc/default/grub"

if [[ $BOOT_MODE == UEFI ]]; then
    in_chroot grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=artix
else
    in_chroot grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=artix --no-nvram
fi
# Fallback path \EFI\BOOT\BOOTX64.EFI, for firmware that loses its boot entries
in_chroot grub-install --target=x86_64-efi --efi-directory=/boot --removable
in_chroot grub-mkconfig -o /boot/grub/grub.cfg
grep -q "cryptdevice=UUID=$LUKS_UUID" "$MNT/boot/grub/grub.cfg" || die "grub.cfg doesn't contain the cryptdevice option"
ok "GRUB installed (artix entry + fallback path)"

step "Users and sudo"
in_chroot useradd -m -G wheel -s /bin/bash "$USER_NAME"
printf '%s:%s\n' "$USER_NAME" "$USER_PASSWORD" | chpasswd -R "$MNT"
cat > "$MNT/etc/sudoers.d/10-wheel" << 'EOF'
# Members of the wheel group may run any command with sudo (added by artix-install.sh)
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 "$MNT/etc/sudoers.d/10-wheel"
in_chroot visudo -cq || die "sudoers syntax check failed"
if [[ $ENABLE_ROOT == yes ]]; then
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd -R "$MNT"
    ok "User $USER_NAME created (wheel, sudo); root password set"
else
    in_chroot passwd -l root > /dev/null
    ok "User $USER_NAME created (wheel, sudo); root account locked"
fi

step "Services"
enable_service NetworkManager
if [[ -e $MNT/etc/dinit.d/chronyd ]]; then enable_service chronyd; else enable_service chrony; fi

sed -i 's/^ENABLED=.*/ENABLED=yes/' "$MNT/etc/ufw/ufw.conf"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/;
        s/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/;
        s/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' "$MNT/etc/default/ufw"
enable_service ufw
ok "Enabled: ${ENABLED_SERVICES[*]}"

# --- 8. Optional: AUR helper ---

if [[ $ENABLE_AUR == yes ]]; then
    step "Installing yay (AUR helper)"
    had_go=no
    in_chroot pacman -Q go &> /dev/null && had_go=yes
    chroot_pacman -S --needed --noconfirm git base-devel go
    # Not in /tmp: artix-chroot mounts a fresh tmpfs there for every command
    build_dir=/home/$USER_NAME/.cache/yay-build
    in_chroot su - "$USER_NAME" -c "
        set -e
        rm -rf '$build_dir'
        git clone --depth 1 https://aur.archlinux.org/yay.git '$build_dir'
        cd '$build_dir'
        makepkg --noconfirm
    "
    yay_pkg=$(find "$MNT$build_dir" -maxdepth 1 -name 'yay-[0-9]*.pkg.tar.*' ! -name '*-debug-*' | head -n1)
    [[ -n $yay_pkg ]] || die "Building yay failed"
    chroot_pacman -U --noconfirm "${yay_pkg#"$MNT"}"
    rm -rf "${MNT:?}$build_dir"
    if [[ $had_go == no ]]; then chroot_pacman -Rns --noconfirm go; fi
    ok "yay $(in_chroot pacman -Q yay | awk '{print $2}') installed"
fi

# --- 9. Summary ---

step "Finishing"
kernel_pkgs=(linux)
if [[ $INSTALL_LTS == yes ]]; then kernel_pkgs+=(linux-lts); fi
KERNELS=$(in_chroot pacman -Q "${kernel_pkgs[@]}" | awk '{printf "%s %s  ", $1, $2}')
SUMMARY_DIR="$MNT/var/log/artix-install"
mkdir -p "$SUMMARY_DIR"

SUMMARY=$(cat << EOF
================================================================================
 Artix Linux (dinit) installation summary            $(date '+%F %R %Z')
================================================================================
 Hardware
   Boot mode        : $BOOT_MODE
   CPU vendor       : $CPU_VENDOR (microcode chosen for it)

 Disk ($DISK, $(numfmt --to=iec "$DISK_SIZE"))
   $PART_EFI : EFI system partition, FAT32, mounted at /boot (NOT encrypted)
   $PART_ROOT : LUKS2 (UUID $LUKS_UUID)
       -> /dev/mapper/$CRYPT_NAME : ext4, mounted at / (UUID $ROOT_FS_UUID)
   Swap             : $([[ $SWAP_SIZE == 0 ]] && echo none || echo "/swapfile, $SWAP_SIZE GiB (inside the encrypted root)")

 System
   Host name        : $HOST_NAME
   Kernel(s)        : $KERNELS
   Bootloader       : GRUB (EFI entry "artix" + fallback \\EFI\\BOOT\\BOOTX64.EFI)
   Init             : dinit
   Locale           : $LOCALE
   Console keymap   : $KEYMAP (also used at the passphrase prompt)
   Time zone        : $TIMEZONE
   Fallback kernel  : $([[ $INSTALL_LTS == yes ]] && echo "linux-lts (GRUB > Advanced options for Artix Linux)" || echo "none")

 Accounts
   User             : $USER_NAME (groups: $(in_chroot id -nG "$USER_NAME"))
   sudo             : %wheel ALL=(ALL:ALL) ALL  (/etc/sudoers.d/10-wheel)
   root             : $([[ $ENABLE_ROOT == yes ]] && echo "enabled (password set)" || echo "locked - use sudo")

 Security
   Disk encryption  : LUKS2, passphrase asked by the initramfs at boot
   Firewall         : ufw, enabled at boot: deny incoming, allow outgoing
                      Status: sudo ufw status verbose   Allow ssh: sudo ufw allow ssh
                      GUI (after you install a desktop): sudo pacman -S gufw
   Keyring          : initialised and populated (artix-keyring)
   Mirrors          : ranked at install time, stock list in /etc/pacman.d/mirrorlist.stock

 Services (dinit, /etc/dinit.d/boot.d)
   ${ENABLED_SERVICES[*]}

 AUR
   yay              : $([[ $ENABLE_AUR == yes ]] && echo "installed - AUR packages are unofficial, review PKGBUILDs ($AUR_WIKI)" || echo "not enabled")

 Next steps
   1. Reboot and remove the USB stick.
   2. Type the disk passphrase at "Enter passphrase for $PART_ROOT".
   3. Log in as $USER_NAME. Connect to Wi-Fi with: nmtui
   4. Install a desktop, for example DARBS: $DARBS_URL

 This summary: /var/log/artix-install/summary.txt   Full log: /var/log/artix-install/install.log
================================================================================
EOF
)

echo "$SUMMARY" > "$SUMMARY_DIR/summary.txt"
chmod 644 "$SUMMARY_DIR/summary.txt"
printf '\n%s\n' "$SUMMARY"

cp "$LOG" "$SUMMARY_DIR/install.log"
chmod 600 "$SUMMARY_DIR/install.log"

sync
stop_chroot_processes
umount -R "$MNT"
cryptsetup close "$CRYPT_NAME"
ok "Unmounted the new system and closed the encrypted disk"

ask_yes_no REBOOT_WHEN_DONE "Reboot now?" y
if [[ $REBOOT_WHEN_DONE == yes ]]; then
    info "Rebooting, remove the USB stick when the screen goes dark."
    sleep 3
    reboot
fi
