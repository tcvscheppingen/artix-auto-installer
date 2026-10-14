# Artix Auto Installer
Personal script for installing Artix Linux with Dinit on UEFI PCs/laptops.

![The installer installing Artix with KDE Plasma, then booting, unlocking the disk and logging in to Plasma (sped up)](assets/install-demo.gif)

After having installed Artix/Arch manually multiple times, I wanted to automate the installation, so I created this script.  
The default locale and keymap are my own preferences, but can be changed during the installation.

The installation script is designed for UEFI PCs and laptops with an Intel or AMD CPU.

The script will do the following:
- Rank the package mirrors by speed (`rankmirrors`), for the installation and the installed system.
- Install Artix Linux with Dinit as the init system and with an encrypted root partition.
- Enable a firewall (UFW) that blocks all incoming connections and allows outgoing ones.
- Show a summary of the installation at the end, with what to do next. You can save it as `~/artix-install-summary.md` in the new system.
- Optionally:
  - Install the LTS Linux kernel as fallback.
  - Install NVIDIA's proprietary driver, when an NVIDIA GPU is found. The right driver for the card's generation (Maxwell or newer) is picked automatically.
  - Use the older HDA sound driver instead of SOF, when the Intel sound chip has a DSP. Use this when SOF only gives a "Dummy Output"; the built-in digital microphones don't work with the HDA driver.
  - Enable the Arch User Repository (AUR) and install `yay` as AUR helper.
  - Install a desktop (see below). Without one, the system boots to a text console.

## Desktops

The script can install one of these. They all work with Artix and dinit: PipeWire, and the D-Bus session bus where needed, run as the user's own dinit services, started by turnstile at login.

| Desktop | Login | What gets installed |
|---|---|---|
| KDE Plasma | SDDM | Plasma, Konsole, Dolphin, Kate, Ark, Gwenview, Okular, Spectacle |
| Cinnamon | LightDM | Cinnamon, GNOME Terminal, File Roller, Eye of GNOME, pavucontrol, Blueman |
| XFCE | LightDM | XFCE with the goodies, pavucontrol, the network applet, Blueman |
| sway | TTY1 or LightDM | My sway setup, [SARBS](https://github.com/tcvscheppingen/SARBS) |
| dwm | TTY1 or LightDM | My dwm setup, [DARBS](https://github.com/tcvscheppingen/DARBS) |

Plasma, Cinnamon and XFCE also get Xorg, LibreWolf, Bluetooth, the Noto fonts, and the Vulkan and VA-API drivers for the Intel/AMD GPUs that are found. For sway and dwm, the script runs SARBS's or DARBS's `auto-rice-artix.sh` as your user, which installs what that setup needs. They start automatically when you log in on TTY1, or from LightDM with a minimal gruvbox greeter; the script asks which.

sway doesn't support NVIDIA's driver, so with sway the script leaves it out and the open nouveau driver is used; on a laptop with Intel/AMD graphics too, sway runs on those. GNOME is not offered: it needs systemd.

## Usage

Boot the Artix **base dinit** ISO in UEFI mode with Secure Boot off, log in as `root` (password `artix`), connect to the internet, then:

```bash
pacman -S git
git clone https://github.com/tcvscheppingen/artix-auto-installer.git
cd artix-auto-installer
chmod +x artix-install.sh
./artix-install.sh
```
To preset some or all answers, copy `install.conf.example`, fill it in and run `./artix-install.sh --config install.conf`. Anything you leave empty is asked for.

## Testing

`test/run-container-test.sh` tests the installer with Docker: it runs the installer in an Artix container against a disk image, checks the installed system, and boots it in QEMU (UEFI, NVMe) to check it from the inside.

```bash
test/run-container-test.sh                          # shellcheck, packages, install, verify, boot; no desktop
test/run-container-test.sh all --desktop plasma     # with a desktop: plasma, cinnamon, xfce, sway or dwm
test/run-container-test.sh all --desktop all        # every desktop in turn (takes hours)
DARBS_DIR=~/src/DARBS test/run-container-test.sh all --desktop dwm    # a local DARBS checkout
SARBS_DIR=~/src/SARBS test/run-container-test.sh all --desktop sway   # a local SARBS checkout
```

Every run checks that the package lists of Plasma, Cinnamon and XFCE still exist in the Artix repos. Each desktop needs its own install, so `--desktop all` installs, checks and boots them one after another; a failing desktop doesn't stop the next one. With a desktop, the boot test logs in through the display manager's login screen the way a person would (it types the password with xdotool), checks the session, PipeWire and the sound card, and the report shows screenshots of the login screen and the desktop.

It works on macOS (Docker Desktop) and Linux (Docker Engine). The install and check stages need privileged containers, which on Linux share the host's kernel; the test only uses its own loop devices and device-mapper names, and doesn't change the host's EFI boot entries, clock, swap or console keymap.

Each desktop's logs, screenshots and report end up in `test/out/<desktop>/`, so runs for different desktops don't overwrite each other. `--desktop all` also writes `test/out/test-report.pdf`, with a summary of all desktops followed by each one's results. The reports are PDFs when pandoc and a TeX engine (xelatex, lualatex, pdflatex or tectonic) are installed, otherwise Markdown.

## Disclaimer
I wrote this script with assistance from a Large Language Model.   
I have reviewed the script in its entirety and validated it by running it in a VM, and I have used it to install Artix on a personal device.

