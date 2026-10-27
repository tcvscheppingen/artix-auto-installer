#!/usr/bin/env bash
#
# artix-install.sh - automated Artix Linux (dinit) installation
#
# Installs a minimal Artix with dinit:
#   * UEFI only, GPT, 1 GiB unencrypted EFI partition mounted at /boot
#   * LUKS2 encrypted root (ext4); the initramfs asks for the passphrase
#   * GRUB, NetworkManager, chrony, ufw firewall (deny incoming)
#   * optional: linux-lts fallback kernel, Timeshift snapshots, NVIDIA driver,
#     yay (AUR)
#   * optional desktop: KDE Plasma, Cinnamon, XFCE or LXQt, or sway
#     (https://github.com/tcvscheppingen/SARBS) or dwm
#     (https://github.com/tcvscheppingen/DARBS); without one it boots to a TTY
#
# For UEFI PCs and laptops with an Intel or AMD CPU. Run it as root from the
# Artix base dinit live ISO.
#
# Usage:
#   ./artix-install.sh                  # interactive
#   ./artix-install.sh --config FILE    # preset answers (see install.conf.example)
#   ./artix-install.sh --print-desktop-packages plasma|cinnamon|xfce|lxqt
#                                       # the packages of a desktop environment
#
# Every variable listed in install.conf.example can also be set in the
# environment. Anything not set is asked for.

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly MNT=/mnt
readonly LOG=/tmp/artix-install.log
readonly AUR_WIKI="https://wiki.archlinux.org/title/Arch_User_Repository"
readonly DARBS_URL="https://github.com/tcvscheppingen/DARBS"
readonly SARBS_URL="https://github.com/tcvscheppingen/SARBS"
# Lets the user's rice script use sudo without a password during the install
readonly RICE_SUDOERS=/etc/sudoers.d/99-artix-install

# --- Output helpers ---

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[1;34m'; C_RST=$'\e[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_RST=''
fi

# With the time since the start, to see what takes long
step() { printf '\n%s==> %s%s  [%02d:%02d]\n' "$C_BLU" "$*" "$C_RST" $((SECONDS / 60)) $((SECONDS % 60)); }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s  ✓ %s%s\n' "$C_GRN" "$*" "$C_RST"; }
warn() { printf '%s  ! %s%s\n' "$C_YLW" "$*" "$C_RST" >&2; }
# FAILED_AT: die explains the problem itself, see on_error
die()  { printf '%sERROR: %s%s\n' "$C_RED" "$*" "$C_RST" >&2; FAILED_AT=""; exit 1; }

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
    local question=$2 default=$3 preset=${_yn-} answer hint
    case ${preset,,} in
        y|yes|true|1) _yn=yes; return 0 ;;
        n|no|false|0) _yn=no;  return 0 ;;
    esac
    [[ $default == y ]] && hint="Y/n" || hint="y/N"
    while :; do
        read -r -p "$question [$hint]: " answer
        case ${answer:-$default} in
            [yY]|[yY][eE][sS]) _yn=yes; return 0 ;;
            [nN]|[nN][oO])     _yn=no;  return 0 ;;
        esac
        warn "Please answer y or n."
    done
}

# ask_choice VAR "Question" default "name:description"... -> VAR is one of
# the names. The answer can be the name or its number in the list.
ask_choice() {
    local -n _ch=$1
    local var=$1 question=$2 default=$3 answer opt i=0
    shift 3
    local names=()
    for opt; do names+=("${opt%%:*}"); done
    if [[ -n ${_ch-} ]]; then
        [[ " ${names[*]} " == *" $_ch "* ]] || die "$var=$_ch is not one of: ${names[*]}"
        return 0
    fi
    for opt; do
        i=$((i + 1))
        printf '    %d) %-9s %s\n' "$i" "${opt%%:*}" "${opt#*:}"
    done
    while :; do
        read -r -p "$question [$default]: " answer
        answer=${answer:-$default}
        if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#names[@]} )); then
            answer=${names[answer - 1]}
        fi
        if [[ " ${names[*]} " == *" $answer "* ]]; then _ch=$answer; return 0; fi
        warn "Choose a number from the list, or one of: ${names[*]}"
    done
}

# ask_password VAR "What" [min_length]
ask_password() {
    local -n _pw=$1
    local what=$2 min=${3:-1} p1 p2
    if [[ -n ${_pw-} ]]; then
        (( ${#_pw} >= min )) || die "$1 is shorter than $min characters"
        return 0
    fi
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

# The X layout (and variant) for a console keymap, empty when unknown. X
# doesn't read /etc/vconsole.conf; on systemd systems localectl writes this.
x11_layout() {
    case $1 in
        us)                   echo "us" ;;
        us-acentos)           echo "us intl" ;;
        uk)                   echo "gb" ;;
        dvorak)               echo "us dvorak" ;;
        colemak)              echo "us colemak" ;;
        de|de-latin1)         echo "de" ;;
        de-latin1-nodeadkeys) echo "de nodeadkeys" ;;
        fr|fr-latin1|fr-latin9) echo "fr" ;;
        be-latin1)            echo "be" ;;
        nl)                   echo "nl" ;;
        es)                   echo "es" ;;
        it)                   echo "it" ;;
        pt-latin1)            echo "pt" ;;
        br-abnt2)             echo "br" ;;
        dk|dk-latin1)         echo "dk" ;;
        no|no-latin1)         echo "no" ;;
        sv-latin1)            echo "se" ;;
        fi)                   echo "fi" ;;
        pl|pl2)               echo "pl" ;;
        cz)                   echo "cz" ;;
        hu)                   echo "hu" ;;
        ru)                   echo "ru" ;;
    esac
}

# KEY=VALUE in the new system's /etc/default/grub, also when the setting is
# there commented out
grub_set() {
    sed -i "/^#\?$1=/d" "$MNT/etc/default/grub"
    echo "$1=$2" >> "$MNT/etc/default/grub"
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

# Sets NVIDIA_ID (PCI device ID of the first NVIDIA GPU), OTHER_GPU (an
# Intel/AMD GPU next to it: hybrid laptop), GPU_PKGS (Vulkan and VA-API for
# the Intel/AMD GPUs, for the desktop environments) and NVIDIA_PKGS. By generation:
# Turing and newer (>= 0x1e00) use the open kernel modules, Maxwell to Volta
# (>= 0x1340) the 580xx branch, and Kepler and older have no packaged driver.
detect_gpus() {
    local dev class vendor id
    OTHER_GPU=no
    NVIDIA_PKGS=()
    GPU_PKGS=()
    for dev in /sys/bus/pci/devices/*; do
        [[ -r $dev/class ]] || continue
        read -r class < "$dev/class"
        [[ $class == 0x03* ]] || continue
        read -r vendor < "$dev/vendor"
        read -r id < "$dev/device"
        if [[ $vendor == 0x10de ]]; then
            [[ -n $NVIDIA_ID ]] || NVIDIA_ID=$id
        elif [[ $vendor == 0x8086 ]]; then
            OTHER_GPU=yes
            [[ " ${GPU_PKGS[*]} " == *" vulkan-intel "* ]] || GPU_PKGS+=(vulkan-intel intel-media-driver)
        elif [[ $vendor == 0x1002 ]]; then
            OTHER_GPU=yes
            # AMD's VA-API driver is part of mesa
            [[ " ${GPU_PKGS[*]} " == *" vulkan-radeon "* ]] || GPU_PKGS+=(vulkan-radeon)
        fi
    done
    [[ -n $NVIDIA_ID ]] || return 0
    if (( NVIDIA_ID >= 0x1e00 )); then
        NVIDIA_PKGS=(nvidia-open-dkms nvidia-utils)
    elif (( NVIDIA_ID >= 0x1340 )); then
        NVIDIA_PKGS=(nvidia-580xx-dkms nvidia-580xx-utils)
    fi
}

# Intel audio with a DSP (PCI class 0x040100 or 0x040380; plain HDA is
# 0x040300) can get the SOF driver; the kernel picks SOF when the laptop has
# digital microphones. Sets INTEL_AUDIO_DSP, AUDIO_DRIVER (the driver the
# live ISO uses) and SOF_FAILED: SOF's firmware is on the live ISO, but no
# sound device with playback came up. Without the firmware on the ISO that
# says nothing, and SOF can also fail later (only PipeWire shows a "Dummy
# Output"), so this only catches the clear failures.
detect_audio() {
    local dev class vendor
    AUDIO_DRIVER=""
    SOF_FAILED=no
    for dev in /sys/bus/pci/devices/*; do
        [[ -r $dev/class ]] || continue
        read -r class < "$dev/class"
        read -r vendor < "$dev/vendor"
        if [[ $vendor == 0x8086 && ( $class == 0x040100 || $class == 0x040380 ) ]]; then
            INTEL_AUDIO_DSP=yes
            if [[ -e $dev/driver ]]; then AUDIO_DRIVER=$(basename "$(readlink "$dev/driver")"); fi
        fi
    done
    if [[ $INTEL_AUDIO_DSP == yes && $AUDIO_DRIVER != snd_hda_intel ]] \
            && compgen -G "/usr/lib/firmware/intel/sof*" > /dev/null \
            && ! grep -qs playback /proc/asound/pcm; then
        SOF_FAILED=yes
    fi
    return 0
}

# The packages of a desktop environment, without the GPU drivers. turnstile
# starts the user's own dinit at login, which runs PipeWire (Artix has no
# other way to start it); blocaled is the locale1 D-Bus service that the
# desktops' keyboard settings use.
desktop_packages() {
    local common=(
        xorg-server xorg-xwayland dbus-dinit turnstile turnstile-dinit
        pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
        pipewire-dinit pipewire-pulse-dinit wireplumber-dinit
        bluez bluez-utils bluez-dinit blocaled xdg-user-dirs xdg-utils
        noto-fonts noto-fonts-emoji ttf-liberation librewolf
    )
    case $1 in
        plasma)   printf '%s\n' "${common[@]}" plasma-meta konsole dolphin kate ark gwenview okular spectacle \
                      sddm sddm-dinit ;;
        cinnamon) printf '%s\n' "${common[@]}" cinnamon gnome-terminal gnome-keyring file-roller eog \
                      pavucontrol blueman lightdm lightdm-dinit lightdm-gtk-greeter ;;
        xfce)     printf '%s\n' "${common[@]}" xfce4 xfce4-goodies gnome-keyring pavucontrol network-manager-applet \
                      blueman lightdm lightdm-dinit lightdm-gtk-greeter ;;
        # The lxqt group has openbox and pavucontrol-qt; LXQt needs an icon
        # theme of its own, and xscreensaver to lock the screen
        lxqt)     printf '%s\n' "${common[@]}" lxqt breeze-icons xscreensaver gnome-keyring network-manager-applet \
                      blueman lightdm lightdm-dinit lightdm-gtk-greeter ;;
        *)        return 1 ;;
    esac
}

# The name of the rice repository for sway or dwm
rice_name() { if [[ $1 == sway ]]; then echo SARBS; else echo DARBS; fi; }

desktop_label() {
    case $1 in
        none)     echo "none (boots to a TTY)" ;;
        plasma)   echo "KDE Plasma, SDDM login screen" ;;
        cinnamon) echo "Cinnamon, LightDM login screen" ;;
        xfce)     echo "XFCE, LightDM login screen" ;;
        lxqt)     echo "LXQt, LightDM login screen" ;;
        sway|dwm)
            case $DESKTOP_LOGIN in
                tty)  echo "$1 ($(rice_name "$1")), starts on TTY1 login" ;;
                dm)   echo "$1 ($(rice_name "$1")), LightDM login screen" ;;
                none) echo "$1 ($(rice_name "$1")), start it yourself" ;;
            esac ;;
    esac
}

# KDE Plasma, Cinnamon, XFCE or LXQt, with their display manager
install_desktop_environment() {
    local pkgs dm svc dir
    mapfile -t pkgs < <(desktop_packages "$DESKTOP")
    chroot_pacman -S --needed --noconfirm "${pkgs[@]}" ${GPU_PKGS[@]+"${GPU_PKGS[@]}"}
    if [[ $DESKTOP == plasma ]]; then
        dm=sddm
        mkdir -p "$MNT/etc/sddm.conf.d"
        printf '# artix-install.sh\n[Theme]\nCurrent=breeze\n' > "$MNT/etc/sddm.conf.d/10-theme.conf"
    else
        dm=lightdm
        mkdir -p "$MNT/etc/lightdm/lightdm.conf.d"
        # logind-check-graphical: wait for the GPU, like Artix's own desktop ISOs
        cat > "$MNT/etc/lightdm/lightdm.conf.d/50-artix-install.conf" << EOF
# artix-install.sh
[LightDM]
logind-check-graphical=true
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=$DESKTOP
EOF
    fi
    for svc in dbus turnstiled bluetoothd "$dm"; do enable_service "$svc"; done
    # PipeWire as the user's own services, started by turnstile at login
    dir=/home/$USER_NAME/.config/dinit.d/boot.d
    mkdir -p "$MNT$dir"
    for svc in pipewire pipewire-pulse wireplumber; do
        [[ -e $MNT/etc/dinit.d/user/$svc ]] || die "dinit user service '$svc' not found in the new system"
        ln -sfn "/etc/dinit.d/user/$svc" "$MNT$dir/$svc"
    done
    in_chroot chown -R "$USER_NAME:" "/home/$USER_NAME/.config"
    ok "$(desktop_label "$DESKTOP"); enabled: dbus turnstiled bluetoothd $dm; PipeWire for $USER_NAME"
}

# Undoes what install_rice changes only for the time the rice script runs
rice_cleanup() {
    rm -f "$MNT$RICE_SUDOERS"
    # pacman.conf has no comments after a directive, so the marker is the line before
    [[ -e $MNT/etc/pacman.conf ]] && sed -i '/^# artix-install.sh, until the rice script is done:$/{N;d}' "$MNT/etc/pacman.conf"
    return 0
}

# sway or dwm: runs SARBS's or DARBS's auto-rice-artix.sh as the user, the
# way the user would run it after the first boot
install_rice() {
    local name repo dir rc=0
    name=$(rice_name "$DESKTOP")
    if [[ $name == SARBS ]]; then repo=${SARBS_REPO:-$SARBS_URL}; else repo=${DARBS_REPO:-$DARBS_URL}; fi
    dir=/home/$USER_NAME/$name
    rm -rf "${MNT:?}$dir"
    if [[ -d $repo ]]; then
        cp -a "$repo" "$MNT$dir"   # a local checkout (tests)
        in_chroot chown -R "$USER_NAME:" "$dir"
    else
        in_chroot su - "$USER_NAME" -c "git clone --depth 1 $(printf '%q %q' "$repo" "$dir")"
    fi
    info "$name commit $(in_chroot git -c safe.directory='*' -C "$dir" rev-parse --short HEAD 2> /dev/null || echo unknown)"

    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$USER_NAME" > "$MNT$RICE_SUDOERS"
    chmod 440 "$MNT$RICE_SUDOERS"
    if [[ $PACMAN_CHROOT_OPTS == *--disable-sandbox* ]]; then
        sed -i 's/^\[options\]$/&\n# artix-install.sh, until the rice script is done:\nDisableSandbox/' "$MNT/etc/pacman.conf"
    fi
    # Enter answers anything else the script asks with its default
    in_chroot su - "$USER_NAME" -c "cd $(printf '%q' "$dir") && RICE_LOGIN=$DESKTOP_LOGIN ./auto-rice-artix.sh" < <(yes '') || rc=$?
    rice_cleanup
    (( rc == 0 )) || die "$name's auto-rice-artix.sh failed (exit code $rc)"
    ok "$(desktop_label "$DESKTOP")"
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

# The command that failed, for the message in cleanup. die exits without it.
FAILED_AT=""
on_error() { FAILED_AT="line $1: $2"; }

cleanup() {
    local rc=$?
    set +e
    if (( rc != 0 )); then
        [[ -n $FAILED_AT ]] && printf '\n%sFailed at %s%s\n' "$C_RED" "$FAILED_AT" "$C_RST" >&2
        printf '\n%sThe installation failed (exit code %s). See %s%s\n' "$C_RED" "$rc" "$LOG" "$C_RST" >&2
    fi
    if mountpoint -q "$MNT" 2> /dev/null; then
        rice_cleanup
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

# --- Settings ---

parse_args() {
    CONFIG_FILE=""
    while (( $# )); do
        case $1 in
            -c|--config) [[ -n ${2-} ]] || die "$1 needs a file name"; CONFIG_FILE=$2; shift 2 ;;
            --print-desktop-packages)
                desktop_packages "${2-}" || die "Desktop environments: plasma, cinnamon, xfce, lxqt"
                exit 0 ;;
            -h|--help)   usage ;;
            *)           die "Unknown option: $1 (see --help)" ;;
        esac
    done
}

# Everything that can be preset, from the config file or the environment
# (empty = ask). The steps below share these, and what they find or create
# (BOOT_MODE, DISK_SIZE, PART_EFI, LUKS_UUID...), as upper-case globals.
load_settings() {
    if [[ -n $CONFIG_FILE ]]; then
        [[ -r $CONFIG_FILE ]] || die "Can't read config file $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
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
    ENABLE_TIMESHIFT=${ENABLE_TIMESHIFT-}
    INSTALL_NVIDIA=${INSTALL_NVIDIA-}
    AUDIO_LEGACY_HDA=${AUDIO_LEGACY_HDA-}
    ENABLE_AUR=${ENABLE_AUR-}
    DESKTOP=${DESKTOP-}
    DESKTOP_LOGIN=${DESKTOP_LOGIN-}
    SWAY_WITHOUT_NVIDIA=${SWAY_WITHOUT_NVIDIA-}
    SAVE_SUMMARY=${SAVE_SUMMARY-}
    CONFIRM_WIPE=${CONFIRM_WIPE-}
    REBOOT_WHEN_DONE=${REBOOT_WHEN_DONE-}
    # Advanced / testing
    EXTRA_KERNEL_PARAMS=${EXTRA_KERNEL_PARAMS-}
    LUKS_FORMAT_OPTS=${LUKS_FORMAT_OPTS-}
    ALLOW_NO_UEFI=${ALLOW_NO_UEFI-no}
    CPU_VENDOR=${CPU_VENDOR-}
    NVIDIA_ID=${NVIDIA_ID-}
    INTEL_AUDIO_DSP=${INTEL_AUDIO_DSP-no}
    PACMAN_CHROOT_OPTS=${PACMAN_CHROOT_OPTS-}
    # A package cache that outlives the test runs, mounted in the new system
    PACMAN_CACHE_DIR=${PACMAN_CACHE_DIR-}
    CRYPT_NAME=${CRYPT_NAME:-cryptroot}
    # yes: a container on someone's computer, so don't touch its EFI boot
    # entries, clock or console keymap
    TEST_IN_CONTAINER=${TEST_IN_CONTAINER-no}
    # A git URL or a local checkout of SARBS/DARBS (tests: a local checkout)
    SARBS_REPO=${SARBS_REPO-}
    DARBS_REPO=${DARBS_REPO-}
}

start_logging() {
    : > "$LOG"
    chmod 600 "$LOG"
    # Passwords are read with read -s, so they never reach the log
    exec > >(tee -a "$LOG") 2>&1
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
    trap cleanup EXIT
}

print_banner() {
    cat << EOF
${C_BLU}
  Artix Linux (dinit) installer v$SCRIPT_VERSION
  -------------------------------------------
  UEFI + GRUB, LUKS2 encrypted root, optional desktop.
  The whole target disk will be ERASED.
${C_RST}
EOF
}

# --- 1. Pre-flight checks ---

check_boot_mode() {
    if [[ -d /sys/firmware/efi/efivars ]] || [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE=UEFI
        ok "Booted in UEFI mode"
    elif [[ $ALLOW_NO_UEFI == yes ]]; then
        BOOT_MODE="none (test mode)"
        warn "No UEFI firmware found; continuing because ALLOW_NO_UEFI=yes (testing only)"
    else
        die "This system did not boot in UEFI mode. Reboot, pick the USB stick's UEFI entry in the firmware's boot menu, and make sure CSM/legacy boot is off in the firmware setup."
    fi
}

check_live_system() {
    local cmd
    grep -qs '^ID=artix' /etc/os-release || die "This doesn't look like an Artix system. Boot the Artix base dinit ISO."
    for cmd in basestrap artix-chroot cryptsetup dmsetup sfdisk mkfs.fat mkfs.ext4 pacman-key curl; do
        command -v "$cmd" > /dev/null || die "Required command '$cmd' not found. Use the Artix base dinit ISO."
    done
    ok "Required tools are present"
}

# Before the disk is touched: pacman -Syu on the live ISO replaces its kernel
# package, which removes the running kernel's modules, so cryptsetup open
# can't load dm_crypt later. The test container has it from the host kernel.
check_dm_crypt() {
    if ! dmsetup targets 2> /dev/null | grep -q '^crypt ' && ! modprobe dm_crypt 2> /dev/null; then
        # pacman -Q linux: 7.1.8.artix1-3, uname -r: 7.1.8-artix1-3
        if [[ $(pacman -Q linux 2> /dev/null | awk '{print $2}' | sed 's/\.artix/-artix/') != "$(uname -r)" ]]; then
            die "The live system's kernel modules don't match its running kernel $(uname -r), most likely because the live system was updated with pacman -Syu. Reboot the live ISO and run the script without updating first (pacman -Sy git is enough)."
        fi
        die "Can't load the dm_crypt kernel module, which the disk encryption needs. Reboot the live ISO and try again."
    fi
    ok "Disk encryption (dm_crypt) is available"
}

# A few tries: right after connecting, DHCP and DNS may need a moment
check_internet() {
    local try
    for try in 1 2 3; do
        if curl -fsS --max-time 10 -o /dev/null https://artixlinux.org; then
            ok "Internet connection works"
            return 0
        fi
        if (( try < 3 )); then sleep 5; fi
    done
    die "No internet connection. Connect with a cable, or Wi-Fi via connmanctl (see the guide), then run this script again."
}

# Sets CPU_VENDOR, unless preset (tests)
detect_cpu() {
    if [[ -n $CPU_VENDOR ]]; then return 0; fi
    if grep -qm1 'GenuineIntel' /proc/cpuinfo; then
        CPU_VENDOR=intel
    elif grep -qm1 'AuthenticAMD' /proc/cpuinfo; then
        CPU_VENDOR=amd
    else
        CPU_VENDOR=unknown
    fi
}

detect_hardware() {
    detect_cpu
    ok "CPU vendor: $CPU_VENDOR"
    detect_gpus
    if [[ -n $NVIDIA_ID ]]; then
        ok "NVIDIA GPU: device $NVIDIA_ID$([[ $OTHER_GPU == yes ]] && echo ", next to an Intel/AMD GPU")"
    fi
    detect_audio
    if [[ $INTEL_AUDIO_DSP == yes ]]; then
        ok "Intel audio with DSP$([[ -n $AUDIO_DRIVER ]] && echo ", live ISO driver: $AUDIO_DRIVER")"
        if [[ $SOF_FAILED == yes ]]; then
            warn "SOF didn't start on the live system: no sound device came up, although its firmware is there"
        fi
    fi
}

# --- 2. Questions ---

ask_disk() {
    local disks default_disk
    mapfile -t disks < <(lsblk -dpno NAME,TYPE,RO | awk '$2 == "disk" && $3 == 0 {print $1}')
    if [[ -n $DISK ]]; then return 0; fi
    (( ${#disks[@]} )) || die "No disks found."
    lsblk -dpo NAME,SIZE,MODEL,TRAN | grep -Ev 'loop|sr[0-9]|zram'
    if [[ -b /dev/nvme0n1 ]]; then default_disk=/dev/nvme0n1; else default_disk=${disks[0]}; fi
    ask DISK "Disk to install to (it will be erased)" "$default_disk"
}

# Sets PART_EFI, PART_ROOT and DISK_SIZE
check_disk() {
    local disk_type in_use=() holder name
    [[ -b $DISK ]] || die "$DISK is not a block device."
    disk_type=$(lsblk -dno TYPE "$DISK")
    [[ $disk_type == part ]] && disk_type=partition
    # The tests install to a loop device
    [[ $disk_type == disk || ( $disk_type == loop && $TEST_IN_CONTAINER == yes ) ]] \
        || die "$DISK is a $disk_type, not a whole disk. Choose a disk such as /dev/sda or /dev/nvme0n1, not one of its partitions."
    PART_EFI=$(part_name "$DISK" 1)
    PART_ROOT=$(part_name "$DISK" 2)
    DISK_SIZE=$(lsblk -dbno SIZE "$DISK")
    (( DISK_SIZE >= 20 * 1024 ** 3 )) || die "$DISK is smaller than 20 GiB."
    # Mounted file systems and active swap ([SWAP]), also on its partitions
    if lsblk -no MOUNTPOINTS "$DISK" 2> /dev/null | grep -q .; then
        die "$DISK (or a partition on it) is mounted. Is this the USB stick you booted from?"
    fi
    # An unlocked LUKS volume, LVM or RAID on the disk keeps it busy, so the new
    # partition table wouldn't take effect. $CRYPT_NAME, left over from an
    # earlier attempt, is closed before partitioning.
    for holder in /sys/class/block/"${DISK##*/}"/holders/* /sys/class/block/"${DISK##*/}"/"${DISK##*/}"*/holders/*; do
        [[ -e $holder ]] || continue
        name=$(cat "$holder/dm/name" 2> /dev/null || basename "$holder")
        [[ $name == "$CRYPT_NAME" ]] || in_use+=("$name")
    done
    if (( ${#in_use[@]} )); then
        die "$DISK is in use by ${in_use[*]} (an unlocked LUKS volume, LVM or RAID). Close it first (cryptsetup close, vgchange -an or mdadm --stop), or reboot the live ISO."
    fi
}

# Sets KEYMAP_LOADED: whether the keymap is loaded for the passwords below
ask_keymap() {
    info "The console keymap is also used at the disk passphrase prompt during boot."
    info "us-acentos = US international with dead keys ( ' then e = é, ' then space = ' )."
    while :; do
        ask KEYMAP "Console keymap" "us-acentos"
        if find /usr/share/kbd/keymaps -name "$KEYMAP.map.gz" 2> /dev/null | grep -q .; then break; fi
        warn "Keymap '$KEYMAP' not found (list them with: localectl list-keymaps or ls /usr/share/kbd/keymaps/i386/*)"
        KEYMAP=""
    done
    # Same layout for the passwords below as at the boot prompt
    if [[ $TEST_IN_CONTAINER != yes ]] && loadkeys "$KEYMAP" 2> /dev/null; then
        ok "Loaded keymap $KEYMAP for the rest of the installation"
        KEYMAP_LOADED=yes
    else
        KEYMAP_LOADED=no
    fi
}

ask_locale() {
    while :; do
        ask LOCALE "System language (locale)" "en_US.UTF-8"
        if grep -q "^$LOCALE " /usr/share/i18n/SUPPORTED 2> /dev/null; then break; fi
        warn "Locale '$LOCALE' not found in /usr/share/i18n/SUPPORTED (example: en_US.UTF-8, nl_NL.UTF-8)"
        LOCALE=""
    done
}

ask_timezone() {
    while :; do
        ask TIMEZONE "Time zone" "Europe/Amsterdam"
        if [[ -f /usr/share/zoneinfo/$TIMEZONE ]]; then break; fi
        warn "Time zone '$TIMEZONE' not found (examples: Europe/Amsterdam, America/New_York, UTC)"
        TIMEZONE=""
    done
}

ask_host_name() {
    while :; do
        ask HOST_NAME "Host name" "artix"
        if [[ $HOST_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then break; fi
        warn "Use letters, digits and hyphens only (max 63 characters)."
        HOST_NAME=""
    done
}

ask_user() {
    while :; do
        ask USER_NAME "User name"
        if [[ $USER_NAME =~ ^[a-z][a-z0-9_-]{0,31}$ ]] && [[ $USER_NAME != root ]]; then break; fi
        warn "Use lower-case letters, digits, '-' and '_', starting with a letter (not 'root')."
        USER_NAME=""
    done
    ask_password USER_PASSWORD "Password for $USER_NAME"
}

ask_root() {
    info ""
    info "If you don't enable root, the root account is locked and you use sudo."
    ask_yes_no ENABLE_ROOT "Enable the root account (set a root password)?" n
    if [[ $ENABLE_ROOT == yes ]]; then
        ask_password ROOT_PASSWORD "Root password"
    fi
}

ask_luks_password() {
    info "This passphrase unlocks the disk at every boot. Without it your data is gone."
    ask_password LUKS_PASSWORD "Disk encryption passphrase" 8
    if [[ $KEYMAP_LOADED == no ]] && [[ $KEYMAP == *acentos* || $KEYMAP == *intl* ]] \
            && [[ $LUKS_PASSWORD =~ [\'\"\`~^] ]]; then
        warn "Your passphrase contains ' \" \` ~ or ^. With the dead-key keymap $KEYMAP"
        warn "you must press space after those characters at the boot prompt."
    fi
}

ask_swap_size() {
    # The system needs at least 16 GiB besides the swap file
    local max_swap=$(( DISK_SIZE / 1024 ** 3 - 16 ))
    info "A swap file in the encrypted root protects against out-of-memory crashes."
    while :; do
        ask SWAP_SIZE "Swap file size in GiB (0 = no swap)" "4"
        # No leading zeros: bash reads 08 as an invalid octal number
        if [[ $SWAP_SIZE =~ ^(0|[1-9][0-9]*)$ ]] && (( SWAP_SIZE <= max_swap )); then break; fi
        warn "Enter a whole number from 0 to $max_swap."
        SWAP_SIZE=""
    done
}

ask_lts_kernel() {
    info ""
    info "The LTS kernel is a second entry in the GRUB menu, which you can"
    info "use when an update of the normal kernel doesn't boot."
    ask_yes_no INSTALL_LTS "Install the linux-lts fallback kernel?" y
}

ask_timeshift() {
    info ""
    info "Timeshift takes a snapshot of the system (not your home folder) every day"
    info "and before every pacman upgrade, so you can roll back an update that breaks"
    info "something. The snapshots are kept on the same disk, in /timeshift."
    # The first snapshot is as big as the system, and timeshift doesn't check
    # the free space for it
    if (( DISK_SIZE >= 64 * 1024 ** 3 )); then
        ask_yes_no ENABLE_TIMESHIFT "Set up Timeshift snapshots?" y
    else
        info "The first snapshot is as big as the system, so on this disk it can fill it up."
        ask_yes_no ENABLE_TIMESHIFT "Set up Timeshift snapshots?" n
    fi
}

ask_nvidia_driver() {
    if (( ${#NVIDIA_PKGS[@]} > 0 )); then
        info ""
        info "Without NVIDIA's proprietary driver the open nouveau driver is used. It"
        info "works, but is much slower and can't manage power on most cards."
        ask_yes_no INSTALL_NVIDIA "Install NVIDIA's driver (${NVIDIA_PKGS[0]})?" y
    else
        if [[ -n $NVIDIA_ID ]]; then
            warn "NVIDIA GPU $NVIDIA_ID is Kepler or older; no packaged driver supports it, so nouveau is used"
        fi
        INSTALL_NVIDIA=no
    fi
}

ask_audio_driver() {
    if [[ $INTEL_AUDIO_DSP != yes || $AUDIO_DRIVER == snd_hda_intel ]]; then
        AUDIO_LEGACY_HDA=no
        return 0
    fi
    info ""
    info "The Intel sound chip has a DSP, so Linux uses the SOF driver for it. On some"
    info "laptops SOF only gives a 'Dummy Output'. The older HDA driver then works,"
    info "but without the built-in digital microphones."
    if [[ $SOF_FAILED == yes ]]; then
        info "SOF didn't start on this live system, so the older driver is the default."
        ask_yes_no AUDIO_LEGACY_HDA "Use the older HDA driver instead of SOF?" y
    else
        info "Not sure? Answer n; the summary shows how to switch later."
        ask_yes_no AUDIO_LEGACY_HDA "Use the older HDA driver instead of SOF?" n
    fi
}

ask_aur() {
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
}

ask_desktop() {
    local desktop_preset=$DESKTOP
    info ""
    info "A desktop environment with its login screen, or my sway or dwm setup"
    info "(SARBS/DARBS on GitHub). Without one the system boots to a text console."
    while :; do
        ask_choice DESKTOP "Desktop" none \
            "none:no desktop, boots to a TTY" \
            "plasma:KDE Plasma (SDDM login screen)" \
            "cinnamon:Cinnamon (LightDM login screen)" \
            "xfce:XFCE (LightDM login screen)" \
            "lxqt:LXQt (LightDM login screen)" \
            "sway:sway, my Wayland setup (SARBS)" \
            "dwm:dwm, my X11 setup (DARBS)"
        [[ $DESKTOP == sway && $INSTALL_NVIDIA == yes ]] || break
        # sway refuses to start when NVIDIA's driver is loaded
        warn "sway doesn't support NVIDIA's driver and won't start with it."
        info "Without it, the open nouveau driver is used for the NVIDIA GPU$([[ $OTHER_GPU == yes ]] && echo ", and sway runs on the Intel/AMD GPU")."
        ask_yes_no SWAY_WITHOUT_NVIDIA "Install sway without NVIDIA's driver?" y
        if [[ $SWAY_WITHOUT_NVIDIA == yes ]]; then
            INSTALL_NVIDIA=no
            break
        fi
        [[ -z $desktop_preset ]] || die "DESKTOP=sway needs INSTALL_NVIDIA=no or SWAY_WITHOUT_NVIDIA=yes: sway doesn't support NVIDIA's driver"
        DESKTOP="" SWAY_WITHOUT_NVIDIA=""
        info "Choose another desktop then."
    done
    if [[ $DESKTOP == sway || $DESKTOP == dwm ]]; then
        ask_choice DESKTOP_LOGIN "Start $DESKTOP" dm \
            "tty:automatically when you log in on TTY1" \
            "dm:from a minimal graphical login screen (LightDM)" \
            "none:neither, start it yourself"
    else
        DESKTOP_LOGIN=""
    fi
}

# --- 3. Confirmation ---

show_overview() {
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
    Timeshift       : $ENABLE_TIMESHIFT
    NVIDIA driver   : $([[ $INSTALL_NVIDIA == yes ]] && echo "${NVIDIA_PKGS[*]}" || echo no)
    Sound driver    : $([[ $AUDIO_LEGACY_HDA == yes ]] && echo "older HDA driver (no SOF)" || echo default)
    AUR (yay)       : $ENABLE_AUR
    Desktop         : $(desktop_label "$DESKTOP")
    Firewall        : ufw (deny incoming, allow outgoing)
EOF
}

confirm_wipe() {
    local answer
    if [[ $CONFIRM_WIPE == yes ]]; then return 0; fi
    echo
    read -r -p "Type ERASE to wipe $DISK and install: " answer
    [[ $answer == ERASE ]] || die "Aborted, nothing was changed."
}

# --- 4. Clock and keyring on the live system ---

# A wrong clock breaks PGP signatures and TLS
check_clock() {
    local web_date web_epoch skew
    if ! web_date=$(curl -fsSI --max-time 10 https://artixlinux.org | awk -F': ' 'tolower($1) == "date" {print $2}' | tr -d '\r') \
            || [[ -z $web_date ]]; then
        warn "Couldn't check the clock. If package signatures fail, set it with: date -s 'YYYY-MM-DD HH:MM'"
        return 0
    fi
    web_epoch=$(date -d "$web_date" +%s)
    skew=$(( $(date +%s) - web_epoch ))
    if (( ${skew#-} <= 120 )); then
        ok "Clock is correct ($(date -u '+%F %T') UTC)"
    elif [[ $TEST_IN_CONTAINER == yes ]]; then
        warn "Clock is off by ${skew}s; not changing it in a test container"
    else
        date -s "@$web_epoch" > /dev/null
        ok "Clock was off by ${skew}s, set to $(date -u '+%F %T') UTC"
    fi
}

init_live_keyring() {
    pacman-key --init
    pacman-key --populate artix
    pacman -Sy --needed --noconfirm artix-keyring
    ok "Keyring ready"
}

# --- 5. Partitioning and encryption ---

partition_disk() {
    # Leftovers from an earlier, failed run
    if mountpoint -q "$MNT"; then
        swapoff "$MNT/swapfile" 2> /dev/null || true
        umount -R "$MNT"
    fi
    if [[ -e /dev/mapper/$CRYPT_NAME ]]; then
        cryptsetup close "$CRYPT_NAME" || die "/dev/mapper/$CRYPT_NAME is still in use; reboot the live ISO and try again"
        info "Closed $CRYPT_NAME left over from an earlier attempt"
    fi
    wipefs -af "$DISK" > /dev/null
    sfdisk -q --wipe always "$DISK" << 'EOF'
label: gpt
size=1GiB, type=U, name=EFI
type=L, name=ARTIX
EOF
    wait_for_partitions "$DISK"
    ok "Created $PART_EFI (EFI) and $PART_ROOT (LUKS)"
}

# Sets LUKS_UUID
encrypt_root() {
    # shellcheck disable=SC2086  # LUKS_FORMAT_OPTS is intentionally split
    printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 --batch-mode \
        $LUKS_FORMAT_OPTS --key-file=- "$PART_ROOT"
    printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file=- "$PART_ROOT" "$CRYPT_NAME"
    LUKS_UUID=$(cryptsetup luksUUID "$PART_ROOT")
    ok "Encrypted, LUKS UUID $LUKS_UUID"
}

# Sets ROOT_FS_UUID
create_file_systems() {
    mkfs.fat -F 32 -n EFI "$PART_EFI" > /dev/null
    mkfs.ext4 -q -F -L ROOT "/dev/mapper/$CRYPT_NAME"
    mount "/dev/mapper/$CRYPT_NAME" "$MNT"
    mkdir -p "$MNT/boot"
    mount "$PART_EFI" "$MNT/boot"
    ROOT_FS_UUID=$(blkid -s UUID -o value "/dev/mapper/$CRYPT_NAME")
    if [[ -n $PACMAN_CACHE_DIR ]]; then
        mkdir -p "$MNT/var/cache/pacman/pkg"
        mount --bind "$PACMAN_CACHE_DIR" "$MNT/var/cache/pacman/pkg"
    fi
    ok "Mounted the new system on $MNT"
}

create_swap_file() {
    fallocate -l "${SWAP_SIZE}G" "$MNT/swapfile"
    chmod 600 "$MNT/swapfile"
    mkswap -q "$MNT/swapfile"
    ok "Swap file created"
}

# --- 6. Base system ---

install_base_system() {
    local packages=(
        base base-devel dinit elogind-dinit
        linux linux-headers linux-firmware sof-firmware
        cryptsetup grub efibootmgr dosfstools e2fsprogs
        networkmanager networkmanager-dinit
        chrony chrony-dinit
        ufw ufw-dinit
        sudo git vim man-db bash-completion
        # pacdiff, to merge the .pacnew files an upgrade leaves in /etc
        pacman-contrib
    )
    # No mesa, Vulkan or VA-API: the desktop step installs those. The NVIDIA
    # module needs its own userspace, nvidia-utils, which pulls in mesa.
    case $CPU_VENDOR in
        intel) packages+=(intel-ucode) ;;
        amd)   packages+=(amd-ucode) ;;
        *)     packages+=(intel-ucode amd-ucode) ;;
    esac
    if [[ $INSTALL_LTS == yes ]]; then packages+=(linux-lts linux-lts-headers); fi
    if [[ $INSTALL_NVIDIA == yes ]]; then packages+=("${NVIDIA_PKGS[@]}"); fi

    # -K: separate keyring for the new system
    basestrap -K "$MNT" "${packages[@]}"
    # Make sure the new system gets the ranked list, not the package's stock one
    cp /etc/pacman.d/mirrorlist "$MNT/etc/pacman.d/mirrorlist"
    if [[ -e /etc/pacman.d/mirrorlist.stock ]]; then
        cp /etc/pacman.d/mirrorlist.stock "$MNT/etc/pacman.d/mirrorlist.stock"
    fi
    ok "Base system installed"
}

# Not fstabgen: it would also add the live system's zram swap
write_fstab() {
    local efi_uuid
    efi_uuid=$(blkid -s UUID -o value "$PART_EFI")
    [[ -n $ROOT_FS_UUID && -n $efi_uuid ]] || die "Couldn't read the file system UUIDs"
    {
        printf '# <file system>\t<dir>\t<type>\t<options>\t<dump>\t<pass>\n'
        printf '# /dev/mapper/%s (LUKS2 on %s)\n' "$CRYPT_NAME" "$PART_ROOT"
        printf 'UUID=%s\t/\text4\trw,relatime\t0 1\n\n' "$ROOT_FS_UUID"
        printf '# %s (EFI system partition)\n' "$PART_EFI"
        printf 'UUID=%s\t/boot\tvfat\trw,relatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro\t0 2\n' "$efi_uuid"
        if (( SWAP_SIZE > 0 )); then
            printf '\n/swapfile\tnone\tswap\tdefaults\t0 0\n'
        fi
    } >> "$MNT/etc/fstab"
    ok "fstab written"
}

# --- 7. System configuration ---

init_new_keyring() {
    in_chroot pacman-key --init
    in_chroot pacman-key --populate artix
    ok "Keyring initialised and populated"
}

set_time_zone() {
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
    if [[ $TEST_IN_CONTAINER == yes ]]; then
        info "Not setting the hardware clock in a test container"
    else
        in_chroot hwclock --systohc || warn "Couldn't set the hardware clock"
    fi
}

# The chosen locale, and en_US.UTF-8 as a fallback
set_locale() {
    local loc charset
    for loc in "$LOCALE" en_US.UTF-8; do
        charset=$(grep -m1 "^$loc " /usr/share/i18n/SUPPORTED | awk '{print $2}')
        if ! grep -q "^$loc $charset" "$MNT/etc/locale.gen"; then
            echo "$loc $charset" >> "$MNT/etc/locale.gen"
        fi
    done
    in_chroot locale-gen
    echo "LANG=$LOCALE" > "$MNT/etc/locale.conf"
}

# The console keymap, and the same layout in X. Sets X11_LAYOUT and
# X11_VARIANT (empty when there is no X layout for the keymap).
set_keyboard() {
    echo "KEYMAP=$KEYMAP" > "$MNT/etc/vconsole.conf"
    read -r X11_LAYOUT X11_VARIANT <<< "$(x11_layout "$KEYMAP")" || true
    if [[ -z $X11_LAYOUT ]]; then return 0; fi
    mkdir -p "$MNT/etc/X11/xorg.conf.d"
    {
        echo '# The keyboard layout in X, matching the console keymap (artix-install.sh)'
        echo 'Section "InputClass"'
        echo '    Identifier "system-keyboard"'
        echo '    MatchIsKeyboard "on"'
        echo "    Option \"XkbLayout\" \"$X11_LAYOUT\""
        if [[ -n $X11_VARIANT ]]; then echo "    Option \"XkbVariant\" \"$X11_VARIANT\""; fi
        echo 'EndSection'
    } > "$MNT/etc/X11/xorg.conf.d/00-keyboard.conf"
}

set_host_name() {
    echo "$HOST_NAME" > "$MNT/etc/hostname"
    cat > "$MNT/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST_NAME.localdomain $HOST_NAME
EOF
}

# keyboard and keymap before encrypt, for the passphrase prompt. Only the
# hooks this mkinitcpio has.
build_initramfs() {
    local hooks=() h
    for h in base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck; do
        # kms would put nouveau in the initramfs, before nvidia-utils' blacklist applies
        [[ $h == kms && $INSTALL_NVIDIA == yes ]] && continue
        [[ -e $MNT/usr/lib/initcpio/install/$h ]] && hooks+=("$h")
    done
    sed -i "s/^HOOKS=.*/HOOKS=(${hooks[*]})/" "$MNT/etc/mkinitcpio.conf"
    grep -q '^HOOKS=(.*encrypt' "$MNT/etc/mkinitcpio.conf" || die "Couldn't set HOOKS in mkinitcpio.conf"
    info "HOOKS=(${hooks[*]})"
    in_chroot mkinitcpio -P
    ok "Initramfs built"
}

install_grub() {
    local cmdline="cryptdevice=UUID=$LUKS_UUID:$CRYPT_NAME root=/dev/mapper/$CRYPT_NAME"
    if [[ -n $EXTRA_KERNEL_PARAMS ]]; then cmdline+=" $EXTRA_KERNEL_PARAMS"; fi
    grub_set GRUB_CMDLINE_LINUX "\"$cmdline\""
    grub_set GRUB_DEFAULT saved
    grub_set GRUB_SAVEDEFAULT true
    # Otherwise grub-mkconfig puts linux-lts first
    grub_set GRUB_TOP_LEVEL '"/boot/vmlinuz-linux"'
    # Just the kernels and UEFI settings: no submenu, and no entry for every
    # firmware boot option (the install USB, network boot...)
    grub_set GRUB_DISABLE_SUBMENU y
    grub_set GRUB_DISABLE_BOOTNEXT true

    if [[ $BOOT_MODE == UEFI && $TEST_IN_CONTAINER != yes ]]; then
        in_chroot grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=artix
    else
        in_chroot grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=artix --no-nvram
    fi
    # Fallback path \EFI\BOOT\BOOTX64.EFI, for firmware that loses its boot entries
    in_chroot grub-install --target=x86_64-efi --efi-directory=/boot --removable
    in_chroot grub-mkconfig -o /boot/grub/grub.cfg
    grep -q "cryptdevice=UUID=$LUKS_UUID" "$MNT/boot/grub/grub.cfg" || die "grub.cfg doesn't contain the cryptdevice option"
    ok "GRUB installed (artix entry + fallback path)"
}

create_users() {
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
}

use_legacy_hda_driver() {
    cat > "$MNT/etc/modprobe.d/legacy-hda.conf" << 'EOF'
# The older HDA driver instead of SOF (artix-install.sh). Delete this file
# and reboot to use SOF again.
options snd-intel-dspcfg dsp_driver=1
EOF
    ok "/etc/modprobe.d/legacy-hda.conf"
}

# NetworkManager, time sync and the firewall: deny incoming, allow outgoing
enable_base_services() {
    enable_service NetworkManager
    if [[ -e $MNT/etc/dinit.d/chronyd ]]; then enable_service chronyd; else enable_service chrony; fi

    sed -i 's/^ENABLED=.*/ENABLED=yes/' "$MNT/etc/ufw/ufw.conf"
    sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/;
            s/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/;
            s/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' "$MNT/etc/default/ufw"
    enable_service ufw
    ok "Enabled: ${ENABLED_SERVICES[*]}"
}

# DKMS builds the module while the packages install; check it did for every
# kernel. On a hybrid laptop, add prime-run and let the GPU power off when
# idle. Suspend needs nothing: the driver saves the video memory through
# kernel suspend notifiers, and nvidia-utils has an elogind hook for resume.
check_nvidia_driver() {
    local kdir
    for kdir in "$MNT"/usr/lib/modules/*/; do
        [[ -e $kdir/vmlinuz ]] || continue
        [[ -n $(find "$kdir" -name 'nvidia.ko*' -print -quit) ]] \
            || die "The NVIDIA module wasn't built for kernel $(basename "$kdir"); see: artix-chroot $MNT dkms status"
    done
    if [[ $OTHER_GPU == yes ]]; then
        # What Arch's nvidia-prime package contains; Artix doesn't have it
        cat > "$MNT/usr/local/bin/prime-run" << 'EOF'
#!/bin/sh
export __NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only __GLX_VENDOR_LIBRARY_NAME=nvidia
exec "$@"
EOF
        chmod 755 "$MNT/usr/local/bin/prime-run"
        # The driver's default only powers off Ampere and newer laptop GPUs
        cat > "$MNT/etc/modprobe.d/nvidia-power.conf" << 'EOF'
# Power off the NVIDIA GPU when it is idle (artix-install.sh)
options nvidia NVreg_DynamicPowerManagement=0x02
EOF
        # Runtime PM for the GPU's PCI device, from NVIDIA's README
        mkdir -p "$MNT/etc/udev/rules.d"
        cat > "$MNT/etc/udev/rules.d/80-nvidia-pm.rules" << 'EOF'
# Runtime power management for the NVIDIA GPU (artix-install.sh)
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", TEST=="power/control", ATTR{power/control}="on"
EOF
    fi
    ok "${NVIDIA_PKGS[0]} built for every kernel$([[ $OTHER_GPU == yes ]] && echo "; powers off when idle; run a program on the NVIDIA GPU with: prime-run <program>")"
}

# --- 8-10. Optional: AUR helper, desktop, Timeshift ---

# Builds yay as the user, like makepkg wants, and removes go again unless the
# user had it already
install_yay() {
    local had_go=no yay_pkg
    # Not in /tmp: artix-chroot mounts a fresh tmpfs there for every command
    local build_dir=/home/$USER_NAME/.cache/yay-build
    if in_chroot pacman -Q go &> /dev/null; then had_go=yes; fi
    chroot_pacman -S --needed --noconfirm git base-devel go
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
}

install_desktop() {
    case $DESKTOP in
        plasma|cinnamon|xfce|lxqt) install_desktop_environment ;;
        sway|dwm)                  install_rice ;;
    esac
}

# Rsync snapshots in /timeshift: daily and before every pacman upgrade. Run it
# after every other pacman run, so the hook doesn't take snapshots during the
# installation.
setup_timeshift() {
    # timeshift depends on cronie, which runs its scheduled snapshots
    chroot_pacman -S --needed --noconfirm timeshift cronie cronie-dinit
    enable_service cronie
    # What timeshift's setup wizard writes: rsync snapshots of the root file
    # system in /timeshift, without the home folders. Restores skip them too,
    # so they never roll back anyone's files, also of users added later. Plus
    # the package cache, which pacman can download again, and pacman's lock:
    # the hook snapshots while pacman runs, and a restored lock would keep
    # pacman from running afterwards.
    cat > "$MNT/etc/timeshift/timeshift.json" << EOF
{
  "backup_device_uuid" : "$ROOT_FS_UUID",
  "parent_device_uuid" : "$LUKS_UUID",
  "do_first_run" : "false",
  "btrfs_mode" : "false",
  "include_btrfs_home_for_backup" : "false",
  "include_btrfs_home_for_restore" : "false",
  "stop_cron_emails" : "true",
  "schedule_monthly" : "false",
  "schedule_weekly" : "false",
  "schedule_daily" : "true",
  "schedule_hourly" : "false",
  "schedule_boot" : "false",
  "count_monthly" : "2",
  "count_weekly" : "3",
  "count_daily" : "5",
  "count_hourly" : "6",
  "count_boot" : "5",
  "exclude" : [
    "/root/**",
    "/home/**",
    "/var/cache/pacman/pkg/**",
    "/var/lib/pacman/db.lck"
  ],
  "exclude-apps" : [
  ]
}
EOF
    # The cron job timeshift writes itself once it has run: every hour it
    # checks whether the daily snapshot is due
    cat > "$MNT/etc/cron.d/timeshift-hourly" << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=""

0 * * * * root timeshift --check --scripted
EOF
    # Tagged daily, so they count towards the daily snapshots and timeshift
    # removes them after 5 days. No --comments: timeshift never removes a
    # snapshot with a comment. When the snapshot fails (a full disk), pacman
    # warns and upgrades anyway.
    mkdir -p "$MNT/etc/pacman.d/hooks"
    cat > "$MNT/etc/pacman.d/hooks/00-timeshift.hook" << 'EOF'
# Snapshot before upgrades (artix-install.sh). Remove this file to stop them.
[Trigger]
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Taking a Timeshift snapshot before the upgrade...
When = PreTransaction
Exec = /usr/bin/timeshift --create --scripted --tags D
EOF
    ok "Timeshift: a daily snapshot and one before every pacman upgrade, kept for 5 days"
}

# --- 11. Summary ---

summary_nvidia_line() {
    if [[ $INSTALL_NVIDIA == yes ]]; then
        echo "${NVIDIA_PKGS[*]}$([[ $OTHER_GPU == yes ]] && echo "; the GPU powers off when idle (\`/etc/modprobe.d/nvidia-power.conf\`); run a program on it with \`prime-run <program>\`")"
    elif [[ -n $NVIDIA_ID ]]; then
        echo "not installed, the open nouveau driver is used"
    else
        echo "no NVIDIA GPU"
    fi
}

summary_sound_line() {
    if [[ $AUDIO_LEGACY_HDA == yes ]]; then
        echo "the older HDA driver instead of SOF (\`/etc/modprobe.d/legacy-hda.conf\`), see Sound"
    elif [[ $INTEL_AUDIO_DSP == yes ]]; then
        echo "SOF, see Sound"
    else
        echo "HDA"
    fi
}

# Step 3 of the next steps, and step 4 without a desktop
summary_login_steps() {
    case $DESKTOP in
        none)
            echo "Log in as $USER_NAME. Connect to Wi-Fi with \`nmtui\`."
            echo "4. Install a desktop, for example DARBS: $DARBS_URL or SARBS: $SARBS_URL" ;;
        plasma|cinnamon|xfce|lxqt)
            echo "Log in as $USER_NAME on the login screen. Connect to Wi-Fi with the network icon in the panel." ;;
        sway|dwm)
            case $DESKTOP_LOGIN in
                tty)  printf '%s' "Log in as $USER_NAME on TTY1; $DESKTOP starts by itself." ;;
                dm)   printf '%s' "Log in as $USER_NAME on the login screen ($DESKTOP session)." ;;
                none) printf '%s' "Log in as $USER_NAME and start $DESKTOP (see the README in ~/$(rice_name "$DESKTOP"))." ;;
            esac
            echo " Connect to Wi-Fi with the network icon in the bar, or \`nmtui\`." ;;
    esac
}

summary_sound_section() {
    if [[ $AUDIO_LEGACY_HDA == yes ]]; then
        cat << 'EOF'

## Sound

The older HDA driver is used instead of SOF, set in /etc/modprobe.d/legacy-hda.conf.
The built-in digital microphones don't work with it. To use SOF again, run
`sudo rm /etc/modprobe.d/legacy-hda.conf` (with DARBS: `sound-fix sof`) and reboot.
EOF
    else
        cat << 'EOF'

## Sound

The SOF driver is used. If you only get a "Dummy Output" (DARBS's bar shows
`vol dummy`), switch to the older HDA driver; the built-in digital microphones
don't work with it. With DARBS, run `sound-fix`. Without it, run
`echo 'options snd-intel-dspcfg dsp_driver=1' | sudo tee /etc/modprobe.d/legacy-hda.conf`.
Then reboot.
EOF
    fi
}

summary_snapshots_section() {
    cat << 'EOF'

## Snapshots

Timeshift takes a snapshot of the system in /timeshift once a day (the first
within an hour after the first boot) and before every `pacman -Syu`. It removes
them after 5 days, but always keeps the 5 newest. Files that didn't change are
shared between snapshots, so each one only takes the space of what changed.
Your home folder is not in them: back it up separately. The snapshots are on
the same disk, so they don't help when the disk itself fails.

- List them: `sudo timeshift --list`
- Take one now: `sudo timeshift --create --comments "before trying X"`. Timeshift
  never removes these itself: delete them with `sudo timeshift --delete`.
- Stop the snapshots before upgrades: `sudo rm /etc/pacman.d/hooks/00-timeshift.hook`

To roll back, pick a snapshot, restore it and restart. Only the system files go
back, not your home folder:

    sudo timeshift --list
    sudo timeshift --restore --snapshot '2026-10-27_09-00-01' --skip-grub
    sudo reboot

Press Enter for the default answers and y to confirm. Keep --skip-grub: the
snapshot already has the boot menu, and Timeshift's own GRUB install doesn't
match this one. Timeshift's own restart doesn't work on Artix (its reboot -f
fails), so restart yourself when it says "Restore completed".

- The desktop still works: run the commands in a terminal, or use the Timeshift
  app and turn off reinstalling GRUB under Bootloader Options.
- The desktop doesn't start: press Ctrl+Alt+F2, log in and run the commands there.
EOF
    if [[ $INSTALL_LTS == yes ]]; then
        echo "- The system doesn't boot after a kernel update: pick linux-lts in the GRUB menu, then restore."
    fi
}

# The installation summary in Markdown, with what to do next
print_summary() {
    local kernel_pkgs=(linux) kernels
    if [[ $INSTALL_LTS == yes ]]; then kernel_pkgs+=(linux-lts); fi
    kernels=$(in_chroot pacman -Q "${kernel_pkgs[@]}" | awk '{printf "%s %s  ", $1, $2}')
    # The backticks are escaped so the heredoc doesn't run them
    cat << EOF
# Artix Linux installation summary

Installed on $(date '+%F %R %Z') with artix-install.sh $SCRIPT_VERSION.

## Next steps

1. Reboot and remove the USB stick.
2. Type the disk passphrase at "Enter passphrase for $PART_ROOT".
3. $(summary_login_steps)

## Hardware

- Boot mode: $BOOT_MODE
- CPU: $CPU_VENDOR, with its microcode
- NVIDIA driver: $(summary_nvidia_line)
- Sound driver: $(summary_sound_line)

## Disk ($DISK, $(numfmt --to=iec "$DISK_SIZE"))

- $PART_EFI: EFI system partition, FAT32, mounted at /boot (not encrypted)
- $PART_ROOT: LUKS2 (UUID $LUKS_UUID), opened as /dev/mapper/$CRYPT_NAME: ext4, mounted at / (UUID $ROOT_FS_UUID)
- Swap: $([[ $SWAP_SIZE == 0 ]] && echo none || echo "/swapfile, $SWAP_SIZE GiB, inside the encrypted root")

## System

- Host name: $HOST_NAME
- Kernels: $kernels
- Fallback kernel: $([[ $INSTALL_LTS == yes ]] && echo "linux-lts, the second entry in the GRUB menu" || echo none)
- Snapshots: $([[ $ENABLE_TIMESHIFT == yes ]] && echo "Timeshift, see Snapshots" || echo none)
- Bootloader: GRUB, EFI entry "artix" and the fallback path \\EFI\\BOOT\\BOOTX64.EFI
- Init: dinit; enabled services (/etc/dinit.d/boot.d): ${ENABLED_SERVICES[*]}
- Locale: $LOCALE
- Console keymap: $KEYMAP, also used at the passphrase prompt
- Keyboard in X: $(if [[ -n $X11_LAYOUT ]]; then echo "$X11_LAYOUT${X11_VARIANT:+ ($X11_VARIANT)}, in /etc/X11/xorg.conf.d/00-keyboard.conf"; else echo "not set (no X layout known for $KEYMAP); set it in /etc/X11/xorg.conf.d/00-keyboard.conf"; fi)
- Time zone: $TIMEZONE
- Mirrors: ranked at install time; the stock list is /etc/pacman.d/mirrorlist.stock
- Desktop: $(desktop_label "$DESKTOP")$([[ $DESKTOP == sway || $DESKTOP == dwm ]] && echo "; the rice is in ~/$(rice_name "$DESKTOP")")
- AUR: $([[ $ENABLE_AUR == yes ]] && echo "yay installed. AUR packages are unofficial, review their PKGBUILDs ($AUR_WIKI)" || echo "not enabled")

## Accounts

- User: $USER_NAME, groups: $(in_chroot id -nG "$USER_NAME")
- sudo: \`%wheel ALL=(ALL:ALL) ALL\` in /etc/sudoers.d/10-wheel
- root: $([[ $ENABLE_ROOT == yes ]] && echo "enabled, password set" || echo "locked, use sudo")

## Security

- Disk encryption: LUKS2, the initramfs asks for the passphrase at boot
- Firewall: ufw, enabled at boot: deny incoming, allow outgoing.
  Status: \`sudo ufw status verbose\`. Allow ssh: \`sudo ufw allow ssh\`.
  A GUI: $([[ $DESKTOP == plasma ]] && echo "System Settings > Firewall" || echo "\`sudo pacman -S gufw\`")
- Keyring: initialised and populated (artix-keyring)

## Updates

Update with \`sudo pacman -Syu\`, and check the Artix news (https://artixlinux.org/news.php)
first. When an upgrade has a new version of a config file you changed, pacman
saves it next to yours as .pacnew. Merge those right after the upgrade with
\`sudo pacdiff\`, before you reboot: an unmerged file in /etc/pam.d can stop
turnstile, and with it PipeWire, from starting at login.
EOF
    if [[ $INTEL_AUDIO_DSP == yes ]]; then summary_sound_section; fi
    if [[ $ENABLE_TIMESHIFT == yes ]]; then summary_snapshots_section; fi
    printf '\nThe full installation log: /var/log/artix-install/install.log\n'
}

# Shows the summary, and saves it in the user's home folder when they want
save_summary() {
    local summary=$1 file=/home/$USER_NAME/artix-install-summary.md
    printf '\n%s\n\n' "$summary"
    ask_yes_no SAVE_SUMMARY "Save this summary as $file?" y
    if [[ $SAVE_SUMMARY == yes ]]; then
        printf '%s\n' "$summary" > "$MNT$file"
        in_chroot chown "$USER_NAME:" "$file"
        chmod 644 "$MNT$file"
        ok "Summary saved as $file"
    fi
}

save_install_log() {
    local log_dir=$MNT/var/log/artix-install
    mkdir -p "$log_dir"
    cp "$LOG" "$log_dir/install.log"
    chmod 600 "$log_dir/install.log"
}

unmount_new_system() {
    sync
    stop_chroot_processes
    umount -R "$MNT"
    cryptsetup close "$CRYPT_NAME"
    ok "Unmounted the new system and closed the encrypted disk"
}

offer_reboot() {
    ask_yes_no REBOOT_WHEN_DONE "Reboot now?" y
    if [[ $REBOOT_WHEN_DONE == yes ]]; then
        info "Rebooting, remove the USB stick when the screen goes dark."
        sleep 3
        reboot
    fi
}

main() {
    local summary
    parse_args "$@"
    load_settings
    (( EUID == 0 )) || die "Run this script as root (on the live ISO you are root already)."
    ENABLED_SERVICES=()
    start_logging
    print_banner

    step "Checking the live environment"
    check_boot_mode
    check_live_system
    check_dm_crypt
    check_internet
    detect_hardware

    step "Target disk"
    ask_disk
    check_disk
    step "Keyboard, language and time zone"
    ask_keymap
    ask_locale
    ask_timezone
    step "Host name and users"
    ask_host_name
    ask_user
    ask_root
    step "Disk encryption"
    ask_luks_password
    step "Extras"
    ask_swap_size
    ask_lts_kernel
    ask_timeshift
    ask_nvidia_driver
    ask_audio_driver
    ask_aur
    ask_desktop

    step "Overview"
    show_overview
    confirm_wipe

    step "Checking the clock"
    check_clock
    step "Initialising the pacman keyring"
    init_live_keyring
    step "Ranking the package mirrors"
    rank_mirrors

    step "Partitioning $DISK"
    partition_disk
    step "Encrypting $PART_ROOT (LUKS2)"
    encrypt_root
    step "Creating file systems"
    create_file_systems
    if (( SWAP_SIZE > 0 )); then
        step "Creating a ${SWAP_SIZE} GiB swap file"
        create_swap_file
    fi

    step "Installing the base system (this takes a while)"
    install_base_system
    step "Generating /etc/fstab"
    write_fstab

    step "Configuring the keyring in the new system"
    init_new_keyring
    step "Time zone, locale, keymap and host name"
    set_time_zone
    set_locale
    set_keyboard
    set_host_name
    ok "$TIMEZONE, $LOCALE, $KEYMAP, $HOST_NAME"
    step "Initramfs with the encrypt hook"
    build_initramfs
    step "Installing GRUB"
    install_grub
    step "Users and sudo"
    create_users
    if [[ $AUDIO_LEGACY_HDA == yes ]]; then
        step "Sound: older HDA driver"
        use_legacy_hda_driver
    fi
    step "Services"
    enable_base_services
    if [[ $INSTALL_NVIDIA == yes ]]; then
        step "NVIDIA driver"
        check_nvidia_driver
    fi

    if [[ $ENABLE_AUR == yes ]]; then
        step "Installing yay (AUR helper)"
        install_yay
    fi
    if [[ $DESKTOP != none ]]; then
        step "Installing $(desktop_label "$DESKTOP") (this takes a while)"
        install_desktop
    fi
    if [[ $ENABLE_TIMESHIFT == yes ]]; then
        step "Setting up Timeshift snapshots"
        setup_timeshift
    fi

    step "Finishing"
    summary=$(print_summary)
    save_summary "$summary"
    save_install_log
    unmount_new_system
    offer_reboot
}

# Sourced (the tests run the desktop step on a copy of an installed base
# system): only the functions
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
