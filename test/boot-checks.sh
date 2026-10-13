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
check "/ is the unlocked LUKS volume"   sh -c "findmnt -no SOURCE / | grep -q /dev/mapper/cryptroot"
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
check "keymap loaded from vconsole"     grep -qx 'KEYMAP=us-acentos' /etc/vconsole.conf
check "user is in wheel"                sh -c "id -nG tester | grep -qw wheel"
check "sudoers grants tester (ALL : ALL)" sh -c "sudo -l -U tester | grep -q '(ALL : ALL) ALL'"
check "root password locked"            sh -c "passwd -S root | awk '{print \$2}' | grep -qx L"
check "yay runs"                        sh -c "yay --version"
echo "== BOOT CHECKS: $pass passed, $fail failed"
