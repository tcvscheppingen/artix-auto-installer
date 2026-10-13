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
check "yay runs"                        sh -c "yay --version"
check "sound card found"                grep -q . /proc/asound/cards
if [ -e /etc/modprobe.d/legacy-hda.conf ]; then
    check "older HDA driver option active" grep -qx 1 /sys/module/snd_intel_dspcfg/parameters/dsp_driver
fi
if [ -x /usr/local/bin/dwm ]; then
    echo "== DARBS"
    for s in dbus turnstiled; do
        check "dinit service $s started"    sh -c "dinitctl status $s | grep -qi 'started'"
    done
    # turnstile starts the user's dinit, and so PipeWire, when tester logs in
    check "PipeWire runs for tester"        sh -c "for i in \$(seq 30); do pgrep -u tester -x pipewire && exit 0; sleep 2; done; exit 1"
    check "PipeWire uses the sound card, not Dummy Output" \
        sh -c "su tester -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u tester) wpctl inspect @DEFAULT_AUDIO_SINK@' | grep -q 'node.name = \"alsa_output'"
    su tester -c "XDG_RUNTIME_DIR=/run/user/$(id -u tester) wpctl status" 2> /dev/null | sed -n '/^Audio/,/^Video/p' | head -n 15
    loginctl list-sessions --no-legend 2> /dev/null
    ls -l /dev/snd 2> /dev/null
    as_tester="su tester -c"
    run="XDG_RUNTIME_DIR=/run/user/$(id -u tester)"
    check "volume block shows the volume"   sh -c "$as_tester '$run ~/.local/bin/statusbar/sb-volume' | grep -qE '^vol [0-9]+%'"
    check "sound-fix: HDA driver in use"    sh -c "$as_tester '$run ~/.local/bin/sound-fix status' | grep -q '^Driver: HDA'"
    check "sound-fix: sound works"          sh -c "$as_tester '$run ~/.local/bin/sound-fix' | grep -q '^Sound works'"
    if [ -e /etc/modprobe.d/legacy-hda.conf ]; then
        check "sound-fix switches back and forth" sh -c "/home/tester/.local/bin/sound-fix sof && [ ! -e /etc/modprobe.d/legacy-hda.conf ] \
            && /home/tester/.local/bin/sound-fix hda && grep -qx 'options snd-intel-dspcfg dsp_driver=1' /etc/modprobe.d/legacy-hda.conf"
    fi
    check "Xorg starts and stops cleanly"   sh -c "timeout 180 xinit /bin/true -- :1 vt7 -logfile /tmp/Xorg.test.log; grep -q 'Server terminated successfully' /tmp/Xorg.test.log"
    grep -E '\((EE|WW)\)' /tmp/Xorg.test.log 2> /dev/null | head -n 5

    # The DARBS session as tester, with st running htop and Thunar, for the
    # report's screenshot. /var/tmp: the test copies it off the disk after poweroff.
    rm -f /var/tmp/darbs-screenshot.png
    uid=$(id -u tester)
    XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
        xinit /bin/su tester -c 'sh ~/.config/x11/xinitrc' -- :2 vt8 -logfile /tmp/Xorg.dwm.log \
        > /tmp/dwm-session.log 2>&1 &
    check "dwm session starts"              sh -c "for i in \$(seq 60); do pgrep -u tester -x dwm && exit 0; sleep 2; done; exit 1"
    su tester -c 'DISPLAY=:2 st -e htop' > /dev/null 2>&1 &
    # Thunar shows whether GTK 3 apps get the dark theme
    su tester -c "DISPLAY=:2 XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus thunar" > /dev/null 2>&1 &
    # Time for the wallpaper, bar and st on the slow emulated CPU
    sleep 30
    check "X keyboard: us international"    grep -q 'XkbVariant.*intl' /tmp/Xorg.dwm.log
    check "Thunar opens"                    sh -c "pgrep -u tester -x thunar"
    check "screenshot of dwm"               su tester -c 'DISPLAY=:2 maim /var/tmp/darbs-screenshot.png'
    pkill -x xinit
    sleep 3
fi
echo "== BOOT CHECKS: $pass passed, $fail failed"
