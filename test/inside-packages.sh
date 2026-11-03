#!/usr/bin/env bash
# Checks the desktop environments' package lists still resolve (sway, dwm and
# penrose come from their own repos)
set -Eeuo pipefail

pacman -Sy > /dev/null
pass=0 fail=0
{
echo "== Desktop packages"
for desktop in plasma cinnamon xfce lxqt; do
    mapfile -t pkgs < <(bash /src/artix-install.sh --print-desktop-packages "$desktop")
    if out=$(pacman -Sp --print-format '%n' "${pkgs[@]}" vulkan-intel intel-media-driver vulkan-radeon 2>&1); then
        echo "PASS  $desktop: ${#pkgs[@]} packages resolve ($(wc -l <<< "$out") to install with dependencies)"
        pass=$((pass + 1))
    else
        echo "FAIL  $desktop: $(grep -m3 'error:' <<< "$out" | tr '\n' ' ')"
        fail=$((fail + 1))
    fi
done
echo "== Result: $pass passed, $fail failed"
} 2>&1 | tee /logs/packages.log

grep -q ' 0 failed$' /logs/packages.log
