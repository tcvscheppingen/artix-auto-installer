#!/usr/bin/env bash
# Runs in the booted test system (as root via sudo) during the QEMU boot test.
pass=0 fail=0
check() {
    local name=$1; shift
    if "$@" > /dev/null 2>&1; then echo "PASS  $name"; pass=$((pass + 1))
    else echo "FAIL  $name"; fail=$((fail + 1)); fi
}
echo "== Booted system"
uname -r; findmnt -no SOURCE,FSTYPE /; dinitctl list | grep -E 'NetworkManager|ufw|chrony|elogind|getty@tty1'
check "/ is the unlocked LUKS volume"   sh -c "findmnt -no SOURCE / | grep -q '^/dev/mapper/'"
check "/boot mounted (vfat)"            sh -c "findmnt -no FSTYPE /boot | grep -qx vfat"
check "swap active"                     sh -c "swapon --show | grep -q /swapfile"
check "PID 1 is dinit"                  sh -c "cat /proc/1/comm | grep -qx dinit"
for s in NetworkManager ufw elogind; do
    check "dinit service $s started"    sh -c "dinitctl status $s | grep -qi 'started'"
done
check "time sync service started"       sh -c "dinitctl list | grep -E 'chrony' | grep -q '\[{+}'"
check "ufw active, deny incoming"       sh -c "ufw status verbose | grep -q 'Status: active' && ufw status verbose | grep -q 'deny (incoming)'"
check "iptables has ufw chains"         sh -c "iptables -S | grep -q ufw-user-input"
check "network: DHCP address"           sh -c "for i in \$(seq 30); do ip -4 addr | grep -q 'inet 10.0.2' && exit 0; sleep 2; done; exit 1"
check "network: DNS + HTTPS"            sh -c "curl -fsS --max-time 20 -o /dev/null https://artixlinux.org"
# us-acentos has dead keys, plain us doesn't
check "console keymap us-acentos active" sh -c "dumpkeys -C /dev/tty1 | grep -q dead_acute"
check "user is in wheel"                sh -c "id -nG tester | grep -qw wheel"
check "sudoers grants tester (ALL : ALL)" sh -c "sudo -l -U tester | grep -q '(ALL : ALL) ALL'"
check "root password locked"            sh -c "passwd -S root | awk '{print \$2}' | grep -qx L"
if [ -e /etc/timeshift/timeshift.json ]; then
    check "dinit service cronie started" sh -c "dinitctl status cronie | grep -qi 'started'"
    # Finds the root file system from the config, without taking a snapshot
    check "timeshift uses the root fs (rsync)" sh -c "out=\$(timeshift --list --scripted 2>&1); echo \"\$out\" | grep -qE \"^UUID +: \$(findmnt -no UUID /)\" && echo \"\$out\" | grep -qE '^Mode +: RSYNC'"
    timeshift --list --scripted 2>&1 | head -n 8
fi
# yay only when the test enabled the AUR (verify checks which)
if command -v yay > /dev/null; then
    check "yay runs"                    sh -c "yay --version"
fi
check "sound card found"                grep -q . /proc/asound/cards
# Artix's udevd handover (udevadm control --exit, then a new udevd) loses the
# events sent in between. A sound card that finishes probing then, as in the
# slow VM, keeps root-only permissions; PipeWire then only has a Dummy Output.
if [ -e /dev/snd/controlC0 ] && [ "$(stat -c %G /dev/snd/controlC0)" != audio ]; then
    echo "NOTE  udev missed the sound card at boot (Artix udevd handover); running its rules again"
    udevadm trigger --subsystem-match=sound --action=add
    udevadm settle
fi
if [ -e /etc/modprobe.d/legacy-hda.conf ]; then
    check "older HDA driver option active" grep -qx 1 /sys/module/snd_intel_dspcfg/parameters/dsp_driver
fi
DESKTOP=$(cat /etc/artix-test-desktop 2> /dev/null || echo none)
if [ "$DESKTOP" != none ]; then
    echo "== Desktop: $DESKTOP"
    # The display manager, and the process that shows the session runs
    case $DESKTOP in
        plasma)   dm=sddm;    session=plasmashell ;;
        cinnamon) dm=lightdm; session=cinnamon ;;
        xfce)     dm=lightdm; session=xfce4-session ;;
        lxqt)     dm=lightdm; session=lxqt-session ;;
        sway)     dm=lightdm; session=sway ;;
        dwm)      dm=lightdm; session=dwm ;;
    esac
    uid=$(id -u tester)
    as_tester="su tester -c"
    run="XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus"
    for s in dbus turnstiled $dm; do
        check "dinit service $s started"    sh -c "dinitctl status $s | grep -qi 'started'"
    done
    case $dm in
        sddm)    greeter='sddm-greeter(-qt6)?' ;;
        lightdm) greeter=lightdm-gtk-greeter ;;
    esac
    # The greeter's X server: its display (SDDM passes none: :0) and auth file
    greeter_x() {
        local args
        args=$(pgrep -af '^/usr/(lib|bin)/X(org)? .*-auth ' | head -n 1)
        [ -n "$args" ] || return 1
        gdisplay=$(echo "$args" | grep -oE ' :[0-9]+' | tr -d ' ' | head -n 1)
        gdisplay=${gdisplay:-:0}
        gauth=$(echo "$args" | sed -E 's/.* -auth ([^ ]+).*/\1/')
    }
    # The emulated CPU makes all of this slow
    check "$dm shows its greeter"           sh -c "for i in \$(seq 300); do pgrep -f -x '.*$greeter.*' > /dev/null && exit 0; sleep 2; done; exit 1"
    sleep 30
    greeter_x
    echo "Greeter X: DISPLAY=$gdisplay XAUTHORITY=$gauth"
    rm -f /var/tmp/dm-screenshot.png
    # SDDM's Breeze greeter fades its login box out when nobody touches it
    DISPLAY="$gdisplay" XAUTHORITY="$gauth" xdotool mousemove 20 20 mousemove 400 300
    sleep 3
    check "screenshot of the login screen"  env DISPLAY="$gdisplay" XAUTHORITY="$gauth" maim /var/tmp/dm-screenshot.png
    # Log in like a person: the greeter has tester selected and the password
    # field focused. The password from test.conf.
    DISPLAY="$gdisplay" XAUTHORITY="$gauth" xdotool type --delay 150 'user pass 123'
    sleep 1
    DISPLAY="$gdisplay" XAUTHORITY="$gauth" xdotool key Return
    check "login through the greeter: $session runs" sh -c "for i in \$(seq 300); do pgrep -u tester -x $session && exit 0; sleep 2; done; exit 1"
    # turnstile starts the user's dinit, and so PipeWire, when tester logs in
    check "PipeWire runs for tester"        sh -c "for i in \$(seq 60); do pgrep -u tester -x pipewire && exit 0; sleep 2; done; exit 1"
    sink_is_card() { $as_tester "$run wpctl inspect @DEFAULT_AUDIO_SINK@" 2> /dev/null | grep -q 'node.name = "alsa_output'; }
    # The emulated card can show up late on the slow emulated CPU
    for _ in $(seq 30); do sink_is_card && break; sleep 2; done
    if ! sink_is_card; then
        wp=$(pgrep -u tester -x wireplumber | head -n 1)
        echo "NOTE  no sound card in WirePlumber after 60 s; wireplumber $(grep '^Groups' "/proc/$wp/status" 2> /dev/null)"
        dmesg | grep -i -E 'snd|hda' | tail -n 4 | sed 's/^/NOTE  kernel: /'
        $as_tester "$run dinitctl --user restart wireplumber" > /dev/null 2>&1
        for _ in $(seq 15); do sink_is_card && break; sleep 2; done
        if sink_is_card; then echo "NOTE  after restarting WirePlumber it has the sound card"; else echo "NOTE  restarting WirePlumber didn't help"; fi
    fi
    check "PipeWire uses the sound card, not Dummy Output" sink_is_card
    $as_tester "$run wpctl status" 2> /dev/null | sed -n '/^Audio/,/^Video/p' | head -n 15
    loginctl list-sessions --no-legend 2> /dev/null
    ls -l /dev/snd 2> /dev/null

    case $DESKTOP in
        cinnamon|xfce|lxqt|dwm)
            # Xorg logs the option as xkb_variant, not XkbVariant like in the file
            check "X keyboard: us international" grep -qiE 'xkb_?variant" "intl"' /var/log/Xorg.0.log
            grep -E '\((EE)\)' /var/log/Xorg.0.log 2> /dev/null | head -n 5 ;;
    esac
    if [ "$DESKTOP" = dwm ]; then
        check "volume block shows the volume" sh -c "$as_tester '$run ~/.local/bin/statusbar/sb-volume' | grep -qE '^vol [0-9]+%'"
        check "sound-fix: HDA driver in use"  sh -c "$as_tester '$run ~/.local/bin/sound-fix status' | grep -q '^Driver: HDA'"
        check "sound-fix: sound works"        sh -c "$as_tester '$run ~/.local/bin/sound-fix' | grep -q '^Sound works'"
        if [ -e /etc/modprobe.d/legacy-hda.conf ]; then
            check "sound-fix switches back and forth" sh -c "/home/tester/.local/bin/sound-fix sof && [ ! -e /etc/modprobe.d/legacy-hda.conf ] \
                && /home/tester/.local/bin/sound-fix hda && grep -qx 'options snd-intel-dspcfg dsp_driver=1' /etc/modprobe.d/legacy-hda.conf"
        fi
    fi

    # A screenshot of the session for the report. /var/tmp: the test copies
    # it off the disk after poweroff. dwm and sway: one floating terminal
    # with fastfetch in the middle of the screen, the way the rice looks.
    shot=/var/tmp/desktop-screenshot.png
    rm -f $shot
    x="DISPLAY=:0 XAUTHORITY=/home/tester/.Xauthority $run"
    case $DESKTOP in
        dwm)
            $as_tester "$x st" > /dev/null 2>&1 &
            sleep 20
            check "st opens"                sh -c "pgrep -u tester -x st"
            # mod+shift+space floats the new terminal; dwm keeps its tiled
            # size, so shrink it and center it on the screen, then run
            # fastfetch at that size
            $as_tester "$x xdotool key super+shift+space" > /dev/null 2>&1
            sleep 2
            read -r sw sh < <($as_tester "$x xdotool getdisplaygeometry")
            $as_tester "$x xdotool getactivewindow windowsize 860 500 windowmove $(((sw - 860) / 2)) $(((sh - 500) / 2))" > /dev/null 2>&1
            # The pointer is still where the greeter login left it
            $as_tester "$x xdotool mousemove $sw $sh" > /dev/null 2>&1
            sleep 2
            $as_tester "$x xdotool type --delay 30 'clear; fastfetch'" > /dev/null 2>&1
            $as_tester "$x xdotool key Return" > /dev/null 2>&1
            sleep 10
            check "screenshot of the desktop" su tester -c "$x maim $shot" ;;
        cinnamon|xfce|lxqt)
            sleep 60
            check "screenshot of the desktop" su tester -c "$x maim $shot" ;;
        sway)
            set -- /run/user/"$uid"/wayland-?
            wl="$run WAYLAND_DISPLAY=$(basename "$1")"
            set -- /run/user/"$uid"/sway-ipc.*.sock
            wl="$wl SWAYSOCK=$1"
            # Hide the pointer after 1 s without moving: grim would show it
            $as_tester "$wl swaymsg 'seat * hide_cursor 1000'" > /dev/null 2>&1
            # foot asks for this size, and sway keeps it for a floating window
            $as_tester "$wl swaymsg 'for_window [app_id=fastfetch] floating enable, move position center'" > /dev/null 2>&1
            $as_tester "$wl swaymsg exec \"foot --app-id=fastfetch --window-size-pixels=860x500 sh -c 'fastfetch; exec \\\$SHELL'\"" > /dev/null 2>&1
            sleep 30
            check "foot opens"              sh -c "pgrep -u tester -x foot"
            check "screenshot of the desktop" su tester -c "$wl grim $shot" ;;
        plasma)
            # Plasma's first start takes long on the emulated CPU
            sleep 90
            # KWin takes the first free name, not always wayland-0
            set -- /run/user/"$uid"/wayland-?
            wl="$run WAYLAND_DISPLAY=$(basename "$1")"
            check "screenshot of the desktop" sh -c "$as_tester '$wl spectacle -b -n -f -o $shot' && test -s $shot"
            if [ ! -s $shot ]; then
                # Why it failed: spectacle's own message, and what runs
                $as_tester "$wl spectacle -b -n -f -o $shot" 2>&1 | tail -n 5 | sed 's/^/NOTE  spectacle: /'
                echo "NOTE  runtime dir: $(cd /run/user/"$uid" && echo *)"
                pgrep -u tester -l -f 'kwin|plasmashell|xdg-desktop-portal' | sed 's/^/NOTE  /'
            fi ;;
    esac
fi
echo "== BOOT CHECKS: $pass passed, $fail failed"
